# Automated Test Plan — Libber Staff & Points Platform

**Version:** 1.0
**Date:** 2026-05-01
**Status:** Ready for implementation

---

## 0. Guiding Principles

- Tests never touch the production database. All suites run against a dedicated test Supabase project with seed data only.
- Each suite is self-contained: setup and teardown are part of the suite, not manual steps.
- Security tests call RPCs and table endpoints directly using the Supabase JS client — the same surface a real caller uses — not internal DB connections.
- The plan is modular: each section maps to one file or folder. Adding a new flow means adding one new module.

---

## 1. Tooling Recommendations

| Layer | Tool | Rationale |
|-------|------|-----------|
| Unit | **Vitest** | Same bundler as Vite; runs in Node with zero config change |
| Integration (RPC/RLS) | **Vitest** + **@supabase/supabase-js** | Call real RPCs against the test project; catches DB-level regressions |
| End-to-end | **Playwright** | Runs a real Chromium against the Vite dev server; handles DOM, overlays, modals |
| API mocking (unit only) | **vi.fn() / vi.mock()** | Isolate service functions from the network |
| Seed data | **Supabase CLI (`supabase db reset`)** | Deterministic baseline on every run |
| CI | **GitHub Actions** | Runs all three layers on every PR |

**Estimated total runtime per CI run:**

- Unit: ~15 s
- Integration: ~90 s (network-bound)
- E2E: ~4–6 min (browser spin-up + scenarios)

---

## 2. Test Environment Setup

### 2.1 Seed Data Contract

Every suite assumes this baseline exists after `supabase db reset`:

```
stores:
  store-A (id: STORE_A_UUID)
  store-B (id: STORE_B_UUID)

admins:
  admin-user (ADMIN_UUID)

store_managers:
  manager-user at store-A (MANAGER_UUID)

store_staff:
  staff-user at store-A (STAFF_UUID)

store_memberships:
  customer-A (CUSTOMER_A_UUID) → store-A, balance 200
  customer-B (CUSTOMER_B_UUID) → store-A, balance 0

store_reward_rules (store-A):
  award-rule-1:    kind=award,        points=50,  label="Coffee",     active=true
  redeem-rule-1:   kind=redeem,       points=100, label="Free drink", active=true
  redeem-rule-2:   kind=redeem,       points=300, label="Gift card",  active=true
  bonus-reason-1:  kind=bonus_reason, points=0,   label="Birthday"
  bonus-amount-1:  kind=bonus_amount, points=25

max_bonus_points: 50 for store-A
```

### 2.2 Auth Sessions

Each test obtains a real Supabase anon-auth session for the relevant identity. Helper:

```js
// test/helpers/auth.js
export async function signInAs(role) {
  const sessions = {
    admin:     { email: 'admin@test.local',    password: '...' },
    manager:   { email: 'manager@test.local',  password: '...' },
    staff:     { email: 'staff@test.local',    password: '...' },
    customerA: { email: 'custA@test.local',    password: '...' },
    customerB: { email: 'custB@test.local',    password: '...' },
    stranger:  { email: 'stranger@test.local', password: '...' },
  }
  return supabase.auth.signInWithPassword(sessions[role])
}
```

---

## 3. Unit Tests — Service Functions

**Location:** `test/unit/services/`
**Runner:** Vitest with `vi.mock('../lib/supabase.js')`
**Duration estimate:** ~15 s

These tests assert that service functions call the RPC/table with the correct parameters and handle success/error responses correctly. The Supabase client is mocked — no network.

### 3.1 `awardPoints`

```js
// test/unit/services/members.test.js

describe('awardPoints', () => {
  it('calls award_points RPC with all five params when ruleId is provided', async () => {
    mockRpc.mockResolvedValue({ error: null })
    await awardPoints(USER_ID, STORE_ID, 50, 'Coffee', RULE_ID)
    expect(mockRpc).toHaveBeenCalledWith('award_points', {
      p_user_id:  USER_ID,
      p_store_id: STORE_ID,
      p_points:   50,
      p_reason:   'Coffee',
      p_rule_id:  RULE_ID
    })
  })

  it('omits p_rule_id when not provided', async () => {
    await awardPoints(USER_ID, STORE_ID, 25, 'Birthday')
    expect(mockRpc.mock.calls[0][1]).not.toHaveProperty('p_rule_id')
  })

  it('returns { error } on RPC failure', async () => {
    mockRpc.mockResolvedValue({ error: { message: 'not authorized' } })
    const { error } = await awardPoints(USER_ID, STORE_ID, 50, 'test')
    expect(error.message).toBe('not authorized')
  })
})
```

