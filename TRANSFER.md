# Gotya — Transfer & Rebuild Plan

## What we are trying to achieve

Build the Gotya loyalty card app from scratch on a clean setup — new laptop, new Google account, new domain. The Libber codebase is the working blueprint. The goal is to fully own and understand every layer of the stack, with everything registered and configured under the Gotya identity from day one.

---

## New accounts to set up (in order)

1. **Google account** — `gotya` branded. This becomes the owner account for everything below.
2. **GitHub** — new account or new organisation under the Gotya Google account. Create repo `gotya`.
3. **Vercel** — sign up with the Gotya Google account. Connect to the GitHub repo.
4. **Supabase** — new project. Note the project ref, anon key, and URL.
5. **Sentry** — new project for error tracking. Note the DSN and auth token.
6. **Resend** — sign up, add and verify domain `gotya.ie`, create API key.
7. **Google Cloud Console** — create a new project `Gotya`. Set up OAuth consent screen and credentials for Google sign-in.
8. **Apple Developer** (optional, $99/year) — needed for Apple sign-in.

---

## Domain setup

- Domains registered: `gotya.ie` and `gotya.co.uk`
- Add `gotya.ie` as a custom domain in Vercel (free)
- Add `gotya.ie` to Resend for transactional email

---

## Linux machine setup (fresh install)

### 1. Install Node.js (via nvm — recommended)

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
# Close and reopen terminal, then:
nvm install --lts
nvm use --lts
node --version   # should be v22 or higher
npm --version
```

### 2. Install Git

```bash
sudo apt update
sudo apt install git
git --version
```

Configure Git identity:

```bash
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

### 3. Set up SSH key for GitHub

```bash
ssh-keygen -t ed25519 -C "your@email.com"
# Press enter to accept defaults
cat ~/.ssh/id_ed25519.pub
```

Copy the output and add it to GitHub: **Settings → SSH and GPG keys → New SSH key**

Test it:

```bash
ssh -T git@github.com
# Should say: Hi username! You've successfully authenticated...
```

### 4. Clone the repo

```bash
git clone git@github.com:yourusername/gotya.git
cd gotya
```

### 5. Install project dependencies

```bash
npm install
```

### 6. Create `.env.local`

```bash
VITE_SUPABASE_URL=your_supabase_project_url
VITE_SUPABASE_ANON_KEY=your_supabase_anon_key
SENTRY_AUTH_TOKEN=your_sentry_auth_token
```

Get these values from:
- Supabase Dashboard → Project Settings → API
- Sentry → Settings → Auth Tokens

### 7. Start the dev server

```bash
npm run dev
```

Admin tool available at: `http://localhost:5173/adminstart.html`

### 8. Install a code editor (VS Code)

```bash
sudo snap install code --classic
```

Or download from code.visualstudio.com.

---

## Code preparation (do this before transferring)

1. Clone or copy the Libber repo
2. Rename all references from `Libber` / `libber` to `Gotya` / `gotya`:
   - `package.json` — name field
   - `README.md`
   - `apps/customer/manifest.json` — app name
   - Any hardcoded strings in HTML files (page titles, headings)
3. Update environment variables in `.env.local`:
   - `VITE_SUPABASE_URL` — new Supabase project URL
   - `VITE_SUPABASE_ANON_KEY` — new Supabase anon key
   - `SENTRY_AUTH_TOKEN` — new Sentry auth token
4. Update `vercel.json` if any Supabase/Sentry URLs are hardcoded in the CSP headers

---

## Supabase setup — SQL scripts (run in this exact order)

See `README.md → Fresh Setup` for the full ordered list. After running all scripts:

1. Start the dev server locally
2. Open `http://localhost:5173/adminstart.html`
3. Copy your public ID shown at the top
4. Run `assign-admin.sql` with that public ID
5. Reload admin tool — create stores, configure reward rules, assign managers

---

## Supabase configuration (dashboard)

After SQL scripts are done:

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
2. APIs & Services → OAuth consent screen
   - User type: External
   - App name: Gotya
   - Authorised domain: `gotya.ie`
   - Publish
3. APIs & Services → Credentials → Create → OAuth 2.0 Client ID
   - Type: Web application
   - Name: Gotya
   - Authorised redirect URI: `https://<new-supabase-ref>.supabase.co/auth/v1/callback`
4. Copy Client ID and Client Secret → paste into Supabase Auth → Google

---

## Vercel setup

1. Connect GitHub repo
2. Framework: Vite (auto-detected)
3. Build command: `npm run build`
4. Output directory: `dist`
5. Environment variables:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
   - `SENTRY_AUTH_TOKEN`
6. Add custom domain `gotya.ie`

---

## After go-live checklist

- [ ] Magic link email arrives from `noreply@gotya.ie`
- [ ] Google sign-in completes and redirects correctly
- [ ] Save flow redirects back to home after 1.5 seconds
- [ ] Admin tool works locally — stores visible, member lists loading
- [ ] Points award and redeem working on staff page
- [ ] Run DB security audit queries (see README) to confirm RLS and grants are correct
- [ ] Re-run `fix-default-privileges.sql` after any function is created or replaced
