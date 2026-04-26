# Libber — Dev & Testing Reference

## URLs

| Page | Local | Live |
|---|---|---|
| Customer | http://localhost:5173/apps/customer/ | https://libber.vercel.app/apps/customer/ |
| Staff picker | http://localhost:5173/apps/staff/ | https://libber.vercel.app/apps/staff/ |
| Staff tools | http://localhost:5173/apps/staff/page.html | https://libber.vercel.app/apps/staff/page.html |
| Manager tools | http://localhost:5173/apps/staff/manager.html | https://libber.vercel.app/apps/staff/manager.html |
| Admin (local only) | http://localhost:5173/adminstart.html | — not deployed — |

---

## Test Checklist

### Customer page

- [ ] Opens, anonymous auth fires, ID appears in header
- [ ] Joined stores load (from cache first, then fresh)
- [ ] "Join a store" section lists available stores; joining one adds it to your list
- [ ] Store card expands to show earn rules, redeem options, and last 10 transactions
- [ ] Save prompt hidden until at least 1 point is earned at any store
- [ ] Save prompt glows when new points arrive (award something via staff page, watch customer page update in real time)
- [ ] Tap the ID/header area → full-screen staff overlay appears in landscape; Done/tap outside dismisses it
- [ ] Refresh button reloads data without a full page reload

### Customer page — dev section

- [ ] Tap the blank strip at the very bottom of the page 7 times quickly → dev panel appears
- [ ] "Staff page" link navigates to `/apps/staff/`
- [ ] "Reset session" → confirm dialog → clears all local data → reloads as a brand new anonymous user (new ID appears)
- [ ] Dev section is NOT visible on fresh page load (confirm in browser devtools: no `.visible` class on `#dev-section`)

### Staff — store picker

- [ ] Lists stores you're approved for (staff or manager)
- [ ] Click a store → navigates to staff tools page for that store
- [ ] "Apply for a new store" section lists stores you're not yet staff for
- [ ] Applied stores show "Pending approval"
- [ ] Manager link visible if you're a manager of any store

### Staff — tools page

- [ ] "← My Stores" button returns to the store picker
- [ ] Member list loads; balances shown
- [ ] Filter input hidden when fewer than 10 members; visible at 10+
- [ ] Click a member → panel opens with their balance

#### Quick award
- [ ] Quick-award buttons shown (from `kind = 'award'` rules)
- [ ] Tapping an award button awards points and updates the member's balance

#### Bonus
- [ ] Bonus reason buttons shown (from `kind = 'bonus_reason'` rules)
- [ ] Bonus amount buttons shown (from `kind = 'bonus_amount'` rules); amounts above the cap hidden
- [ ] Award button disabled until both a reason and an amount are selected
- [ ] Awarding bonus updates balance; reason and selection reset after

#### Adjust
- [ ] Adjust input accepts positive and negative integers
- [ ] Reason field required; Apply button disabled until both are filled
- [ ] Positive adjust increases balance; negative decreases it

#### Redeem
- [ ] Redeem buttons shown (from `kind = 'redeem'` rules)
- [ ] Redeem deducts points; balance updates

### Manager tools

- [ ] Lists managed stores
- [ ] Click store → shows pending applicants and current staff
- [ ] Approve applicant → moves to staff list
- [ ] Reject applicant → removed from list
- [ ] Remove staff member works
- [ ] Refresh button reloads without full page reload

### Admin tool (local only)

- [ ] Your public ID shown at top
- [ ] Create a store
- [ ] Add rules: `award`, `redeem`, `bonus_reason`, `bonus_amount`
- [ ] `bonus_reason` rule: label required, no points value
- [ ] `bonus_amount` rule: points value required, label optional
- [ ] Drag to reorder rules
- [ ] Set bonus cap for a store
- [ ] Assign/remove managers and staff

### Real-time

- [ ] With customer page open in one tab and staff tools in another: award points via staff → customer page updates balance automatically without a refresh

---

## Reset for a fresh test user

On the customer page, trigger the dev section (7 taps on the footer strip) and tap **Reset session**. Reloads as a completely new anonymous user with no memberships or history.