### 3.2 `adjustPoints`

```js
describe('adjustPoints', () => {
  it('passes all four params to adjust_points', async () => { ... })
  it('returns error on zero points (RPC raises)', async () => { ... })
})
```

### 3.3 `loadMemberRecentTransactions`

```js
describe('loadMemberRecentTransactions', () => {
  it('calls RPC with p_user_id and p_store_id', async () => { ... })

  it('returns data: [] when RPC returns null', async () => {
    mockRpc.mockResolvedValue({ data: null, error: null })
    const { data } = await loadMemberRecentTransactions(USER_ID, STORE_ID)
    expect(data).toEqual([])
  })

  it('calls captureError when RPC fails', async () => { ... })
})
```

### 3.4 `loadMembers`

```js
describe('loadMembers', () => {
  it('maps toHumanId over returned members and sets state.members', async () => { ... })
  it('sets state.members to [] on RPC error', async () => { ... })
})
```

### 3.5 `admin.js` service functions

```js
describe('insertRewardRule', () => {
  it('calls admin_insert_reward_rule with store_id, label, points, kind, sort_order', () => { ... })
})

describe('removeStore', () => {
  it('calls admin_remove_store with p_store_id', () => { ... })
})
```

---

## 4. Integration Tests — RPC & RLS

**Location:** `test/integration/`
**Runner:** Vitest (no mocking — real Supabase test project)
**Duration estimate:** ~90 s

Each test signs in as a specific role, calls an RPC or direct table query, and asserts the result. This layer catches auth regressions that unit tests cannot.

### 4.1 `award_points`

```js
describe('award_points RPC', () => {

  it('staff can award points using a valid rule', async () => {
    await signInAs('staff')
    const { data, error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID,
      p_points:   50,
      p_reason:   'Coffee',
      p_rule_id:  AWARD_RULE_1_UUID
    })
    expect(error).toBeNull()
    expect(data).toBe(250) // 200 + 50
  })

  it('rejects award with wrong store's rule', async () => {
    await signInAs('staff')
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID,
      p_points:   50,
      p_reason:   'test',
      p_rule_id:  STORE_B_RULE_UUID
    })
    expect(error.message).toMatch(/invalid rule/)
  })

  it('rejects redemption with no rule_id', async () => {
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID,
      p_points:   -100,
      p_reason:   'redeem'
      // p_rule_id intentionally omitted
    })
    expect(error.message).toMatch(/p_rule_id required/)
  })

  it('rejects when balance would go negative', async () => {
    await signInAs('staff')
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_B_UUID, // balance = 0
      p_store_id: STORE_A_UUID,
      p_points:   -100,
      p_reason:   'redeem',
      p_rule_id:  REDEEM_RULE_1_UUID
    })
    expect(error.message).toMatch(/insufficient points/)
  })

  it('rejects zero points', async () => {
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID,
      p_points:   0,
      p_reason:   'test'
    })
    expect(error.message).toMatch(/cannot be zero/)
  })

  it('rejects bonus exceeding store cap', async () => {
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID,
      p_points:   75, // cap is 50
      p_reason:   'big bonus'
    })
    expect(error.message).toMatch(/bonus cap/)
  })

  it('rejects unauthenticated call', async () => {
    await supabase.auth.signOut()
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID,
      p_points:   50,
      p_reason:   'test'
    })
    expect(error.message).toMatch(/not authenticated/)
  })

  it('rejects stranger (not staff of the store)', async () => {
    await signInAs('stranger')
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID,
      p_points:   50,
      p_reason:   'test'
    })
    expect(error.message).toMatch(/not authorized/)
  })

  it('rejects staff at store-A trying to award at store-B', async () => {
    await signInAs('staff')
    const { error } = await supabase.rpc('award_points', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_B_UUID,
      p_points:   50,
      p_reason:   'test'
    })
    expect(error.message).toMatch(/not authorized/)
  })
})
```

