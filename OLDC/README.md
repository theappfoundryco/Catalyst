# Catalyst — system map

Mission control for a Mac dev environment (native macOS SwiftUI app) + a Cloudflare backend +
a marketing site. This README is the **one place that says what runs where** so you never have to
hold it all in your head. Deeper detail lives in `goLive.md` (status/tracker),
`CatalystUnderstanding.md` (architecture), `Formrules.md` (conventions), `RELEASING.md` (release runbook).

**Golden rule:** the Mac app is never trusted. The Worker + D1 are the only source of truth; the app
just verifies a short-lived, server-signed Ed25519 entitlement JWT.

---

## Repos (5 git repos, all under github.com/imsg8)

| Repo | Folder | What it is | Deploy |
|---|---|---|---|
| `imsg8/Catalyst` (PRIVATE) | root | The Xcode app (SwiftUI). Also holds `Scripts/` release tooling + all docs. | Xcode build / `Scripts/cut_release.sh` |
| `imsg8/catalyst_worker` | `catalyst_worker/` | Cloudflare Worker — auth, entitlement, subscriptions, student, single-seat, Razorpay webhook. | `npx wrangler deploy` |
| `imsg8/theappfoundry` | `theappfoundryco/` | Astro marketing site "The App Foundry" (Vercel) + OTP serverless fn + Edge Config redirects. | push → Vercel auto-deploy |
| `imsg8/catalyst_cloudflare` | `catalyst_pages/` | Static read-only JSON on CF Pages (shortcuts/brew/popular/about). Link fields deprecated. | push → CF Pages |
| `imsg8/Catalyst_Releases` (PUBLIC) | `Catalyst_Releases/` | Sparkle artifacts + `appcast.xml` + release notes + `.github/` issue forms. | `Scripts/cut_release.sh` / manual push |

---

## Services — what manages what

| Service | Manages | Credentials / where | Touch it |
|---|---|---|---|
| **Cloudflare Workers** | All auth/entitlement/subscription/student/device API + Razorpay webhook | account login; code in `catalyst_worker/src/index.ts` | `npx wrangler deploy` (live: `catalyst-api.shivanggulati817.workers.dev`) |
| **Cloudflare D1** (`catalyst-db`) | **Source of truth** tables: `users`, `devices`, `trials`, `subscriptions`, `grants` | binding `catalyst_db` in `wrangler.toml` | `npx wrangler d1 execute catalyst-db --remote --command "…"` |
| **Cloudflare KV** (`SESSIONS`) | Short-lived OTP codes, device-auth codes, rate-limit buckets, refresh→user map | binding `SESSIONS` in `wrangler.toml` | `wrangler kv key …`, or delete `rl:*`/`otp:*` to clear lockouts |
| **Cloudflare Pages** | Static JSON (shortcuts, brew lists, popular, `about.json`) | `catalyst_pages` repo | push |
| **Vercel** | Hosts `theappfoundry.co` (Astro site) + `api/catalyst/send-otp.js` + `middleware.js` | Vercel dashboard; `theappfoundryco` repo | push |
| **Vercel Edge Config** | `/catalyst/*` redirect destinations (website/support/feedback/bug/feature/developer), dashboard-editable | store connected to project → injects `EDGE_CONFIG` env; keys `catalyst_*` | edit keys in Vercel Storage → Edge Config |
| **Razorpay** | Payments: plans, subscriptions, hosted checkout, webhooks | live keys = Worker **secrets**; plan_ids = `wrangler.toml [vars]`; webhook in Razorpay dashboard | dashboard + `wrangler` |
| **Amazon SES** (AWS, region `eu-north-1`) | **Preferred** OTP sender (`no-reply@theappfoundry.co`) — `send-otp.js` wired 2026-07-17b | AWS account (personal); domain verified with **DKIM/SPF (MAIL FROM `mail.theappfoundry.co`)/DMARC all PASS**. Needs Vercel creds + AWS **production access** (still sandbox) | AWS console; SMTP `email-smtp.eu-north-1.amazonaws.com:587` (STARTTLS) |
| **Gmail** (`usecatalystapp@gmail.com`) | **Fallback** OTP sender (nodemailer + app password; used only when `SES_SMTP_*` are unset) | Vercel env `GMAIL_USER` / `GMAIL_APP_PASSWORD` | — |
| **GitHub** | 5 code repos; public releases repo (download host + appcast); bug/feature issue forms | your GitHub account; `gh` CLI | `gh`, git |
| **Sparkle** | macOS in-app auto-update | appcast served by Worker; `SUFeedURL`/`SUPublicEDKey` in `Info.plist`; **EdDSA private key in login Keychain** | `Scripts/cut_release.sh` (signs + publishes) |
| **Apple Developer** ($99/yr) | Code signing (Developer ID) + notarization | local Keychain; notary profile `CATALYST_NOTARY`; team `6957JGQD3R` | `xcodebuild` / `notarytool` (in cut_release) |
| **Firebase** (Analytics + Crashlytics) | Telemetry (device-UUID keyed, never email) | `GoogleService-Info.plist` in app; only `Telemetry/Telemetry.swift` imports it | via `Telemetry.log(_:)` facade |
| **Tally** (planned) | Feedback + support forms (hidden fields `version`/`email`) | Tally account; URLs go in Edge Config `catalyst_feedback`/`catalyst_support` | — |

