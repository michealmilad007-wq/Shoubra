// Vercel build step: write public/config.js from environment variables.
const fs = require('fs');
const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_KEY;
if (!url || !key) { console.error('Missing SUPABASE_URL or SUPABASE_KEY environment variable.'); process.exit(1); }
fs.writeFileSync('public/config.js',
  `window.APP_CONFIG = ${JSON.stringify({ SUPABASE_URL: url, SUPABASE_KEY: key })};\n`);
console.log('config.js written');