### 4.2 `adjust_points`

```js
describe('adjust_points RPC', () => {
  it('staff can apply a positive adjustment', async () => { ... })
  it('staff can apply a negative adjustment (may go below zero)', async () => { ... })
  it('rejects zero amount', async () => { ... })
  it('rejects stranger', async () => { ... })
})
```

### 4.3 `load_member_recent_transactions`

```js
describe('load_member_recent_transactions RPC', () => {
  beforeAll(async () => {
    // seed 7 ledger entries for customer-A at store-A
  })

  it('returns exactly 5 entries regardless of ledger size', async () => {
    await signInAs('staff')
    const { data } = await supabase.rpc('load_member_recent_transactions', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID
    })
    expect(data).toHaveLength(5)
  })

  it('entries are ordered newest first', async () => {
    const { data } = await supabase.rpc('load_member_recent_transactions', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID
    })
    const dates = data.map(e => new Date(e.created_at).getTime())
    expect(dates).toEqual([...dates].sort((a, b) => b - a))
  })

  it('entry shape contains only points, reason, created_at', async () => {
    const { data } = await supabase.rpc('load_member_recent_transactions', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID
    })
    const entry = data[0]
    expect(Object.keys(entry).sort()).toEqual(['created_at', 'points', 'reason'])
  })

  it('returns empty array for member with no transactions', async () => {
    await signInAs('staff')
    const { data } = await supabase.rpc('load_member_recent_transactions', {
      p_user_id:  CUSTOMER_B_UUID,
      p_store_id: STORE_A_UUID
    })
    expect(data).toEqual([])
  })

  it('rejects stranger', async () => { ... })
  it('rejects staff from store-A querying store-B data', async () => { ... })
  it('rejects customer (not staff)', async () => { ... })
})
```

### 4.4 `load_store_members`

```js
describe('load_store_members RPC', () => {
  it('returns user_id, public_id, balance for each member', async () => {
    await signInAs('staff')
    const { data } = await supabase.rpc('load_store_members', { p_store_id: STORE_A_UUID })
    expect(
      data.every(m => m.user_id && m.public_id !== undefined && typeof m.balance === 'number')
    ).toBe(true)
  })

  it('does not return members of other stores', async () => {
    const { data } = await supabase.rpc('load_store_members', { p_store_id: STORE_A_UUID })
    const ids = data.map(m => m.user_id)
    expect(ids).not.toContain(STORE_B_ONLY_CUSTOMER_UUID)
  })

  it('customer cannot call this RPC', async () => {
    await signInAs('customerA')
    const { error } = await supabase.rpc('load_store_members', { p_store_id: STORE_A_UUID })
    expect(error).not.toBeNull()
  })
})
```

### 4.5 `approve_staff_applicant`

```js
describe('approve_staff_applicant RPC', () => {
  it('manager can promote a store member to staff', async () => {
    await signInAs('manager')
    const { error } = await supabase.rpc('approve_staff_applicant', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_A_UUID
    })
    expect(error).toBeNull()

    // Verify store_staff row was created
    const { data } = await supabase
      .from('store_staff')
      .select('user_id')
      .eq('user_id', CUSTOMER_A_UUID)
      .eq('store_id', STORE_A_UUID)
    expect(data).toHaveLength(1)
  })

  it('rejects promotion of a non-member', async () => {
    await signInAs('manager')
    const { error } = await supabase.rpc('approve_staff_applicant', {
      p_user_id:  NON_MEMBER_UUID,
      p_store_id: STORE_A_UUID
    })
    expect(error.message).toMatch(/not a member/)
  })

  it('rejects manager promoting at a store they do not manage', async () => {
    await signInAs('manager') // manages store-A only
    const { error } = await supabase.rpc('approve_staff_applicant', {
      p_user_id:  CUSTOMER_A_UUID,
      p_store_id: STORE_B_UUID
    })
    expect(error.message).toMatch(/not authorized/)
  })

  it('is idempotent — second call does not error', async () => {
    await signInAs('manager')
    await supabase.rpc('approve_staff_applicant', {
      p_user_id: CUSTOMER_A_UUID, p_store_id: STORE_A_UUID
    })
    const { error } = await supabase.rpc('approve_staff_applicant', {
      p_user_id: CUSTOMER_A_UUID, p_store_id: STORE_A_UUID
    })
    expect(error).toBeNull()
  })
})
```

