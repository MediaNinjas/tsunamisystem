# Tsunami — Reference (schema, deploy, config)

## Supabase tables (inferred from client + edge functions)

Verify in Dashboard → Table Editor. No migrations in repo.

### `profiles`

| Column | Purpose |
|--------|---------|
| `id` | UUID, matches `auth.users.id` |
| `unlocked` | Boolean — paywall gate |
| `code_used` | Text — code or receipt reference after unlock |

Row creation mechanism not documented in repo — confirm signup trigger or first-login insert exists.

### `codes`

| Column | Purpose |
|--------|---------|
| `code` | Text, e.g. `TSU-XXXX-XXXX` |
| `used` | Boolean |
| `used_by` | User id when redeemed |
| `used_at` | Timestamp |
| `stripe_session_id` | Set by webhook (optional) |
| `paypal_order_id` | Set by PayPal flow (optional) |
| `type` | NOT NULL — CHECK (`free` = promo/admin, `paid` = Stripe/PayPal) |
| `max_uses` / `use_count` | Multi-use support |

Admin generates unused codes (`used: false`). Stripe webhook inserts with `used: true` as receipt record.

### `cards`

| Column | Purpose |
|--------|---------|
| `user_id` | FK to user |
| `card_data` | JSONB array of card objects (see below) |
| `updated_at` | Timestamp |

**Card object fields** (in `card_data` JSON): `id`, `name`, `balance`, `limit`, `minPayment`, `interest`, `tsunami`, `credentials`, `due`, `promoOn`, `promoMonths`, `promoApr`, `promoWarn`, `promoEnd`, `dismissed`, `paid`, `empty`.

**Cloud `card_data` shapes:**
- Legacy: bare array of card objects
- v2: `{ v: 2, cards: [...], planner: { [cardId]: { pages, page } } }` — planner slots sync with cards

Also cached in localStorage as `tsunami_planner_v1_<userId>`.

## RLS expectations (verify in Dashboard)

Client-side code assumes authenticated users can:

- **Read** own `profiles`, own `cards` row
- **Update** own `profiles.unlocked` and `code_used` (paywall unlock via code/PayPal)
- **Select** `codes` where `used = false`; **update** matched code to `used = true`
- **Insert** into `codes` (PayPal path inserts; admin insert for new codes)

If RLS is too permissive, users could unlock without paying. If too strict, PayPal/code flows fail silently. **Audit policies before shipping paywall changes.**

`stripe-webhook` uses **service role** — bypasses RLS (correct).

## Supabase secrets (names only — set via `supabase secrets set`)

| Secret | Used by |
|--------|---------|
| `STRIPE_SECRET_KEY` | create-checkout, stripe-webhook |
| `TSUNAMI_PRICE_ID` | create-checkout (`price_1TrsHhL15F7ly2P4GPshKTkL`) |
| `STRIPE_WEBHOOK_SECRET` | stripe-webhook |
| `SITE_URL` | create-checkout success/cancel URLs — must match live app origin |
| `SUPABASE_URL` | edge functions (often auto) |
| `SUPABASE_SERVICE_ROLE_KEY` | stripe-webhook (`createClient` admin) |

**Important:** Webhook code reads `SUPABASE_SERVICE_ROLE_KEY`. If secrets were set under a different name (e.g. `SERVICE_ROLE_KEY`), the webhook will fail to unlock.

`SITE_URL` must be `https://tsunamiapp.medianinjas.tv`. Never bare `medianinjas.tv` (unrelated AV site). `create-checkout` allowlists the Tsunami subdomain (+ Netlify alias) and ignores wrong origins.

## Netlify

| Setting | Value |
|---------|--------|
| Site ID | `2de0ab90-46e8-4caf-b178-3756c19baa5d` |
| Publish directory | Repo root (`index.html` at root) |
| Config file | `netlify/netlify.toml` (publish path may point to full Windows path — verify in Netlify UI) |
| Function | `netlify/functions/send-backup.js` → `POST /.netlify/functions/send-backup` |
| Env | `RESEND_API_KEY` — from address `noreply@tsunamiapp.medianinjas.tv` |

## Stripe

- Product: Tsunami System Access — $20 one-time
- Test card: `4242 4242 4242 4242`, any future expiry, any CVC
- Webhook event: `checkout.session.completed`
- `client_reference_id` on session = Supabase user id

## Google OAuth (Supabase Auth)

- Provider enabled in Supabase
- Redirect URLs must include **both** any domain you use (`tsunamisystem.netlify.app`, custom domain)
- Front-end `redirectTo` in `signInWithGoogle()` must match an allowed redirect URL

## File map

```
index.html                          # entire app
supabase/functions/create-checkout/
supabase/functions/stripe-webhook/
netlify/functions/send-backup.js
netlify/netlify.toml
netlify/state.json                  # site id
.cursor/skills/tsunami/             # this skill
```

## Deploy checklist

- [ ] `SITE_URL` matches browser origin users actually use
- [ ] Google OAuth redirect URLs include that origin
- [ ] Stripe webhook URL live and signing secret matches
- [ ] `SUPABASE_SERVICE_ROLE_KEY` secret name matches webhook code
- [ ] Netlify `RESEND_API_KEY` set if email backup needed
- [ ] PayPal / Drive / Dropbox client IDs replaced if those paths go live
- [ ] `checkUnlocked()` gates all paths to `launchApp()`
- [ ] Main UI inside `#app-content`

## Open questions for Vincent

1. Confirm `profiles` row creation on signup — trigger or manual?
2. Exact RLS policies on `profiles`, `codes`, `cards` — export from Supabase?
3. Canonical production URL going forward: Netlify default or custom domain?
4. Should `tsunami_complete_status.md` (contains live keys) be deleted from disk and rotated?
5. Is PayPal still required or Stripe-only for launch?
6. Should planner payment slots persist to cloud?
