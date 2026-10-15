-- Shubra Champions Tournament: Supabase schema
-- Run in the Supabase SQL editor (or via migration).

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  captain_user uuid not null default auth.uid() references auth.users(id),
  name text not null unique,
  phone text not null,
  status text not null default 'pending' check (status in ('pending','selected','rejected')),
  seed int,
  created_at timestamptz not null default now()
);
create unique index one_team_per_captain on public.teams(captain_user);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  role text not null check (role in ('captain','player')),
  full_name text not null,
  -- UNIQUE across ALL teams: one ID can only ever belong to one team
  national_id text not null unique check (national_id ~ '^[23][0-9]{13}$'),
  id_photo_path text not null,
  verified boolean not null default false
);

create table public.admins (user_id uuid primary key references auth.users(id));

create table public.matches (
  id serial primary key,
  round text not null check (round in ('QF','SF','F')),
  slot int not null,
  team_a uuid references public.teams(id),
  team_b uuid references public.teams(id),
  score_a int not null default 0,
  score_b int not null default 0,
  status text not null default 'scheduled' check (status in ('scheduled','live','done')),
  winner uuid references public.teams(id),
  unique (round, slot)
);

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- RLS
alter table public.teams enable row level security;
alter table public.members enable row level security;
alter table public.admins enable row level security;
alter table public.matches enable row level security;

create policy teams_read on public.teams for select to authenticated
  using (captain_user = auth.uid() or public.is_admin());
create policy teams_admin_write on public.teams for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy members_read on public.members for select to authenticated
  using (public.is_admin() or exists (select 1 from public.teams t where t.id = team_id and t.captain_user = auth.uid()));
create policy members_admin_write on public.members for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy matches_read on public.matches for select to anon, authenticated using (true);
create policy matches_admin_write on public.matches for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Public view: only the selected teams' names
create view public.public_teams as
  select id, name, seed from public.teams where status = 'selected';
grant select on public.public_teams to anon, authenticated;

-- Live duplicate check (signed-in users only). Returns IDs already used by any team.
create or replace function public.taken_ids(ids text[]) returns text[]
language sql security definer set search_path = public as $$
  select coalesce(array_agg(national_id), '{}') from public.members where national_id = any(ids)
$$;
revoke execute on function public.taken_ids(text[]) from public, anon;
grant execute on function public.taken_ids(text[]) to authenticated;

-- Atomic registration: team + 6 members, or nothing (a duplicate ID rolls everything back)
create or replace function public.register_team(p_name text, p_phone text, p_members jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare tid uuid; m jsonb; i int := 0;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if jsonb_typeof(p_members) <> 'array' or jsonb_array_length(p_members) <> 6 then
    raise exception 'need_6_members';
  end if;
  insert into public.teams(captain_user, name, phone) values (auth.uid(), trim(p_name), trim(p_phone))
    returning id into tid;
  for m in select * from jsonb_array_elements(p_members) loop
    i := i + 1;
    insert into public.members(team_id, role, full_name, national_id, id_photo_path)
    values (tid, case when i = 1 then 'captain' else 'player' end,
            trim(m->>'name'), m->>'nid', m->>'photo');
  end loop;
  return tid;
end $$;
revoke execute on function public.register_team(text, text, jsonb) from public, anon;
grant execute on function public.register_team(text, text, jsonb) to authenticated;

-- Shareable link / check-in page data (safe fields only)
create or replace function public.team_status(tid uuid) returns json
language sql security definer stable set search_path = public as $$
  select json_build_object('name', t.name, 'status', t.status,
    'members', (select count(*) from public.members where team_id = t.id),
    'verified', (select count(*) from public.members where team_id = t.id and verified))
  from public.teams t where t.id = tid
$$;
grant execute on function public.team_status(uuid) to anon, authenticated;

-- Admin: pick exactly 8 teams and build the bracket (4 QF, 2 SF, 1 F)
create or replace function public.select_teams(ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare s int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if array_length(ids, 1) <> 8 then raise exception 'need_8_teams'; end if;
  update public.teams set status = case when id = any(ids) then 'selected' else 'rejected' end,
    seed = array_position(ids, id);
  delete from public.matches;
  for s in 1..4 loop
    insert into public.matches(round, slot, team_a, team_b) values ('QF', s, ids[2*s-1], ids[2*s]);
  end loop;
  insert into public.matches(round, slot) values ('SF',1),('SF',2),('F',1);
end $$;
revoke execute on function public.select_teams(uuid[]) from public, anon;
grant execute on function public.select_teams(uuid[]) to authenticated;

-- Admin: final result, sets winner and advances them to the next round
create or replace function public.set_result(mid int, a int, b int) returns void
language plpgsql security definer set search_path = public as $$
declare m public.matches; w uuid; nxt text;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if a = b then raise exception 'no_draws'; end if;
  select * into m from public.matches where id = mid;
  w := case when a > b then m.team_a else m.team_b end;
  update public.matches set score_a = a, score_b = b, status = 'done', winner = w where id = mid;
  if m.round <> 'F' then
    nxt := case m.round when 'QF' then 'SF' else 'F' end;
    if m.slot % 2 = 1 then
      update public.matches set team_a = w where round = nxt and slot = (m.slot + 1) / 2;
    else
      update public.matches set team_b = w where round = nxt and slot = (m.slot + 1) / 2;
    end if;
  end if;
end $$;
revoke execute on function public.set_result(int, int, int) from public, anon;
grant execute on function public.set_result(int, int, int) to authenticated;

-- Private bucket for ID photos (owner + admin only)
insert into storage.buckets (id, name, public) values ('id-photos', 'id-photos', false)
  on conflict (id) do nothing;
create policy idphotos_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'id-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy idphotos_read on storage.objects for select to authenticated
  using (bucket_id = 'id-photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- Realtime for the public scoreboard
alter publication supabase_realtime add table public.matches;

-- After you sign up once on the site, make yourself admin:
-- insert into public.admins(user_id) select id from auth.users where email = 'YOUR_EMAIL';