### 4.6 RLS — Direct Table Access

```js
describe('RLS: points_ledger direct query', () => {
  it('customer sees only their own rows', async () => {
    await signInAs('customerA')
    const { data } = await supabase.from('points_ledger').select('user_id')
    expect(data.every(r => r.user_id === CUSTOMER_A_UUID)).toBe(true)
  })

  it('customer cannot insert directly', async () => {
    await signInAs('customerA')
    const { error } = await supabase.from('points_ledger').insert({
      user_id:         CUSTOMER_A_UUID,
      store_id:        STORE_A_UUID,
      points:          9999,
      reason:          'fraud',
      running_balance: 9999
    })
    expect(error).not.toBeNull()
  })

  it('staff cannot read another customer's ledger rows directly', async () => {
    await signInAs('staff')
    const { data } = await supabase
      .from('points_ledger')
      .select('user_id')
      .eq('user_id', CUSTOMER_A_UUID)
    // RLS: staff user_id ≠ CUSTOMER_A_UUID → own-row policy returns nothing
    expect(data).toHaveLength(0)
  })
})

describe('RLS: store_staff direct write', () => {
  it('authenticated user cannot insert into store_staff', async () => {
    await signInAs('stranger')
    const { error } = await supabase
      .from('store_staff')
      .insert({ user_id: STRANGER_UUID, store_id: STORE_A_UUID })
    expect(error).not.toBeNull()
  })
})

describe('RLS: profiles', () => {
  it('customer can read only their own profile row', async () => {
    await signInAs('customerA')
    const { data } = await supabase.from('profiles').select('user_id')
    expect(data).toHaveLength(1)
    expect(data[0].user_id).toBe(CUSTOMER_A_UUID)
  })

  it('admin can read all profile rows', async () => {
    await signInAs('admin')
    const { data } = await supabase.from('profiles').select('user_id')
    expect(data.length).toBeGreaterThan(1)
  })
})

describe('RLS: stores direct write', () => {
  it('authenticated user cannot insert a store directly', async () => {
    await signInAs('manager')
    const { error } = await supabase.from('stores').insert({ name: 'rogue store' })
    expect(error).not.toBeNull()
  })
})

describe('RLS: admins table', () => {
  it('authenticated user cannot read admins table', async () => {
    await signInAs('staff')
    const { data } = await supabase.from('admins').select('user_id')
    // Returns empty or error — either is acceptable; the admin UUID must not appear
    const ids = (data || []).map(r => r.user_id)
    expect(ids).not.toContain(ADMIN_UUID)
  })
})
```

### 4.7 Admin RPCs

```js
describe('admin_create_store', () => {
  it('admin can create a store', async () => {
    await signInAs('admin')
    const { data, error } = await supabase.rpc('admin_create_store', { p_name: 'New Store' })
    expect(error).toBeNull()
    expect(data.name).toBe('New Store')
  })

  it('non-admin (manager) cannot create a store', async () => {
    await signInAs('manager')
    const { error } = await supabase.rpc('admin_create_store', { p_name: 'Rogue' })
    expect(error.message).toMatch(/not authorized/i)
  })
})

describe('admin_set_bonus_cap', () => {
  it('admin can set cap', async () => { ... })
  it('admin can remove cap by passing null', async () => { ... })
  it('rejects cap < 1', async () => { ... })
  it('non-admin is rejected', async () => { ... })
})

describe('admin_remove_store', () => {
  it('deletes store and all related data in one call', async () => {
    await signInAs('admin')
    await supabase.rpc('admin_remove_store', { p_store_id: EPHEMERAL_STORE_UUID })

    const { data } = await supabase
      .from('stores')
      .select('id')
      .eq('id', EPHEMERAL_STORE_UUID)
    expect(data).toHaveLength(0)

    // Also assert points_ledger, store_staff, store_memberships are gone
    const { data: ledger } = await supabase
      .from('points_ledger')
      .select('id')
      .eq('store_id', EPHEMERAL_STORE_UUID)
    expect(ledger).toHaveLength(0)
  })
})
```

