# Libber — Outstanding Work

Last updated: 2026-05-10

---

## 1. Pending SQL Deployments

Run in this exact order in **Supabase Dashboard → SQL Editor**.

### 1a. `scripts/sql/admin-load-store-members.sql`
**What it fixes:** The `load_store_members` RPC previously required the calling admin to be manually added as a manager of each store (bootstrap dependency). This script replaces that check with `is_admin()` so any admin can view members of any store without needing to be assigned as a manager first. Without this, the admin tool shows empty member lists for stores the admin was not bootstrapped into.

### 1b. `scripts/sql/add-load-store-members-rpc.sql`
**What it fixes:** Adds `ORDER BY p.public_id` to the member list query. Currently members appear in insertion order on the staff page. After this they appear alphabetically by public ID.

### 1c. `scripts/sql/fix-default-privileges.sql` ← always re-run last
**Why:** Creating or replacing RPCs in Supabase resets default privileges, which can inadvertently re-grant `EXECUTE` to `anon`. This script revokes those grants and re-applies the correct `authenticated`-only permissions. Must be run after any session that creates or replaces functions.

---

## 2. OAuth Setup — Google

Google OAuth is **not yet configured**. Until this is done, "Continue with Google" on the save page will silently redirect and fail.

### Step 1 — Google Cloud Console
1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Select an existing project (e.g. **My Project** — `delta-discovery-593`)
3. **APIs & Services → OAuth consent screen**
   - User type: External
   - App name, support email, developer email
   - Authorised domain: `libber.vercel.app`
   - Publish (or add test users if keeping in testing mode)
4. **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
   - Application type: **Web application**
   - Authorised redirect URI — add exactly:
     ```
     https://flghcbrwqtburdywgcvk.supabase.co/auth/v1/callback
     ```
5. Copy the **Client ID** and **Client Secret**

### Step 2 — Supabase
- Authentication → Providers → **Google** → Enable → paste Client ID + Client Secret → Save

---

## 3. OAuth Setup — Apple

Apple Sign-In requires a paid **Apple Developer account ($99/year)**. More complex than Google.

### Step 1 — Apple Developer Portal ([developer.apple.com](https://developer.apple.com))
1. **Identifiers → +** → App ID
   - Bundle ID: e.g. `com.libber.app`
   - Capability: tick **Sign In with Apple**

2. **Identifiers → +** → Services ID
   - Description: `Libber Web`
   - Identifier: e.g. `com.libber.web` ← this becomes your **Client ID** in Supabase
   - After saving, click it → Enable **Sign In with Apple → Configure**
     - Primary App ID: the App ID from step 1
     - Domains: `libber.vercel.app`
     - Return URLs:
       ```
       https://flghcbrwqtburdywgcvk.supabase.co/auth/v1/callback
       ```

3. **Keys → +**
   - Enable **Sign In with Apple** → Configure → select App ID from step 1
   - Download the `.p8` private key file (one download only — save it securely)
   - Note the **Key ID**

4. Note your **Team ID** (top-right of the developer portal)

### Step 2 — Supabase
- Authentication → Providers → **Apple** → Enable:
  - Client ID: `com.libber.web`
  - Team ID: your 10-char team ID
  - Key ID: from the key you created
  - Private Key: full contents of the `.p8` file

---

## 4. Supabase Auth — URL Configuration

- Authentication → **URL Configuration**
  - **Site URL:** `https://libber.vercel.app`
  - **Redirect URLs** — add: `https://libber.vercel.app/apps/customer/save.html`

---

## 5. Supabase Auth — Allow Automatic Identity Linking

- Authentication → **Configuration (Sign In / Providers)**
- Enable: **Allow automatic identity linking**

**Why this matters:** When a user has already saved their points on their phone (linked Google/Apple), opening the app on a laptop creates a fresh anonymous session. When they tap "Continue with Google" on the laptop, `linkIdentity` is called with a Google identity that already belongs to their phone account. With automatic identity linking ON, Supabase detects this and signs them in as their existing account — cross-device access works. With it OFF, the sign-in silently fails and they land on the home page with no points visible.

The `handleCallback()` fix deployed today handles both outcomes correctly:
- **Success:** shows "Points saved" then redirects home (points visible)
- **Failure:** shows the sign-in form again with an error message after 8 seconds

---

## 6. Known Gap — Magic Link on Free Tier

Supabase's free tier rate-limits outbound email to approximately **3 emails per hour**. For any real usage, a custom SMTP provider needs to be configured:

- Authentication → **Email** (or Settings → SMTP)
- Options: Resend, Postmark, SendGrid, AWS SES

This is not blocking for testing but will block real users from saving their points via magic link at any meaningful volume.

---

## Session Summary — What Was Done Today (2026-05-10)

### Customer page cleanup
- Default theme changed from `min` to `mid` — new users see store thumbnails by default
- "Tap to show staff" header label replaced with "Your ID" from first load — removed the localStorage-based label update that changed it after first tap
- Cog glow animation removed — the green pulse on the gear icon was competing with the save-prompt glow; only the save-prompt button now glows when new points arrive
- Auto-notification permission request removed — `requestNotificationPermission()` was firing at 4 seconds automatically; removed along with `maybeNotify()`

### Settings page simplified
- Removed: notifications section, display/theme picker, PWA install section — and all associated CSS and JS
- Settings page now shows only: linked account status (with provider icons), and a link to save.html if unlinked
- `settingsCog.js` deleted — it was fully orphaned after removing the glow

### Save page — providers reduced
- Facebook and GitHub buttons removed from `save.html`
- Three options only: Google, Apple, magic link (email)

### Save flow — critical bug fixed
- `handleCallback()` previously called `showView('view-success')` immediately on arrival at the callback URL, before verifying whether sign-in had actually succeeded
- If sign-in failed (identity conflict, automatic linking disabled, token expired), the user saw "Points saved. Taking you back…" then landed on the home page with no points — a completely misleading experience
- **Fix:** show a neutral `view-loading` state first. Only show `view-success` once `onAuthStateChange` confirms a non-anonymous user. If no confirmed session after 8 seconds, re-render the sign-in form with an error message so the user can retry

### Thumbnails on unjoined store cards
- `storeAvatar()` in `renderUser.js` was already exported — unjoined store cards in `renderStores.js` now render the same avatar (logo or initials) as joined cards
- Theme-gated to `mid`/`max` only, matching the behaviour of `renderUserStores`

### Cross-device sign-in analysis
- Magic link (`signInWithOtp`) handles cross-device naturally — Supabase signs in as the existing email user
- OAuth (`linkIdentity`) requires **Allow automatic identity linking** to be enabled in Supabase — without it, cross-device sign-in silently fails
- The `handleCallback()` fix above makes both the success and failure paths explicit and recoverable

---

## Supabase Project Reference

| Key | Value |
|---|---|
| Project ref | `flghcbrwqtburdywgcvk` |
| Supabase callback URI | `https://flghcbrwqtburdywgcvk.supabase.co/auth/v1/callback` |
| Live app | `https://libber.vercel.app` |
| Admin tool | Local only — `http://localhost:5173/adminstart.html` |