---

## Where every secret lives (so you never hunt)

| Secret | Lives in | Notes |
|---|---|---|
| `JWT_PRIVATE_KEY` (Ed25519) | Worker secret | public key embedded in app (`AuthConfig.publicKeyPEMBody`) |
| `RAZORPAY_KEY_ID` / `RAZORPAY_KEY_SECRET` | Worker secrets | must be **live** (`rzp_live_`) for live payments |
| `RAZORPAY_WEBHOOK_SECRET` | Worker secret **+** Razorpay webhook config | **must byte-match both sides** or webhooks silently fail |
| `RAZORPAY_PLAN_MONTHLY_INR` / `_YEARLY_INR` / `_*_USD` | `wrangler.toml [vars]` | plan_ids, not secret; change → `wrangler deploy` |
| `INTERNAL_EMAIL_SECRET` | Worker secret **+** Vercel env | guards the OTP send route; same value both sides |
| `EMAIL_ENDPOINT`, `WEBSITE_URL`, `STUDENT_EMAIL_DOMAINS`, `ENVIRONMENT` | `wrangler.toml [vars]` | |
| `GMAIL_USER` / `GMAIL_APP_PASSWORD` | Vercel env | **fallback** OTP sender (used only if `SES_SMTP_*` unset) |
| `EDGE_CONFIG` | Vercel env (auto when store connected) | Edge Config connection string |
| Apple Developer ID + Sparkle EdDSA private key + `CATALYST_NOTARY` | **local login Keychain** | back these up — losing the Sparkle key breaks updates |
| `SES_SMTP_USER` / `SES_SMTP_PASS` (+ `SES_FROM`, `SES_REGION`) | Vercel env | SES SMTP creds (`eu-north-1`); `send-otp.js` prefers SES when set. ⚠️ never in `.env.example` |

Never put `*_SECRET` or `JWT_PRIVATE_KEY` in the app or the static Pages bundle.

---

## Everyday commands

```bash
# Inspect the live database
npx wrangler d1 execute catalyst-db --remote --command "SELECT * FROM users;"
npx wrangler d1 execute catalyst-db --remote --command "SELECT status,current_period_end,razorpay_subscription_id FROM subscriptions;"

# Watch the Worker live (debugging payments/auth) — look for POST /webhook/razorpay
npx wrangler tail

# Deploy the Worker (after editing src/index.ts or [vars])
cd catalyst_worker && npx wrangler deploy

# Cut a release (interactive; prompts for notes in the terminal)
./Scripts/cut_release.sh            # or --dry-run to preview, --deprecate-only, --yes
```

---

## Read next
- **`goLive.md`** — live status + full session changelogs (start at "✅ LATEST").
- **`CatalystUnderstanding.md`** — architecture (§36 auth/entitlement, §49 monetization/distribution).
- **`Formrules.md`** — conventions & invariants (Part 12 = telemetry/entitlement/payments/signing).
- **`RELEASING.md`** — Sparkle release runbook.