---

## 5. End-to-End Tests — Browser (Playwright)

**Location:** `test/e2e/`
**Runner:** Playwright against `vite dev` pointed at the test Supabase project
**Duration estimate:** ~4–6 min

All E2E tests use `page.goto('/apps/staff/page.html')` with a pre-seeded test session cookie (use Playwright `storageState` to avoid re-logging in on every test).

### 5.1 Award Points Flow

```js
test('staff awards points via quick-award button', async ({ page }) => {
  await page.goto('/apps/staff/page.html')
  await page.click('[data-store-id="STORE_A_UUID"]')
  await page.click('[data-user-id="CUSTOMER_A_UUID"] .customer-row')

  const btn = page.locator('.quick-btn').first()
  await btn.click()

  // Confirm dialog appears
  await expect(page.locator('#confirmTitle')).toBeVisible()
  await page.click('#confirmOk')

  // Button enters done state
  await expect(btn).toHaveClass(/done/)
  await expect(btn.locator('.btn-label')).toHaveText('awarded')

  // Status message includes point value
  await expect(page.locator('#status')).toContainText('Points awarded')
  await expect(page.locator('#status')).toContainText('pts')

  // Panel balance increases
  const newBalance = parseInt(await page.locator('#panelBalance').textContent())
  expect(newBalance).toBeGreaterThan(200)
})
```

### 5.2 Bonus Award Flow

```js
test('staff awards a bonus with reason and amount', async ({ page }) => {
  await page.click('.bonus-reason-btn:has-text("Birthday")')
  await page.click('.bonus-btn:has-text("+25")')

  // Confirm section appears with correct details
  await expect(page.locator('#bonusConfirm')).toBeVisible()
  await expect(page.locator('#bonusConfirmMsg')).toContainText('Birthday')
  await expect(page.locator('#bonusConfirmMsg')).toContainText('+25 pts')

  await page.click('#bonusConfirmOk')

  // Status message shows amount
  await expect(page.locator('#status')).toContainText('Bonus awarded')
  await expect(page.locator('#status')).toContainText('+25 pts')
})
```

### 5.3 Redeem Points Flow

```js
test('redeem button is enabled when customer has sufficient balance', async ({ page }) => {
  // customer-A has 200 pts; redeem-rule-1 costs 100
  const redeemBtn = page.locator('.redeem-btn').first()
  await expect(redeemBtn).not.toBeDisabled()
  await expect(redeemBtn).not.toHaveClass(/insufficient/)
})

test('redeem buttons are greyed out when customer has insufficient balance', async ({ page }) => {
  // customer-B has 0 pts
  await page.click('[data-user-id="CUSTOMER_B_UUID"] .customer-row')
  const redeemBtns = page.locator('.redeem-btn')

  for (const btn of await redeemBtns.all()) {
    await expect(btn).toBeDisabled()
    await expect(btn).toHaveClass(/insufficient/)
    const title = await btn.getAttribute('title')
    expect(title).toMatch(/Requires \d+ pts/)
    expect(title).toMatch(/member has 0 pts/)
  }
})

test('clicking greyed-out redeem button does nothing and shows no status', async ({ page }) => {
  await page.click('[data-user-id="CUSTOMER_B_UUID"] .customer-row')
  // Force click even though disabled (simulates direct DOM manipulation)
  await page.locator('.redeem-btn.insufficient').first().dispatchEvent('click')
  await expect(page.locator('#status')).toHaveText('')
})

test('insufficient points message appears when RPC rejects a redemption', async ({ page }) => {
  await page.route('**/rest/v1/rpc/award_points', route => route.fulfill({
    status: 400,
    body: JSON.stringify({ message: 'insufficient points: balance is 0' })
  }))
  await expect(page.locator('#status')).toContainText('Not enough points to redeem')
})
```

### 5.4 View History Flow

