---
name: tsunami
description: >-
  Tsunami System debt-payoff app — monolithic index.html, Supabase auth/paywall,
  Stripe/PayPal unlock, Netlify hosting. Use when working on Tsunami (NOT Starship
  Phoenix Autoposter). Repo path ends in Products/Tsunami/files.
---

# Tsunami System — Agent Skill

## Identity

| | |
|---|---|
| **App** | Tsunami System — debt payoff / credit card planner |
| **NOT** | Starship Phoenix Autoposter (different project) |
| **Repo** | `https://github.com/MediaNinjas/tsunamisystem.git` |
| **Live URL** | `https://tsunamiapp.medianinjas.tv` (primary); `https://tsunamisystem.netlify.app` (alias) |
| **Not Tsunami** | Bare `medianinjas.tv` — separate AV site; never use for Stripe/OAuth redirects |
| **Supabase** | Project ref `fxrhddcexwklyfzzgnvz` · API `https://api.tsunamiapp.medianinjas.tv` |

## Architecture

- **Single file app:** `index.html` (~2,500 lines) — all HTML, CSS, vanilla JS inline. No build step, no framework.
- **Supabase Edge Functions:** `supabase/functions/create-checkout/`, `supabase/functions/stripe-webhook/`
- **Netlify:** static publish = repo root; serverless `netlify/functions/send-backup.js` (Resend email)
- **No SQL migrations in repo** — schema lives in Supabase dashboard. See `reference.md`.

## Auth & paywall (intended flow)

1. User signs in (email/password or Google OAuth).
2. `checkUnlocked(user)` reads `profiles.unlocked` for that user id.
3. If **not** unlocked → hide auth, show `#code-screen` (promo code, PayPal, Stripe).
4. If unlocked → `launchApp()` (hide auth + code screens, show app, load cards).

**Rules for agents:**

- Always gate with `checkUnlocked()` before `launchApp()` on session restore **and** `onAuthStateChange`. Committed `origin/main` did this; a local regression removed it and broke the paywall.
- Remove the `checkUnlocked` branch that auto-unlocks when `unlocked === undefined` — that bypasses payment unless RLS blocks it.
- `?dev=1` skips auth for local testing only — do not rely on it in production.
- Admin (`serano9@gmail.com`) can generate codes via Account menu: single-use (prompt for uses) or one-click **Generate 500-Use Code**. Codes support `max_uses` / `use_count`.

**Unlock paths:**

| Path | Mechanism |
|------|-----------|
| Promo code | Client validates unused row in `codes`, sets `profiles.unlocked` |
| PayPal | Client `onApprove` inserts used code + unlocks profile (RLS-dependent) |
| Stripe | `create-checkout` → Stripe → `stripe-webhook` sets unlock server-side |

**Stripe return:** `?stripe_success=1` should load session first, then poll `checkUnlocked` (webhook may lag). Current bug: poll can run before `currentUser` is set.

## Known structural bugs (fix with minimal diffs)

1. **`#app-content` DOM split** — Only header/settings modals are inside `#app-content`. Sort bar, summary, `#grid`, and `#ledger-view` are **siblings outside** it. `launchApp()` only toggles `#app-content`, so main UI is not properly gated. **Fix:** move sort/summary/grid/ledger inside `#app-content`.

2. **`plannerState` not persisted** — Payment planner slots live in memory only. `saveCards()` persists `cards` array, not `plannerState`. Committed payments update balance (saved); slot refs/dates/commits are lost on refresh.

3. **OAuth / Stripe URLs** — primary `https://tsunamiapp.medianinjas.tv` (also allow Netlify alias). Never bare `medianinjas.tv` (unrelated AV site).

4. **EmailJS dead code** — `emailjs` initialized in `<head>`; CSV backup uses `/.netlify/functions/send-backup` instead.

## Secrets & placeholders (never commit values)

| Item | Location | Status |
|------|----------|--------|
| Supabase publishable key | `index.html` `_supabase.createClient(...)` | Set |
| `STRIPE_SECRET_KEY`, `TSUNAMI_PRICE_ID`, `STRIPE_WEBHOOK_SECRET`, `SITE_URL` | Supabase secrets | Configured (see reference.md) |
| `SUPABASE_SERVICE_ROLE_KEY` | stripe-webhook only | Must match env var name in code |
| `YOUR_PAYPAL_CLIENT_ID` | `index.html` script tag | **Placeholder** |
| `GOOGLE_DRIVE_CLIENT_ID`, `DROPBOX_APP_KEY` | `index.html` JS vars | **Placeholders** |
| `RESEND_API_KEY` | Netlify env | Required for email backup |

Price ID for Stripe product "Tsunami System Access": `price_1TrsHhL15F7ly2P4GPshKTkL` ($20 one-time).

## Deployment

**Autonomy:** Commit and push `main` when work is done — do not wait for the user to say “deploy.”

**Important:** The Netlify site `tsunamisystem` is **not** linked to the GitHub repo for auto-deploy. Pushing `main` alone does **not** update production. Always also run a production deploy:

```bash
cd "<repo root>"
git add .
git commit -m "message"
git push origin main
npx netlify deploy --prod --dir=. --message "short note"
```

Live: `https://tsunamiapp.medianinjas.tv`

Edge functions:

```bash
supabase link --project-ref fxrhddcexwklyfzzgnvz
supabase functions deploy create-checkout
supabase functions deploy stripe-webhook --no-verify-jwt
```

`stripe-webhook` must be registered in Stripe Dashboard pointing at the Supabase function URL.

Local static test: `python -m http.server 8000` in repo root.

## Agent conventions

- **Minimize scope** — small targeted diffs; do not refactor to React/Vite unless asked.
- **Match style** — vanilla JS, inline CSS, Bebas Neue / DM Sans, existing naming.
- **Do not commit secrets** — no keys in git; use Supabase/Netlify dashboards.
- **Ship by default** — when a Tsunami fix is done, commit + push `main` **and** `npx netlify deploy --prod` (site is not GitHub-auto-deployed). Do not wait for “please deploy.”
- Card `credentials` field stores passwords in `cards.card_data` JSON — intentional for user convenience; do not log or expose.

## Feature status (as of July 2026)

| Feature | Status |
|---------|--------|
| Card grid, ledger, promo warnings, planner UI | Built |
| Settings modal (billing display, backups UI, delete flow) | Built (partial delete — no auth.users removal) |
| Supabase cloud card sync | Built |
| Stripe checkout + webhook | Backend deployed; frontend wired; redirect/SITE_URL needs verification |
| PayPal | Not configured (placeholder client id) |
| Google Drive / Dropbox backup | UI only (placeholder OAuth keys) |
| CSV email backup | Needs `RESEND_API_KEY` on Netlify |
| Early-adopter shared code (N uses) | Built — admin Generate 500-Use Code + multi-use redeem |

## When stuck

Read `reference.md` for table shapes, RLS expectations, deploy checklist, and open questions.
