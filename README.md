# دورة أبطال شبرا: Tournament site

## 1. Supabase
1. Create a project at supabase.com.
2. SQL Editor: paste and run `supabase/schema.sql`.
3. Authentication > Providers > Email: keep enabled. For quick testing, turn off "Confirm email".
4. Project Settings > API: copy the Project URL and the publishable (anon) key.

## 2. Vercel
1. Push this folder to a GitHub repo, then Vercel > Add New > Project > import it.
   (Or run `npx vercel` in this folder.)
2. Environment Variables:
   - SUPABASE_URL = your project URL
   - SUPABASE_KEY = your publishable/anon key
3. Deploy. Framework preset: Other (vercel.json already sets everything).

## 3. After the first deploy
1. Supabase > Authentication > URL Configuration: set Site URL to your Vercel domain
   and add it to Redirect URLs (needed for email confirmation).
2. Open the site, go to "سجّل فريقك", create your account.
3. In the SQL editor run:
   insert into public.admins(user_id) select id from auth.users where email = 'YOUR_EMAIL';
4. Reload: an "الإدارة" (Admin) tab appears.

## Notes
- The publishable/anon key is meant to be public; security comes from the RLS policies in schema.sql.
- Never put the service_role key in Vercel env vars for this project.