```js
test('history button appears left of member ID in each row', async ({ page }) => {
  const row    = page.locator('.customer-row').first()
  const histBtn = row.locator('.history-btn')
  const custId  = row.locator('.cust-id')

  await expect(histBtn).toBeVisible()

  // Confirm button is to the left (lower x coordinate)
  const btnBox = await histBtn.boundingBox()
  const idBox  = await custId.boundingBox()
  expect(btnBox.x).toBeLessThan(idBox.x)
})

test('clicking history button opens modal with transactions', async ({ page }) => {
  await page.locator('.customer-row').first().locator('.history-btn').click()

  await expect(page.locator('#historyOverlay')).toHaveClass(/open/)
  await expect(page.locator('#historyTitle')).toBeVisible()

  // Focus moves to close button on open
  await expect(page.locator('#historyClose')).toBeFocused()

  // Entries render — customer-A has transactions
  await expect(page.locator('.history-entry').first()).toBeVisible()
  const count = await page.locator('.history-entry').count()
  expect(count).toBeLessThanOrEqual(5)
})

test('history modal shows empty state when no transactions', async ({ page }) => {
  await page.locator('[data-user-id="CUSTOMER_B_UUID"] .history-btn').click()
  await expect(page.locator('#historyBody')).toContainText('No transactions yet')
})

test('history modal closes on Escape key', async ({ page }) => {
  await page.locator('.history-btn').first().click()
  await expect(page.locator('#historyOverlay')).toHaveClass(/open/)
  await page.keyboard.press('Escape')
  await expect(page.locator('#historyOverlay')).not.toHaveClass(/open/)
})

test('history modal closes on backdrop click', async ({ page }) => {
  await page.locator('.history-btn').first().click()
  await page.locator('#historyOverlay').click({ position: { x: 10, y: 10 } })
  await expect(page.locator('#historyOverlay')).not.toHaveClass(/open/)
})

test('focus returns to history button after modal closes', async ({ page }) => {
  const histBtn = page.locator('.history-btn').first()
  await histBtn.click()
  await page.keyboard.press('Escape')
  await expect(histBtn).toBeFocused()
})

test('history RPC failure shows error and retry button', async ({ page }) => {
  await page.route('**/rest/v1/rpc/load_member_recent_transactions', route =>
    route.fulfill({ status: 500, body: JSON.stringify({ message: 'internal error' }) })
  )
  await page.locator('.history-btn').first().click()
  await expect(page.locator('#historyBody')).toContainText('Could not load history')
  await expect(page.locator('#historyRetryBtn')).toBeVisible()
})

test('clicking history button does not open member panel', async ({ page }) => {
  await page.locator('.customer-row').first().locator('.history-btn').click()
  // Member panel must remain closed
  await expect(page.locator('#overlay')).not.toHaveClass(/open/)
  // History modal must be open
  await expect(page.locator('#historyOverlay')).toHaveClass(/open/)
})
```

### 5.5 Member Panel — General

```js
test('clicking a member row (not the history button) opens the member panel', async ({ page }) => {
  await page.locator('.customer-row').first().locator('.cust-id').click()
  await expect(page.locator('#overlay')).toHaveClass(/open/)
  await expect(page.locator('#panelId')).not.toBeEmpty()
})

test('panel displays correct balance for selected member', async ({ page }) => {
  await page.locator('[data-user-id="CUSTOMER_A_UUID"] .cust-id').click()
  await expect(page.locator('#panelBalance')).toHaveText('200')
})

test('panel balance updates immediately after award without page reload', async ({ page }) => {
  await page.locator('[data-user-id="CUSTOMER_A_UUID"] .cust-id').click()
  const initial = parseInt(await page.locator('#panelBalance').textContent())

  await page.locator('.quick-btn').first().click()
  await page.locator('#confirmOk').click()

  await expect(page.locator('#panelBalance')).toHaveText(String(initial + 50))
})
```

### 5.6 Search / Filter

```js
test('search hides non-matching members', async ({ page }) => {
  await page.locator('#search').fill('ZZZNOMATCH')
  await expect(page.locator('#memberCount')).toContainText('0 of')
  await expect(page.locator('.customer-row')).toHaveCount(0)
})

test('search is case-insensitive and ignores hyphens', async ({ page }) => {
  const id      = await page.locator('.cust-id').first().textContent()
  const stripped = id.replace(/-/g, '').toUpperCase()
  await page.locator('#search').fill(stripped)
  await expect(page.locator('.customer-row')).toHaveCount(1)
})
```

