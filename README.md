# Hope, Inc. ERP (frontend + Supabase)

```
index.html     opens the login page
css/           hope.css, the shared design system
html/          one file per page (login, dashboard, users, customers, ...)
js/            config.js (your Supabase keys), app shell, services, page scripts
               edge-function-admin-create-user.ts (pasted into Supabase, not run in the browser)
sql/           01 to 05, run in this order in the Supabase SQL Editor
               06-migrate-old-data.sql is optional: one-time copy of data from the older tables
```

## Setup
1. **Database:** in Supabase > SQL Editor, paste and run `sql/01-schema.sql`, then 02, 03, 04, 05 in order.
2. **Keys:** open `js/config.js` and paste your project URL and anon/publishable key (Project Settings > API Keys).
3. **Run locally:** serve this folder over HTTP (VS Code Live Server: right-click `index.html` > Open with Live Server).
4. **Redirect URLs:** Supabase > Authentication > URL Configuration. Set Site URL to your local address, for example
   `http://127.0.0.1:5500`, and add `http://127.0.0.1:5500/html/reset-password.html` and
   `http://localhost:5500/html/reset-password.html` to Redirect URLs.
5. **Add user feature:** Supabase > Edge Functions > new function `admin-create-user`, paste `js/edge-function-admin-create-user.ts`.
6. **First Superadmin:** register on the Register page, then run in the SQL Editor:
   `update public.profiles set role = 'SUPERADMIN', status = 'ACTIVE' where email = 'you@example.com';`

See REMAINING.md for what is still open.
