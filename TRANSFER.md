# Gotya — Transfer & Rebuild Plan

## What we are trying to achieve

Build the Gotya loyalty card app from scratch on a clean setup — new laptop, new Google account, new domain. The Libber codebase is the working blueprint. The goal is to fully own and understand every layer of the stack, with everything registered and configured under the Gotya identity from day one.

---

## Order of operations (read this first)

DNS propagation takes 24–48 hours. Do the domain and DNS steps **before** anything else so the wait runs in the background while you set up everything else.

1. Set up accounts (Google, GitHub, Vercel, Supabase, Sentry, Resend)
2. Add `gotya.ie` to Vercel → get DNS records
3. Add `gotya.ie` to Resend → get DNS records
4. Add ALL DNS records to registrar (123reg) in one go
5. While DNS propagates: set up Linux machine, clone repo, run SQL scripts, configure Supabase
6. Once DNS is live: test email, test OAuth, test custom domain

---

## New accounts to set up

1. **Google account** — Gotya branded. This becomes the owner account for everything below.
2. **GitHub** — new account or organisation under the Gotya Google account. Create repo `gotya`.
3. **Vercel** — sign up with the Gotya Google account. Connect to the GitHub repo.
4. **Supabase** — new project. Note the project ref, anon key, and URL.
5. **Sentry** — new project for error tracking. Note the DSN and auth token.
6. **Resend** — sign up, add and verify domain `gotya.ie`, create API key.
7. **Google Cloud Console** — create project `Gotya`. Set up OAuth consent screen and credentials.
8. **Apple Developer** (optional, $99/year) — needed for Apple sign-in.

---

## Domain DNS setup (do early — propagation takes 24–48 hours)

Domains registered: `gotya.ie` and `gotya.co.uk` (via 123reg).

### Vercel DNS records

In Vercel: **Project → Settings → Domains → Add → `gotya.ie`**

Vercel will show you the DNS records to add (usually an A record and a CNAME). Add them at 123reg.

### Resend DNS records

In Resend: **Domains → Add Domain → `gotya.ie`**

Resend will show SPF, DKIM, and MX records. Add all of them at 123reg.

### At 123reg

Go to **Domain Management → `gotya.ie` → DNS** and add all the records from Vercel and Resend together. Once saved, propagation begins — check back in a few hours.

---

## Linux machine setup (fresh install)

### 1. Install VS Code