---

## 6. Concurrent Operations Test

**Location:** `test/integration/concurrency.test.js`
**Duration estimate:** ~20 s (parallel requests)

```js
test('two concurrent award_points calls produce a correct final balance', async () => {
  // Two independent Supabase clients — two separate staff sessions
  const clientA = createClient(URL, ANON_KEY)
  const clientB = createClient(URL, ANON_KEY)
  await clientA.auth.signInWithPassword(STAFF_CREDENTIALS)
  await clientB.auth.signInWithPassword(STAFF_CREDENTIALS_2)

  const params = {
    p_user_id:  CUSTOMER_A_UUID,
    p_store_id: STORE_A_UUID,
    p_points:   50,
    p_reason:   'concurrent test',
    p_rule_id:  AWARD_RULE_1_UUID
  }

  const [resultA, resultB] = await Promise.all([
    clientA.rpc('award_points', params),
    clientB.rpc('award_points', params)
  ])

  // Count how many succeeded — one or both may succeed
  const successCount   = [resultA, resultB].filter(r => !r.error).length
  const expectedBalance = 200 + (50 * successCount)

  // Verify the ledger's running_balance matches exactly
  const { data: ledger } = await clientA
    .from('points_ledger')
    .select('running_balance')
    .eq('user_id', CUSTOMER_A_UUID)
    .eq('store_id', STORE_A_UUID)
    .order('created_at', { ascending: false })
    .limit(1)

  expect(ledger[0].running_balance).toBe(expectedBalance)
})
```

---

## 7. Edge Case Matrix

| Scenario | RPC / Layer | Expected Result | Test Location |
|----------|-------------|-----------------|---------------|
| `p_points = 0` | `award_points` | raise `points cannot be zero` | integration |
| `p_points = -0` | `award_points` | raise `points cannot be zero` | integration |
| Invalid UUID format for `p_rule_id` | `award_points` | PostgreSQL UUID cast error | integration |
| `p_rule_id` from wrong store | `award_points` | raise `invalid rule` | integration |
| Inactive rule used | `award_points` | raise `invalid rule` | integration |
| Redeem rule used for award | `award_points` | raise `invalid rule for this award` | integration |
| Award rule used for redemption | `award_points` | raise `invalid rule for this redemption` | integration |
| Balance exactly equal to redeem cost | `award_points` | succeeds, new balance = 0 | integration |
| Balance exactly 1 below redeem cost | `award_points` | raise `insufficient points` | integration |
| `p_store_id` does not exist | `award_points` | FK violation or auth failure | integration |
| Non-member `p_user_id` in `approve_staff_applicant` | RPC | raise `not a member` | integration |
| History for member with exactly 5 ledger entries | `load_member_recent_transactions` | returns 5 | integration |
| History for member with 6+ ledger entries | `load_member_recent_transactions` | returns exactly 5 | integration |
| Bonus amount > store cap | `award_points` | raise `bonus cap` | integration |
| Null store cap + any bonus amount | `award_points` | succeeds | integration |

---

## 8. Accessibility Tests (Playwright + Axe)

```js
import { checkA11y, injectAxe } from 'axe-playwright'

test('staff page has no axe violations on load', async ({ page }) => {
  await page.goto('/apps/staff/page.html')
  await injectAxe(page)
  await checkA11y(page, null, { runOnly: ['wcag2a', 'wcag2aa'] })
})

test('history modal has no axe violations when open', async ({ page }) => {
  await page.locator('.history-btn').first().click()
  await expect(page.locator('#historyOverlay')).toHaveClass(/open/)
  await checkA11y(page, '#historyOverlay')
})

test('greyed-out redeem buttons have descriptive title attributes', async ({ page }) => {
  await page.locator('[data-user-id="CUSTOMER_B_UUID"] .cust-id').click()
  const titles = await page.locator('.redeem-btn.insufficient').evaluateAll(
    btns => btns.map(b => b.getAttribute('title'))
  )
  expect(titles.every(t => t && t.includes('Requires'))).toBe(true)
})
```

---

## 9. Sentry Integration Smoke Test

```js
// test/unit/services/members.test.js — extend existing suite

it('calls captureError when loadMemberRecentTransactions fails', async () => {
  const { captureError } = await import('../lib/sentry.js')
  vi.spyOn({ captureError }, 'captureError')

  mockRpc.mockResolvedValue({ data: null, error: { message: 'timeout' } })
  await loadMemberRecentTransactions(USER_ID, STORE_ID)

  expect(captureError).toHaveBeenCalledWith(
    expect.objectContaining({ message: 'timeout' }),
    expect.objectContaining({ fn: 'loadMemberRecentTransactions' })
  )
})
```

---

## 10. Maintainability Guidelines

### When an RPC signature changes

1. Update the corresponding integration test params.
2. Update the unit test mock assertions for that service function.
3. Search for `'rpc_name'` across `test/` to find all usages.

### When a new RPC is added

1. Create `test/integration/rpcs/new-rpc.test.js`.
2. Add at minimum: unauthenticated call, wrong-role call, valid call, at least one edge case.
3. Add the new RPC name and any UUID constants to `test/helpers/constants.js`.

### When an RLS policy changes

1. The policy name appears in `docs/security-contract.md` — find its invariant tag (`INV-*`).
2. Locate the corresponding RLS test block in `test/integration/rls.test.js` by that tag.
3. Update the assertion to match the new policy behaviour.

### When a UI string changes

1. Exact strings are defined once in `src/ui/renderCustomers.js` — search `test/e2e/` for the old string and update.
2. E2E tests use `toContainText` (partial match) rather than `toHaveText` where possible, so minor phrasing changes don't break the full suite.

### Seed data

All test UUIDs are constants in `test/helpers/constants.js`. Never hardcode a UUID directly in a test file — always import from constants.

---

## 11. CI Pipeline Structure

```yaml
# .github/workflows/test.yml

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npm run test:unit          # vitest run test/unit/

  integration:
    runs-on: ubuntu-latest
    needs: unit
    env:
      SUPABASE_URL:      ${{ secrets.TEST_SUPABASE_URL }}
      SUPABASE_ANON_KEY: ${{ secrets.TEST_ANON_KEY }}
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: supabase db reset --db-url $TEST_DB_URL
      - run: npm run test:integration   # vitest run test/integration/

  e2e:
    runs-on: ubuntu-latest
    needs: unit
    env:
      SUPABASE_URL:      ${{ secrets.TEST_SUPABASE_URL }}
      SUPABASE_ANON_KEY: ${{ secrets.TEST_ANON_KEY }}
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: supabase db reset --db-url $TEST_DB_URL
      - run: npx playwright install chromium
      - run: npm run test:e2e           # playwright test
```

> Integration and E2E run in parallel after unit passes. Estimated total wall-clock time: **~6 min**.

---

## 12. Critical Areas — Must Never Fail

The following failures indicate a broken security or data-integrity guarantee, not a UX regression. Any failure here must **block the PR immediately**.

| # | Invariant | Test Reference |
|---|-----------|----------------|
| 1 | A customer cannot read another customer's ledger rows via direct query | `RLS: points_ledger direct query` |
| 2 | A stranger (no store role) cannot call `award_points` | `award_points → rejects stranger` |
| 3 | Staff at Store A cannot award points at Store B | `award_points → rejects staff at wrong store` |
| 4 | A redemption without `p_rule_id` is always rejected | `award_points → rejects redemption with no rule_id` |
| 5 | Balance cannot go negative via `award_points` | `award_points → rejects when balance would go negative` |
| 6 | No client can insert directly into `points_ledger` | `RLS: points_ledger → customer cannot insert directly` |
| 7 | No client can insert directly into `stores` or `store_reward_rules` | `RLS: stores direct write` |
| 8 | `load_member_recent_transactions` returns at most 5 rows | `load_member_recent_transactions → returns exactly 5` |
| 9 | A manager cannot promote a non-member to staff | `approve_staff_applicant → rejects non-member` |
| 10 | Non-admin cannot call any `admin_*` RPC | `admin_create_store → non-admin rejected` |

---

*This document is generated and maintained alongside the codebase. Update it whenever an RPC, RLS policy, or UI flow changes. Cross-reference with `docs/security-contract.md` for invariant tags.*