Download from [code.visualstudio.com](https://code.visualstudio.com) or:

```bash
sudo snap install code --classic
```

### 2. Install curl and Git

```bash
sudo apt update
sudo apt install curl git
git --version
```

Configure Git identity:

```bash
git config --global user.name "Your Name"
git config --global user.email "your@gotya.ie"
```

### 3. Install Node.js via nvm

nvm is the recommended way to install Node on Linux — avoids permission issues.

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
```

Close and reopen the terminal, then:

```bash
nvm install --lts
nvm use --lts
node --version   # should be v22 or higher
npm --version
```

### 4. Set up SSH key for GitHub

```bash
ssh-keygen -t ed25519 -C "your@gotya.ie"
# Press enter to accept defaults
cat ~/.ssh/id_ed25519.pub
```

Copy the output and add it in GitHub: **Settings → SSH and GPG keys → New SSH key**

Test it:

```bash
ssh -T git@github.com
# Should say: Hi username! You've successfully authenticated...
```

### 5. Clone the repo

```bash
git clone git@github.com:yourusername/gotya.git
cd gotya
```

### 6. Install project dependencies

```bash
npm install
```

This also sets up the Husky pre-commit lint hook automatically.

### 7. Create `.env.local`

Create this file in the project root (never commit it — it is in `.gitignore`):

```
VITE_SUPABASE_URL=your_supabase_project_url
VITE_SUPABASE_ANON_KEY=your_supabase_anon_key
SENTRY_AUTH_TOKEN=your_sentry_auth_token
```

| Variable | Where to get it |
|---|---|
| `VITE_SUPABASE_URL` | Supabase Dashboard → Project Settings → API |
| `VITE_SUPABASE_ANON_KEY` | Supabase Dashboard → Project Settings → API |
| `SENTRY_AUTH_TOKEN` | Sentry → Settings → Auth Tokens |

### 8. Start the dev server

```bash
npm run dev
```

Admin tool: `http://localhost:5173/adminstart.html`

---

## Code changes before first deploy

These are hardcoded values in the source that must be updated for Gotya:

### 1. Sentry DSN — `src/lib/sentry.js`

The DSN is hardcoded (not an env var). Replace the `dsn` value with the one from your new Sentry project:

```js
dsn: 'YOUR_NEW_SENTRY_DSN_HERE',
```

Get it from: Sentry → Your Project → Settings → Client Keys (DSN)

### 2. Rename Libber → Gotya throughout

| File | What to change |
|---|---|
| `package.json` | `"name"` field |
| `apps/customer/manifest.json` | App name and short name |
| All HTML files | Page `<title>` tags and any visible "Libber" text |
| `README.md` | Project name and URLs |

### 3. `vercel.json`

The CSP headers use wildcards (`*.supabase.co`, `*.ingest.de.sentry.io`) — no changes needed. Just confirm the rewrites still match your page structure.

---

## Supabase setup — SQL scripts

Run these in order in **Supabase Dashboard → SQL Editor**. All are in `scripts/sql/`.

1. `admin-rpcs.sql`
2. `staff-rpcs.sql`
3. `add-manager-applicants.sql`
4. `add-bonus-cap.sql`
5. `add-rls-select-policies.sql`
6. `add-load-customer-home-rpc.sql`
7. `add-load-store-members-rpc.sql`
8. `add-reject-applicant-rpc.sql`
9. `add-ab-testing.sql`
10. `add-bonus-adjust.sql`
11. `add-save-account.sql`
12. `add-load-store-staff-profiles-rpc.sql`
13. `rename-account-linked.sql`
14. `harden-rls-and-grants.sql`
15. `fix-default-privileges.sql`
16. `remove-applicant-table-refs.sql`
17. `drop-applicant-system.sql`
18. `add-store-logo.sql`
19. `admin-load-store-members.sql`
20. `fix-default-privileges.sql` ← always re-run last after any session that creates/replaces functions
21. Open `http://localhost:5173/adminstart.html`, copy your public ID, run `assign-admin.sql`
22. Reload admin tool — create stores, configure reward rules, assign managers

---

## Supabase dashboard configuration

| Setting | Where | Value |
|---|---|---|
| Custom SMTP | Authentication → Email → Custom SMTP | Resend — see below |
| Google OAuth | Authentication → Providers → Google | Client ID + Secret from Google Cloud Console |
| Apple OAuth | Authentication → Providers → Apple | Services ID, Team ID, Key ID, `.p8` key |
| Site URL | Authentication → URL Configuration | `https://gotya.ie` |
| Redirect URL | Authentication → URL Configuration | `https://gotya.ie/apps/customer/save.html` |

### Resend SMTP values

| Field | Value |
|---|---|
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | Resend API key |
| Sender email | `noreply@gotya.ie` |
| Sender name | `Gotya` |

---

## Google Cloud Console — OAuth setup

1. Create project `Gotya`
2. **APIs & Services → OAuth consent screen**
   - User type: External
   - App name: Gotya
   - Authorised domain: `gotya.ie`
   - Publish
3. **APIs & Services → Credentials → Create → OAuth 2.0 Client ID**
   - Type: Web application
   - Name: Gotya
   - Authorised redirect URI: `https://<your-supabase-ref>.supabase.co/auth/v1/callback`
4. Copy Client ID and Client Secret → Supabase Auth → Providers → Google → Enable → paste → Save

---

## Vercel setup

1. Sign in with Gotya Google account
2. Connect GitHub repo `gotya`
3. Framework: Vite (auto-detected)
4. Build command: `npm run build`
5. Output directory: `dist`
6. Add environment variables:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
   - `SENTRY_AUTH_TOKEN`
7. Deploy
8. Add custom domain `gotya.ie` (once DNS has propagated)

---

## After go-live checklist

- [ ] `gotya.ie` resolves correctly in browser
- [ ] Magic link email arrives from `noreply@gotya.ie`
- [ ] Google sign-in flow completes and redirects to home
- [ ] Save flow redirects back to home within 1.5 seconds of signing in
- [ ] Admin tool works locally — stores visible, member lists loading
- [ ] Points award and redeem working on staff page
- [ ] Run DB security audit queries (see README) to confirm RLS and grants are correct
- [ ] `fix-default-privileges.sql` re-run after any function is created or replaced
