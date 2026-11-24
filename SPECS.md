# AI Usage specifications

Behavior and provider contracts for the personal fork. Read the relevant sections before changing behavior; universal working rules live in [AGENTS.md](AGENTS.md). These are required product behaviors, with known code mismatches tracked separately in section 7. Code/tests establish current implementation; historical commits do not prove current live API behavior.

## Contents

- [1. Product behavior](#1-product-behavior)
- [2. Data presentation and login contract](#2-data-presentation-and-login-contract)
- [3. Provider contracts](#3-provider-contracts)
- [4. Analytics and persistence](#4-analytics-and-persistence)
- [5. Alerts](#5-alerts)
- [6. Compatibility](#6-compatibility)
- [7. Known implementation gaps](#7-known-implementation-gaps)

## 1. Product behavior

- Panel width 440 pt, Settings window fixed 750×640 (screen-clamped), dashboard min 1080×700 (`AppSurfaceLayout`).
- Cards start collapsed (first quota row only); chevron expands secondary rows, consumption share, resets, Additional Usage/Credits.
- Severity colors are shared by panel and menu bar: normal < 60% used, orange 60–85%, red ≥ 85% (`UsageSeverity`).
- Left/Used mode never inverts share charts.
- Sessions shorter than 24 hours with a known `startsAt` and `resetsAt` (after ≥ 10% elapsed, `0 < usedPercent < 100`, `measuredAt < resetsAt`, and `now < resetsAt`) show an `"Out <countdown>"` pace estimate and hourglass icon on the tile and an hourglass on the menu bar when linear pace predicts exhaustion before reset; stale (`⚠︎`) takes precedence over the hourglass on the menu bar.
- When Sparkle detects an upstream version strictly newer than `UpdateController.syncedUpstreamVersion` (currently `0.5.0`), the panel footer displays passive informational text (`Upstream <version>`) with no interactive Update button or in-app update action; already-synced or older upstream versions are suppressed.
- Use semantic system colors and solid backgrounds; preserve accessibility labels.

### Native window and settings behavior

- Keep the arrowless usage panel reusable across opens. Disclosure expansion keeps its top edge and summary anchored; grow downwards, clamp to the current screen and scroll only after reaching the available height. Avoid open/close animations and full host reconstruction on ordinary refreshes.
- `UsagePanel` is a non-activating panel (do not call `NSApplication.activate`; Settings and Dashboard activate normally). Do not depend on `NSStatusBarButton.window` when anchoring; capture the button rect if available or fall back to the mouse click and its `NSScreen`, deferring status-button presentation until the tracking turn unwinds. Do not close on the transient key-focus loss caused by the opening status-item click; outside click, Escape and real foreground-app switches dismiss predictably, suppressing only the matching close/toggle event via `PanelToggleGate`. Keep a stable `NSStatusItem.autosaveName` and never call `NSStatusBar.removeStatusItem` on app termination so macOS and menu-bar managers (such as Hidden Bar) preserve the icon's position across quits and reinstalls. Avoid `button.image = nil` flicker before assigning a status image.
- Settings and analytics Dashboard are independent native windows that can coexist. Preserve the Dock presence while either is visible/minimized and restore menu-bar-only behavior when both close.
- Settings order is Providers, Alerts, General, with natural content height inside the fixed window. Keep the US/CN provider zones, aligned native login pickers (currently 184 pt) and drag ordering within each region. Switching panel region persists selection, resets scroll to top and resizes the panel; it must not disable tracking or hide menu-bar metrics in the other region.
- Tracking, menu-bar visibility and metric selection are independent settings: hiding a provider preserves selected metrics; clearing its last menu metric hides it without stopping collection; disabling tracking preserves choices for re-enabling. Order must agree across settings, panel and menu bar.
- Seed newly introduced defaults once using versioned migration flags. Preserve explicit opt-outs, order, metrics, display mode and login source across relaunch/update. Do not reapply fresh-install defaults on every launch or overwrite an unavailable metric selection merely because a poll omitted it.
- Provider icons must use monochrome template glyphs with transparent backgrounds through the shared `ProviderIcon` rendering path. Use SVG where possible; if a brand supplies only a colored app/favicon asset, use a recognizable monochrome vector treatment, not an original-color rendering exception or an opaque app-icon background. Keep the asset source documented. Menu-bar icons follow appearance while individual values keep their own severity colors; do not make the complete status image a template that erases those colors. Skip unchanged status-image assignments.

Failure policy: `transient`, `rateLimited` and `invalidResponse` retain the last snapshot marked stale; `authentication` and `storage` clear it. A source change clears the old snapshot/Connected state before refreshing the new source. `ProviderID.enabledCases` controls active providers; region controls grouping.

## 2. Data presentation and login contract

**Required behavior:** expose the maximum meaningful account/usage values the provider returns, including on accounts without a paid plan. This is not a raw JSON viewer: credentials, internal IDs, telemetry, implementation metadata and unrelated content must never be displayed. Plan names are metadata, not a gate for quota, balances, billing, resets or details. Do not stop mapping just because one endpoint, one plan or one bounded quota is absent.

### What to show, omit, or annotate

- A finite numeric zero is real data: show `0`, exhausted `0 left`, `0% used` or `0% left` as appropriate. Never turn a reported zero balance into `N/A` or hide it merely because a plan is free. An explicit disabled state can be meaningful, but default flags for absent plans/products are not independent user-facing metrics. Preserve zero balances of allocated pools; a 0/0 unallocated entitlement is not a zero credit balance.
- Missing, null, invalid and unsupported are distinct from zero. Do not fill missing usage with zero, missing capacity with 100, or missing plans with invented names. Preserve valid sibling data when one field cannot be mapped.
- For every meaningful response field/bucket, account for it as: mapped UI value; duplicate of an identified pool; explicitly unavailable entitlement; unsupported value with a redacted compatibility notice; or irrelevant/private metadata. New schema fields require review, not automatic raw-value display.
- Iterate all quota/model/feature/wallet/package arrays and keyed dictionaries. Do not select only `.first` and discard other distinct allowances. Deduplicate only when the contract establishes the same pool, scope, cadence and account. Never add overlapping limits or aggregate different units/currencies.
- Paid-plan absence disables only the entitlement the response identifies as unavailable. Keep free quotas, remaining purchased credits and organization pools visible. A failed optional endpoint must not be labeled `No plan`.
- Use a stable known-feature placeholder for unavailable entitlements, with an accurate note (`No Token Plan`, `Unavailable`, etc.). Hide absent unknown buckets, empty groups and private/irrelevant metadata. Do not create a grid of speculative features or infer unlimited from missing/zero capacity.
- `Off` means explicitly disabled; `N/A` means an expected value is unavailable; `Expired` means a reused browser session has expired and only the user can renew it in that browser; `No plan` requires entitlement evidence; `Unlimited` requires an explicit flag or documented sentinel. An unknown reset is not `No reset`.
- Empty quota windows are valid when usable balances, details, billing or resets exist. Do not throw a whole-provider error merely for lack of a bounded quota. If all usable data is absent, distinguish a valid unavailable state from an authentication, storage, request or schema failure.

### Choosing the visual form

| Response semantics | Presentation | Rules |
| --- | --- | --- |
| Explicit used/remaining percentage or ratio | `QuotaWindow`: percentage + progress bar | Normalize once to used percent; convert remaining to `100 - remaining`. Ratios use their documented scale. No invented denominator. |
| Used/remaining count with valid positive capacity | `QuotaWindow`: percentage + bar + count/limit | Derive percentage only for the same pool/unit; keep counts and reset. Count text follows Left/Used. |
| Credits with known positive total | `ProviderUsageDetail` with `BoundedCreditProgress` | Show used/total or left/total and a bar; keep credit units. Existing credit-row rendering recognizes IDs ending in `.credits`. |
| Balance or usage counter without capacity | Numeric `ProviderUsageDetail` | Show amount + unit/scope, including zero; no percentage or progress bar. Extend the model/view if necessary rather than fabricating a bounded quota. |
| Explicit unlimited allowance | `QuotaWindow(isUnlimited: true)` | Show `Unlimited` with the existing decorative unlimited bar, never a numeric capacity/percentage. Preserve any independently reported counter as a detail. |
| Unavailable known entitlement | `QuotaWindow(isInactive: true, inactiveDetail:)` | Gray `—`/placeholder track + reason, never a measured 0%/100%. Preserve other available values. |
| Monetary spend with a cap | `BillingUsage.boundedSpend` in Additional Usage | Currency spend/cap + bar, enablement and reset if known. |
| Monetary spend without a cap; prepaid money | `unboundedSpend`; `MonetaryBalance` | Amount and currency; no ratio/bar without a real cap. Credits are money only when the provider reports the conversion/value. |
| Consumption breakdown | `consumptionShares` | Stacked share of already consumed usage, not remaining quota; do not invert in Left mode or add to quota capacity. |
| Reset grants/cards | `UsageResets` | Available count, usable-now count when different, next expiry/countdown and expiry detail. Zero is meaningful when a count is reported. Never redeem. |
| Reset, expiry or refresh timestamp | Time label attached to its own value | Keep reset vs expiry vs refresh semantics; parse timezone/seconds/milliseconds correctly. Future expiry/renewal/billing timestamps in `ProviderUsageDetail` set `targetDate` so rows render as relative `CompactCountdown` (`in <duration>`) with the exact date-time in the hover tooltip, never raw date-time strings inline. Do not invent a reset date or cadence. |
| Status, entitlement, unsupported semantics | Concise labeled detail or diagnostic | Explain the useful state without secrets, raw payloads or misleading numbers. |

Quota footers keep count/limit values visible: counts up to `99,999` remain exact, while counts `> 99,999` use compact decimal suffixes (`K`, `M`, `B`, up to 2 decimal places) so they fit cleanly alongside reset times. When reset and counts still cannot fit on one line, `QuotaFooter` wraps onto a second line instead of ellipsis or dropping the reset. Accessibility exposes the formatted counts too.

Left/Used switches only bounded usage/counts/spend. Balances, status, consumed shares, expiry and reset-card counts retain their semantics. Severity always uses consumed percentage: normal <60%, orange 60–85%, red >=85%, independent of display mode. Only active bounded, selectable metrics belong in the menu bar; unbounded counters/balances stay visible in provider details.

### Grouping and ordering

1. Header: provider, verified account/plan and scope; hide missing identity fields instead of inventing them. Subtitles follow the established `Shared account limits • <products>` or `Product usage limits • <features>` patterns (or an existing domain-specific pattern when necessary); describe user-facing scope without repeating the provider name or exposing API terms such as membership/entitlements. Dola/Manus without subscription/Pro plan use the `Free` badge. Subscription/membership state belongs in the header plan badge, not in a repeated Plan detail or a Membership quota tile/section. An unavailable known overall usage pool can use a gray Usage placeholder with No plan when cadence is unknown. Quota titles must describe a measured window or feature (Session, Weekly, Daily, Monthly, or a verified feature name), and section titles group actual pools/products; never invent a cadence to fill the grid.
2. Summary: one row, up to two principal quota tiles. Prefer broad/main pools and shorter then longer cadence (Session/Weekly, Daily/Weekly). A collapsed card limits space, not data collection or expanded availability.
3. Expanded quotas: remaining model/feature/cadence buckets, grouped by product or independent pool with `ProviderQuotaSection` where helpful. Stable order and stable IDs are required across refreshes. Keep independent app/IDE pools separate; a summary overlay must retain both readings and sections.
4. Consumed-usage breakdown, then resets, Additional Usage/billing, additional credits/wallets/org pools and remaining labeled details. Keep each source and unit explicit. Preserve the existing detail order unless the provider's semantics require a clearer grouping.
5. Details-only snapshots are valid, but must not dump every response field inline. First identify the compact primary state and group meaningful secondary values behind disclosure. Do not create redundant Plan/Subscribed/Business None/Team None/Enterprise None rows for an absent subscription. Default enterprise counters/exhaustion flags are hidden when no enterprise pool applies. Verify collapsed and expanded rendering alongside existing providers before declaring UI parity.

Current summary/detail conventions live in `ProviderDetailsLayout`: Claude, Codex, Antigravity and MiniMax prioritize Session/Weekly; Qwen Daily/Weekly; Adobe keeps Firefly in details; Copilot keeps completions in details; Kimi keeps Code limits in details. Claude orders Session/Weekly, Fable, then others. Antigravity now exposes only app-pool windows. These are presentation conventions, not permission to drop other response values.

### Login-method coverage

- Investigate every relevant source: native desktop app(s), CLI/local OAuth, editor/plugin login, Edge Default and Chrome Default. Inspect each source's supported read-only auth flow, account scope, refresh behavior and endpoint coverage. Multiple products may share a provider but not quota/credentials.
- Offer the maximum **implemented and verified** working methods in `ProviderLoginMethod.supported(for:)`. Do not restrict a new provider to the easiest discovered source, or advertise desktop/CLI/browser methods merely because a related app exists. Record unavailable/blocked methods and the concrete reason in the implementation handoff; do not present them as working.
- A single available login on this Mac need not block implementing other methods whose credential format and API contract are established and covered by fixtures; clearly distinguish live-verified from fixture-only validation.
- The picker is a real routing contract: every method must have its own loader, source label, account identity/history isolation, refresh/cache invalidation and errors. Switching methods must not reuse another source's credentials, stale account cache or quota history. Edge and Chrome remain separate choices.
- Never silently fallback to another source/account. An explicitly selected combined mode (Copilot Editor + CLI fallback) is the declared exception; desktop app/IDE resolution must also be documented and deterministic.
- Browser methods need exact domain/cookie allowlists, read-only storage and the normal macOS permission/security-scoped access path. Native credential encryption must use the app's actual Safe Storage service. No copying blocked databases, bypassing Keychain boundaries or asking for passwords/API keys.
- Keep the provider contracts here and the README login-source table synchronized with the actual picker and adapter implementation.

### Session lifecycle

- Publish each completed provider fetch independently. A provider waiting for its normal macOS permission prompt must not hold every other card at Connecting. Discard obsolete generations/source results and keep the latest successful-refresh timestamp monotonic.

- Rotating refresh tokens must survive relaunch in this app's provider-specific session store, bound to the originating credential fingerprint. Do not replay a stale browser/native refresh token over a newer persisted rotation. Serialize rotating refreshes (and session forks) single-flight inside an unstructured cancellation-safe task so concurrent fetches or caller cancellation (such as `UsageStore.cancelRefresh()`) never drop or reuse a rotated refresh token.
- Refresh and proactively renew sessions before expiry where supported; normalize token encoding/prefixes according to the provider contract. Bound retries after auth rejection, classify refresh errors strictly so transient or rate-limit responses never wipe persisted sessions, and discard persisted sessions only on confirmed authentication rejection or account mismatch, then reload fresh source credentials (including untouched source cookies for forked sessions). Do not create a refresh/retry loop.
- Reusing a login must not revoke the source app/browser session. Preserve Qwen's independent-session forking; do not replace it with direct consumption of the browser's rotating session. Respect provider-specific refresh opt-ins (including Kimi's existing gate), and never enable one implicitly.
- Account email/profile lookup is supplementary, not a condition for showing quota. Cache the attempt per source selection, including failure; do not hit profile endpoints on every poll. Use a verified email or a scoped one-way identity for history, never display a session hash as an email.

### Adding or changing a provider

1. Inspect native/public provider resources and verify the read-only contract live with the user's selected login. Never record secrets. If macOS blocks one source, report that source as blocked and investigate other authorized methods without silently switching the selected method. Do not claim live verification from fixtures or enable an unverified guessed contract.
2. Inventory all relevant read-only quota, membership, billing, balance, wallet, entitlement, reset and identity endpoints. Build a field-to-UI mapping using the presentation contract above, including free/no-plan, zero, unavailable, unlimited and partial-response states. Reuse all meaningful returned values.
3. Add the `ProviderID` case (new raw value), `displayName`, template SVG icon, `region`, install indicators, default metric, `dashboardSubtitle`, scoped `historyIdentity` prefix, all verified `ProviderLoginMethod.supported` paths, seeding flag in `AppPreferences`, and `UsageStore.defaultProviders()` entry.
4. Implement exact-source auth, first-party host/cookie allowlists, account isolation, safe refresh and failure handling. Verify each advertised method routes to its documented loader, and identify its live/test coverage.
5. Map all data families to windows/sections, billing, balances, resets and details; wire summary/expanded layout and menu-bar eligibility. Unknown measured buckets use `QuotaDiscovery` / `.additional(id:title:)`; unsupported semantics produce a redacted compatibility warning. Extend model/UI when a valid value has no honest representation; never drop it for convenience.
6. Add/update `ConfirmedSchemaCatalog` baselines and `ResponseSchemaWatch` for every consumed endpoint and relevant nested bucket, headers, deprecation, keys and enums. New structures must not disappear silently.
7. Add fake-fixture tests covering mapping and grouping, zero and exhausted balances, free/no-plan with valid data, unlimited, missing/null/malformed fields, unknown/additional buckets, details-only snapshots, partial endpoint failure, login routing/isolation and failure kinds. Verify count/bar/time/note rendering and Left/Used semantics where changed. Never use real secrets or the real UserDefaults suite in tests.
8. Update provider contracts in this file and `README.md`. Review the diff against every meaningful response value and every investigated login method; report remaining unsupported values/methods and validation limits. Run the appropriate build/tests; commit/push only when explicitly requested.

## 3. Provider contracts

### Claude

- Region: US.
- Login methods (default first): CLI OAuth; Claude desktop; Edge; Chrome.
- Credential source: Keychain `Claude Code-credentials` / `~/.claude/.credentials.json`; desktop/browser `sessionKey*` cookies.
- Read-only endpoints: `api.anthropic.com/api/oauth/usage` (`?cedar_ember=1` hourly for reset grants); `claude.ai/api/organizations/{id}/usage`.
- Auth behavior: HTTP `403` with `error.details.error_code == "oauth_not_allowed_for_organization"` skips token refresh and reports an authentication failure; if stored credentials change twice during one refresh, fail transiently immediately without probing stale candidates.
- Data families: Session, weekly, Sonnet/Fable and discovered scoped/model quotas; consumed usage by Code/Chat/Cowork; banked/usable resets and expiry; extra spend, monthly cap, enablement, active `auto_reload` and `spend_limit_reached` status flags.

### Codex

- Region: US.
- Login methods (default first): CLI OAuth (also resolves shared Codex/desktop auth); Edge; Chrome.
- Credential source: `$CODEX_HOME`/`~/.config/codex`/`~/.codex` `auth.json`, Keychain `Codex Auth`; `__Secure-next-auth.session-token*`.
- Read-only endpoints: `chatgpt.com/backend-api/wham/usage`, `.../wham/rate-limit-reset-credits`.
- Data families: Session/weekly, Spark windows, code-review and additional rate limits; flex/additional credits and reported monetary value; banked/usable resets and expiry; active `spend_control.reached` status flag.

### Cursor / X Subscription

- Region: US.
- Login methods (default first): Cursor desktop; Edge; Chrome.
- Credential source: Cursor `state.vscdb` (safeStorage `v10`, `Cursor Safe Storage`), Cursor CLI Keychain (`cursor-access-token` / `cursor-refresh-token`); `WorkosCursorSessionToken`.
- Auth behavior: Access tokens renewed from Cursor CLI Keychain items are cached in memory per `refreshToken` and never written back to the CLI Keychain; expired CLI sessions prompt `agent login`.
- Read-only endpoints: `api2.cursor.sh` DashboardService RPCs; `cursor.com/api/dashboard/v2/usage-status`, `get-sand-usage-status`.
- Data families: Legacy Total/Auto/API quotas or shared weekly pool; consumed share by Cursor/Grok Chat/Grok Tasks; additional spend/cap/enablement, prepaid monetary balance.

### Antigravity

- Region: US.
- Login methods (default first): Desktop (native app/IDE credential resolution).
- Credential source: `Antigravity IDE` (else `Antigravity`) `state.vscdb` key `antigravityUnifiedStateSync.oauthToken`.
- Read-only endpoints: `oauth2.googleapis.com/token`; `loadCodeAssist` metadata and `retrieveUserQuotaSummary` on `daily-cloudcode-pa.googleapis.com` only. The method name `loadCodeAssist` does not mean the retired Code Assist quota pool is queried.
- Data families: App Session/weekly, 3rd-party session/weekly, Argon and discovered pools; additional credits when supplied. Code Assist quota is excluded.

### GitHub Copilot

- Region: US.
- Login methods (default first): Editor + CLI fallback (explicit combined mode); editor only; CLI only.
- Credential source: `~/.config/github-copilot/{apps,hosts}.json`, `gh` config / Keychain `gh:github.com`.
- Read-only endpoints: `api.github.com/copilot_internal/user`.
- Data families: Credits/premium quota, chat/monthly, completions, other quota snapshots; unlimited flags; overage count, `overage_permitted` status on bounded `premium_interactions`, and credits-used details.

### Gemini

- Region: US.
- Login methods (default first): `Desktop app + Edge` (`nativeAppEdge`, default for new installs; existing `geminiNativeAccessAllowed.v1` users without a saved source preserve `nativeApp`); `Desktop app + Chrome` (`nativeAppChrome`); `Desktop app` (`nativeApp`); `Browser (Edge)`; `Browser (Chrome)`. Combined modes read Gemini quotas from the desktop app (preserving `credentialSource: "Gemini app"` so history stays continuous) and Flow/Flow Music credits only from the named browser. Browser-only modes read everything from that browser. `Desktop app` never reads browser cookies and omits browser-only Flow/Music segments.
- Credential source: Gemini.app active account (`com.google.GeminiMacOS`, Keychain `Gemini Safe Storage`); browser `.google.com` `__Secure-1PSID(TS)` plus `flow.google.com` `__Secure-OSID` (never `OSID`) for Flow; Flow Music Supabase session cookie `sb-sb-auth-token` / `sb-sb-auth-token.0…7` on exact host `www.flowmusic.app` in the same browser.
- Read-only endpoints: `robinfrontend-pa.googleapis.com/.../GetUsageInfo` (protobuf); web `gemini.google.com` GraphQL; Google Flow `GET flow.google.com/` (page `SNlM0e` form token only, cached in memory per Google + Flow session and refetched once on `400`/`401` or a null/error cached response) then `POST flow.google.com/_/AiSandboxAngularFrontend/data/batchexecute?rpcids=nzlxg` with `f.req=[[["nzlxg","[]",null,"generic"]]]`; Flow Music `GET www.flowmusic.app/__api/billing/credits` with the session's Bearer access token only (cookies are not sent, fetched concurrently with Flow). Each host has its own allowlisted no-redirect client. Never call Flow/Flow Music generation, top-up or Supabase token refresh: Supabase rotates refresh tokens, so refreshing would sign the browser out. An expired Flow Music access token shows `Music Expired` without a request; it renews when the user opens Flow Music in that browser.
- Data families: Native/web session and weekly pools; discovered pool types; `OVERAGE_CREDITS` additional AI credits (`credits_remaining` including zero, `use_overage_ai_credits` Off/On state, and optional `expires_at` countdown detail; native `credits_remaining=0` with `use_overage_ai_credits=false` is live-verified, while positive balances, `expires_at`, and Web `OVERAGE_CREDITS` shapes use fixtures); Flow Credits (`nzlxg` element 0 + reset element 6) and Flow Music (`data.credits_remaining`, schema-checked in `ConfirmedSchemaCatalog`) rendered as 2 side-by-side detail quota bars in 1 row (`ProviderDetailsLayout`), using known plan monthly allotments (`Flow`: Pro `1,000`, Ultra `25,000`, Free `100`, expanding to `balance` if daily bonus credits push the total higher; `Flow Music`: Pro `10,000`, Ultra `30,000`, Free `100`) and inactive `N/A`/`Expired` tiles when unavailable. Flow and Flow Music are separate pools from Gemini AI credits (live: Flow 1,050 and Flow Music 10,650 while Gemini/Antigravity AI credits were 0). Flow Music `tokens_remaining` (a 12× internal unit of the same balance) and `add_token_transactions` are not displayed. Both Flow (`__Secure-1PSID(TS)` + `flow.google.com` `__Secure-OSID` out-of-browser `nzlxg`) and Flow Music endpoints were live-verified against Edge cookies.

### Muse

- Region: US.
- Login methods (default first): Edge; Chrome.
- Credential source: `hatch_sess`, `hatch_gw`.
- Read-only endpoints: `muse.ai` Next.js `fetchSubscriptionAction` (action ID rediscovered from public chunks when rotated).
- Data families: Weekly usage and reset; top-up spend/cap, monetary balance, enablement when supplied.

### Adobe

- Region: US.
- Login methods (default first): Edge; Chrome.
- Credential source: `ims_sid`.
- Read-only endpoints: Silent IMS `adobeid-na1.services.adobe.com/ims/authorize/v1` → `firefly.adobe.io/v1/credits/balance`.
- Data families: Total monthly generative credits, Firefly allowance and all other `credits` pools/balances, `planCap`, counts, reset/expiry.

### Manus

- Region: CN.
- Login methods (default first): Manus desktop; Edge; Chrome.
- Credential source: `session_id`.
- Read-only endpoints: `api.manus.im/user.v1.UserService/GetAvailableCredits`; optional `user.v1.UserService/UserInfo` for the validated account email. The profile uses the same selected session Bearer token, is cached per selection/credential (including failed/empty lookup) and never gates quota. Desktop UserInfo email is live-verified.
- Badge: when no active Pro monthly allocation exists, display `Free`, not a blank badge or No subscription. Keep the unavailable Monthly tile note `No Pro plan` when a refresh window or `proMonthlyCredits` field is present; allocated daily/weekly/monthly/free balances remain measured normally, including balance-only snapshots and explicit zero balances.
- Data families: Refresh credits (`daily`/`weekly`/`monthly` per `refreshInterval`) and monthly credits, counts/reset; free, bonus, add-on and total credit balances.

### Kimi

- Region: CN.
- Login methods (default first): Kimi desktop; Edge; Chrome.
- Credential source: `kimi-desktop` / browser Local Storage `access_token`/`refresh_token` (origin `https://www.kimi.ai`), else `kimi-auth` cookie.
- Read-only endpoints: `www.kimi.ai/apiv2/...MembershipService/GetSubscription(Stats)`, `BillingService/GetUsages`; refresh `www.kimi.ai/api/auth/token/refresh` (needs `kimiNativeRefreshAllowed.v1`).
- Data families: Membership monthly/feature allowances; Code weekly, total and duration-specific limits (`remaining` or `used` relative to `limit`); counts and reset/expiry.

### Qwen

- Region: CN.
- Login methods (default first): Qwen desktop; Edge; Chrome.
- Credential source: Qwen app (`Cookies` or `Network/Cookies`) / browser Local Storage `qwen_access_token_state`, `refresh_token` cookie.
- Read-only endpoints: `auth.qwen.ai` refresh + `authorize/code` (forks an independent session so the app/browser login is not revoked, and proactively renews expiring JWT refresh tokens before expiry); `sg-entitlement.qwen.com`, `sg-member.qwen.com`.
- Data families: Daily/weekly allowance; model-frequency limits; video/image and discovered entitlements; counts/reset; reset cards and expiry.

### MiniMax

- Region: CN.
- Login methods (default first): Desktop (Code/Hub credential resolution); Edge; Chrome.
- Credential source: `~/.minimax/auth/prod/*/mcode-public/auth.json` (OAuth), MiniMax Hub `hub-config-global.json` (`v2enc` + `.token-key`); browser `_token`.
- Read-only endpoints: `agent.minimax.io` membership, `platform.minimax.io` token plan, `design.minimax.io` wallet/profile, `hailuoai.video` credit/equity (signed requests).
- Data families: Token Plan session/weekly (including `status == 3` Unlimited and `remaining_percent` fields) and all multimodal `model_remains` buckets (Video, Audio/Speech, Image, Music, etc.); Token Plan/Agent/gift credits (preserving explicit zero balances); Design and Hailuo wallets rendered as 2 side-by-side detail quota bars in 1 row (bounded by `totalCredits` or paid-plan monthly allotments — `Max` `12,000`, `Pro` `4,500`, `Standard`/`Plus` `1,000` — or inactive `<n> left` gray bars on Free/unknown plans so `UsageHistory` is not polluted).

### Qoder

- Region: CN.
- Login methods (default first): Desktop (Qoder app/IDE credential resolution); Edge; Chrome.
- Credential source: `com.qoder.app.stable/auth.v1.dat` (`Qoder App Safe Storage`), else Qoder IDE `state.vscdb` (`Qoder Safe Storage`); `qoder_session_cookie`.
- Read-only endpoints: `openapi.qoder.sh` usage/plan/refresh; `qoder.com/sash/api/v2/me/usage`.
- Data families: User plan credits (`userQuota` mapped to `.credits` with one-time `qoderCreditsMetricMigrated.v1` migration from `.weekly`, counts/reset and fractional/percent normalization); add-on credits; `dedicatedResourcePackages` with bounded progress and expiry; organization resource pool (`total` or `cap`); plan/account metadata.

### Dola

- Region: CN. Login methods (default first): Desktop, Edge, Chrome. Default menu bar metric is `.additional(id: "dola.usage", title: "Usage")`. Reordering the picker changes the default for new selections only; preserve existing explicit choices.
- Desktop storage: `Cici/Default/Cookies`, bundle `com.bot.pc.cici`, app `Cici.app`, Keychain `Cici Browser Safe Storage` (embedded Dola Browser; account label `Dola Browser`) read via shared `SecurityKeychainAccessor` (`/usr/bin/security`). Do not use the separate `Cici Safe Storage` item: it does not decrypt the browser cookie database. Denials remain storage errors and no credential access boundary is bypassed.
- Browser storage: selected Edge/Chrome Default Cookies only (`BrowserDatabaseAccess` bookmark path). Exact domain `dola.com`, cookies `sessionid`, `sessionid_ss`, `passport_csrf_token`. `LARK_SUITE_ACCESS_TOKEN` is explicitly excluded; never load it. Preserve `WebSessionStore` macOS Privacy & Security permission guidance when storage fails due to OS access denial.
- Requests: HTTPS `www.dola.com`, POST with `product_line: membership` to `/alice/commerce/sale/subscription/overview/`, `.../status/`, `/alice/commerce/sale/entitlement/usage_detail/`, `/alice/user/get_user_ogf_quota`. No generation, redemption or purchase calls. Web aid is 495671; native aid is 582465.
- Mapping: no subscription uses the header `Free` badge and a standard inactive `Usage` tile with gray track/No plan note, never Session/Weekly/Monthly without cadence evidence. Do not show the empty-plan API default `total_used_percent=0` as an active quota. Hide duplicate subscription flags and inapplicable business/team/enterprise false/zero metadata; show active/pending secondary states only behind disclosure. Preserve numeric zero for an allocated positive-capacity quota, including exhausted free quota. OGF `0/0` means no allocated counter and is omitted, not shown as Additional Credits or a usable balance. A positive-capacity OGF pool uses a count/percentage tile; nonzero/unbounded counts use concise details without guessed units. Unknown reset remains absent.
- Unknown nonempty paid groups produce partial-compatibility notices. Optional endpoint failures retain overview and successful sibling results. Overview error `710012001` is authentication; `429` is rate-limited; malformed is invalid.
- Identity: optional GET `/passport/account/info/v2/` with the same selected cookies and `aid`. Accept only a validated direct `data.email` from a successful profile response. Cache the lookup attempt per selection/credential using `AccountIdentityCache`; profile failure/empty email must not fail quota or inherit another account. Stabilize `historyID` on `label + "\0" + (email ?? seed)` when email is resolved so cookie rotation does not split history, and never display the scoped hash as email.
- Icon and subtitle: transparent monochrome SVG loop glyph rendered with shared template mode; subtitle `Shared account limits • Chat & Work`. Desktop and Edge free-account flows are live-verified; Chrome and paid entitlement shapes use fixtures.

### Z.ai / ZCode

- Region: CN. Login methods (default first): ZCode desktop, Edge, Chrome. Do not silently read credentials from Claude/OpenCode/environment settings. New tracking is seeded once with `zaiProviderAdded.v2`; later opt-outs persist.
- Desktop: selected Z.ai OAuth account in `~/.zcode/v2/credentials.json`, with sibling `credential-source` equal to `os`. Keychain service `ZCode Credential Encryption`, account SHA-256 of the resolved absolute credential path, read via `SecurityKeychainAccessor` (`/usr/bin/security`) so Keychain ACLs persist across local builds. Values use `enc:v2:os:<key fingerprint>:<nonce>.<tag>.<ciphertext>`, base64url AES-256-GCM, 12-byte nonce, 16-byte tag and SHA-256 key fingerprint. Reject other encryption sources, mismatched keys and tampering; never create/migrate keys or modify the source file.
- Browser: selected Edge/Chrome Default Local Storage (`BrowserDatabaseAccess` bookmark path + `SettingsView` access button), exact origin `https://z.ai`, keys `z-ai-open-platform-token-production` and `platform-user-info`. `api.z.ai` redirects its website to `z.ai/model-api`; API calls still use `api.z.ai`. Chat login at `chat.z.ai` is not a substitute. Read the live LevelDB manifest read-only with one retry on compaction race, never copying tables.
- Read-only APIs: `api.z.ai/api/biz/subscription/list`, `/api/monitor/usage/quota/limit`, `/api/biz/customer/getCustomerInfo`; native Start Plan `zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=...`; optional active Coding Plan read-only endpoints `zcode.z.ai/api/v1/coding-plan/reset/status` (banked reset cards; never `/use`) and `zcode.z.ai/api/v1/mcp/usage` (fallback for `zai.tools` when `TIME_LIMIT` is absent). Bearer business OAuth goes only to `api.z.ai` (and as `X-Bigmodel-Authorization` on ZCode coding-plan routes to `zcode.z.ai`); the separate native JWT goes only to `zcode.z.ai`. Propagate `.authentication` (`401`/`403`) and `.rateLimited` (`429`) from `/api/monitor/usage/quota/limit` instead of silently downgrading them to unavailable. Do not create project/API keys, call generation, claim a Start Plan, purchase, redeem or perform source-token refresh/writeback. Re-read source credentials on polling so source app rotation is respected.
- Start Plan requires the existing `deviceMid` from `~/.zcode/v2/telemetry-state.json` and the installed app version/platform headers. Read only that field; do not read/transmit other telemetry or generate a replacement device identity. Never print/store the device ID in diagnostics. Send this context only to the native host, never the API/browser host. Missing context leaves Start Plan unavailable without invalidating the verified Coding Plan reading.
- Mapping: inspect all subscription entries and all quota limits. Coding Plan `usage` is capacity, `currentValue` used, `percentage` consumed percent; `unit`/`number` describe cadence, not capacity. Keep session/weekly and tool/model readings separate; new measured buckets remain visible with compatibility warnings. Only emit the gray `Coding Plan` (`No plan`) placeholder when BOTH Start Plan windows and Coding Plan windows are empty (or `Unavailable` when an active Coding Plan exists whose quota failed to load); do not append a redundant `Coding Plan — No plan` tile alongside active Start Plan windows.
- Start Plan: match each balance with its plan/entitlement, retain each model and unit, total/remaining/available-now values including zero, expiry and plan dates. Explicit entitlement periods (`daily`, etc.) establish reset semantics; period-end alone is not a reset. Daily model token windows lead the summary; Coding Plan stays a distinct tile when present. Stable metric IDs derive from plan + entitlement + unit, not a rotating bucket ID. Avoid adding model pools together. Entitlement grant amounts already represented by a balance are not duplicated; future grants retain effective dates.
- Plan badge uses active returned plan names. Show `Free` only when available endpoints establish no active plan; a failed native Start Plan must not be called Free. Account email prefers the selected profile, then successful customer info; masked values are never identity emails and never overwrite a full email. Stabilize `accountLabel` on `auth.source + "\0" + (email ?? auth.token)` so token rotation does not fragment history. Null API balance fields are omitted, not zero; non-null numeric amounts without confirmed currency use one concise detail row (`<amount> (unit unconfirmed)`). Omit the customer profile organization/project selector list.
- Validation and icon: desktop and Edge free/Start Plan flows are live-verified; Chrome, paid Coding Plan, partial and error states use fake fixtures. Monochrome Z.ai SVG uses shared template rendering.

### Buddy (WorkBuddy / CodeBuddy)

- Region: CN. One `buddy` provider/card with subtitle `Shared account limits • WorkBuddy & CodeBuddy`; never duplicate a shared allowance across two provider totals. Official [pricing documentation](https://www.codebuddy.cn/docs/workbuddy/Pricing) establishes shared credits for the same account. Domestic `.cn` and international `.ai` contracts remain separate; the implemented host is international `www.codebuddy.ai`, personal accounts only. Enterprise/China accounts must not silently reuse personal/international totals.
- Methods (default first): CodeBuddy desktop, CodeBuddy web in Edge, CodeBuddy web in Chrome. WorkBuddy's protected native session (`$wbEncrypted` via `electron.workbuddyStorage`) is unsupported and not an advertised method; `installationIndicators` checks only CodeBuddy desktop (`CodeBuddy.app` and `state.vscdb`), never `WorkBuddy AI.app`, so machines with only WorkBuddy installed are not marked installed only to fail on the default method. Picker labels name CodeBuddy explicitly; no silent WorkBuddy-to-CodeBuddy or browser-to-desktop fallback.
- Desktop: exact secret `secret://{"extensionId":"tencent-cloud.coding-copilot","key":"planning-genie.new.accessToken"}` in `CodeBuddy/User/globalStorage/state.vscdb`, read-only. Decode the stored Buffer using Chromium Safe Storage and Keychain `CodeBuddy Safe Storage` via `SecurityKeychainAccessor` (`/usr/bin/security`). Use only `auth.accessToken`, verify `auth.domain == www.codebuddy.ai`, and bind the selected personal `account.uid`. Top-level legacy `accessToken`/`token` are not current credentials. Source app refresh remains owned by CodeBuddy; never write or rotate its stored auth.
- Browser: selected Edge/Chrome Default Cookies, allowlisted hosts `www.codebuddy.ai`, `.codebuddy.ai`, and `codebuddy.ai`, cookie names `session`, `session_2`; no analytics, Keycloak or anti-bot cookie import. Report selected-source authentication failures honestly without following login redirects or falling back to desktop.
- Read-only APIs: GET `/console/accounts`; POST `/billing/meter/get-user-resource-summary`, `/billing/meter/get-user-resource-free-packages`, `/billing/meter/get-user-resource-paid-packages`. Choose the exact stored account UID for desktop; browser needs one unambiguous selected personal account. Package requests use response-discovered PackageCodes, valid/exhausted Status `[0,3]`, bounded pagination and explicit day slices in Asia/Shanghai. Retain the summary and completed families on optional-page failure, mark incomplete details, and reject repeated pages. Never call check-in, gift/compensation claims, purchase, API-key creation, generation or redemption routes.
- Identity: optional same-source OIDC GET `/auth/realms/copilot/protocol/openid-connect/userinfo`. Accept a validated email only with `email_verified=true`; cache the attempt per selected source/account. Do not treat the account nickname as email. History remains source/account scoped when email is absent.
- Data mapping: Packages contain `CycleTotalCapacity`, `CycleRemainCapacity`, `CycleUsedCapacity`, reserved credits and unit. CreditGroups and TotalCredits overlap these package totals and are not added again; known groups are base, plan bonus, add-on and platform benefit. Unknown fields/groups produce compatibility warnings. Preserve exhausted allocated pools and zero balances; omit `0/0` groups with no allocation. Do not add monthly allowance, gift and add-on into one progress denominator.
- Presentation: standard Free/verified-plan header, base bounded allowance in summary. Use Monthly only when the returned slice cycle establishes it. For cyclic allocations, `CycleEndTime` before `DeductionEndTime` establishes the next reset at the following second; when a base package has no next reset (final cycle where `CycleEndTime >= DeductionEndTime`), surface its `DeductionEndTime` expiry detail. Additional gift/add-on counts/progress and package expiry stay under shared disclosure, ordered soonest-expiring first (matching FIFO deduction). Multiple underlying packages retain their remaining breakdown without adding to the summary.
- Validation and icon: CodeBuddy desktop summary, package breakdown and verified email are live-verified; Chrome/browser edge cases use fixtures. Transparent monochrome Buddy SVG uses shared template rendering.

### Provider-specific behavior

- Claude: put Session/Weekly first, Fable next, then remaining windows; retain consumed Code/Chat/Cowork shares and usable reset grants separately.
- Codex: the CLI OAuth selection also resolves shared desktop auth; flex credits are Additional Credits, not a duplicate monetary Additional Usage section.
- Cursor: use X Subscription branding/shared weekly semantics when the unified response applies. Keep Cursor/Grok consumption shares, not separate allowances; X plans must not inherit legacy Cursor price estimates.
- Antigravity: Gemini remains an independent provider. Only the Antigravity app pool on `daily-cloudcode-pa.googleapis.com` is requested/displayed. Do not query `cloudcode-pa.googleapis.com`, create Code Assist sections, overlay its readings or merge its usage into the app pool. Ignore retired `.ide` host responses even if supplied to the mapper. Native IDE storage may still supply the existing selected credential; credential location does not change which quota pool is read. Retain stable legacy identifiers and stored history without reactivating the retired feature.
- GitHub Copilot: the combined Editor + CLI fallback is an explicit selectable mode. Editor-only and CLI-only must not silently use each other's credentials.
- Muse: bounded first-party public-chunk discovery may recover a rotated subscription action ID; never execute downloaded code. Do not duplicate the same top-up amount in both the header balance and billing row.
- Adobe: keep total Monthly and Firefly sub-allowance distinct; do not sum them.
- Kimi: preserve the native refresh opt-in and rotated-token persistence; strip token prefixes only as required by the established contract.
- Qwen: fork an independent session before refreshing so the selected native/browser login is not revoked. Refresh access tokens 3 minutes before expiry, serialize refreshes and forks single-flight in cancellation-safe tasks, persist rotations (ignoring deletion `Set-Cookie` headers), classify refresh errors strictly so transient/rate-limit errors keep `qwen-auth.json`, proactively renew expiring JWT refresh tokens via `authorize/code` with a 1-hour failure cooldown, invalidate mismatched JWT account switches, and reload fresh source credentials (including untouched cookies for forked sessions) when a persisted session is revoked.
- MiniMax: distinguish Token Plan allowance/credits from free Agent, Design and Hailuo wallets. Free Agent credit belongs in Additional Credits when there is no Token Plan; paid Token Plan credits retain their own bounded progress.
- Qoder: separate personal quota, add-on credits and organization resource pool.

Coverage above describes implemented data families and sources, not exhaustive live verification of every account/method. Endpoint and credential contracts must be rechecked when changed; fixture tests are not proof of live behavior.

## 4. Analytics and persistence

- Tokens/Value analytics and quota percentages are different datasets. Dashboard bars show token counts or API-equivalent value; do not substitute quota %. All-provider bars group by provider, single-provider bars by model. Retain hover breakdowns, Plans/Limits/Models views, CSV export and the full 53-week Monday-aligned heatmap including empty days.
- `Value` estimates what the recorded tokens would cost at explicit API rates; it is not subscription spend, an invoice, savings or total account usage. Unknown/unpriced models remain in Tokens and are excluded from Value, with incomplete coverage disclosed. Do not guess rates from a similar model.
- Parse only usage/model/timestamp metadata from local Codex and Claude logs. Never persist/export message, tool or conversation content. Web chats and other devices are outside this dataset; local logs may span multiple accounts and must not be presented as isolated to the currently selected quota login.
- Codex cumulative token counters become nonnegative deltas; handle counter resets. Do not add cached input or reasoning tokens twice. Claude streaming records deduplicate by message ID and retain the fullest usage snapshot, including duplicates across files; preserve cache-read and cache-write tiers.
- Preserve imported metadata when source logs disappear, within retention. Removed files may leave the file cache, not erase already imported history. Bound JSONL record reads; skip malformed/oversized rows and retry incomplete final records when files change. Never fabricate missing historical usage.
- Plan prices are labeled list-price estimates with source, or explicit user overrides; ambiguous tiers stay unknown. Compare API value against prorated plan cost for the selected period. Overrides affect comparison only, never billing. Refresh price sources when changing rates; preserve provenance.
- Filtering one provider must not change the sidebar totals of other providers. Limit-hit views are scoped to the selected quota source/account. Keep notes concise (current copy tests require each dashboard note under 100 characters).

### Persistence and performance

- Quota history records the latest sample per provider/source/account/metric/ hour, with 13-month retention. Record limit-hit events separately so an exhaustion and reset in the same hour survive hourly sample replacement. Repeated full snapshots must not inflate the same observed limit event.
- Count observed limit hits only; do not infer unobserved earlier hits from missing history. Inactive/unlimited placeholders must not become measured history, exhaustion events or pace-alert inputs.
- Keep atomic background persistence and debounced saves. Surface storage failure without silently resetting existing history or preferences.
- Cache token files by size/mtime; normal reopen uses the five-minute import cooldown and explicit Refresh may force a scan. Build projections off the main thread, share Tokens/Value work and coalesce identical in-flight work. Cache by filters and data generation (currently up to 12 projections).
- View resize/hover/unit switching must not reparse logs or rebuild unchanged aggregates. Reject results from an obsolete generation. Completed cancelled view work may populate its matching cache but must not replace newer data.
- Verify idle CPU and repeated open/close/resize behavior for UI/performance changes. A successful build alone does not establish an idle-performance fix.

### Local storage

`UserDefaults` (bundle `com.burakgon.aiusage`; tests use the `com.burakgon.aiusage.test-host` suite and must never touch the real one) holds preferences, login methods (`<provider>LoginMethod.v1`), seeding flags (`<provider>ProviderAdded.v1`), email cache (`accountIdentity.v1.*`), Muse action ID, browser bookmarks.

`~/Library/Application Support/AI Usage/`:

| File | Owner | Contents |
| --- | --- | --- |
| `quota-history.json`, `quota-limit-hits.json` | `UsageHistory` | Hourly quota samples and limit hits, 13 months, keyed by source + account identity |
| `token-history.json`, `token-file-cache.json` | `TokenAnalytics` | Token counts parsed from local `~/.codex/sessions`, `~/.codex/archived_sessions`, `~/.claude/projects` JSONL (metadata only, no message text) |
| `confirmed-schemas.json` | `ConfirmedSchemaStore` | User-approved schema changes |
| `kimi-auth.json`, `qwen-auth.json`, `minimax-auth.json`, `qoder-auth.json` | provider session stores | Rotated tokens for that provider, bound to a fingerprint of the source credential; dropped when the source changes or refresh is rejected |

Never change an existing key/raw value (`ProviderID`, `QuotaKind`, `MenuBarMetricID`, defaults keys) — saved preferences and history depend on them. Add new versioned keys instead.

## 5. Alerts

- Alerts are opt-in, default off, and use ordinary macOS notifications that obey Focus; never upgrade them to time-sensitive/critical delivery.
- Running-out alerts require observed consumption pace predicting exhaustion before reset within the selected lead time; a high fixed percentage alone is insufficient. Current rule requires at least three readings spanning two minutes in the same reset window; restart the series when usage drops/reset changes. Keep samples scoped to source/account/metric.
- Paid-usage alerts require an observed exhausted allowance plus actual spend starting or monetary balance falling. Merely enabling extra usage, showing a plan or holding credits is insufficient.
- Limit-back alerts require an observed capped-to-available transition. Dedup alerts by account/metric/reset cycle; do not notify repeatedly on every poll. Feed history/alerts from successful observations, never stale failed fetches.
- Keep “A capped limit is back” before “Heads-up lead time” in Settings and preserve their explanatory subtitles.

## 6. Compatibility

Each mapper diffs live responses against `ConfirmedSchemaCatalog` (+ user overrides). New/missing keys, deprecation headers/bodies, unknown enums and unsupported quota entries surface as a warning badge on the card; **Update** records the reviewed diff in `confirmed-schemas.json`. When you change a mapper to support a new field, update the catalog in the same commit so users are not asked to confirm it. Previews must stay secret-redacted.

- Schema warning **Update** acknowledges reviewed structure in the local schema store. It does not update the parser, prove an unknown field is supported, repair auth, or execute downloaded compatibility recipes. New later changes must warn again. Keep known optional fields optional rather than treating every omission as a breaking change.
- When a vendor changes headers, action IDs or schemas, preserve metric IDs and historical meaning. Discovery must remain bounded and first-party (e.g. Muse action rediscovery), without arbitrary remote code/config execution.

### Protocol, header and identity guardrails

- Read macOS Keychain items exclusively via `SecurityKeychainAccessor` (`/usr/bin/security`), never direct `SecItemCopyMatching` calls in the app binary. Direct Keychain calls tie ACLs to the unsigned/ad-hoc local build and re-prompt for the user's password on every launch or rebuild.
- Do not blindly auto-bump protocol headers or replace protocol constants with installed app build versions: Codex `OpenAI-Beta`/`originator`, Copilot API date (`2025-04-01` / editor build headers) and Gemini `X-Goog-Api-Format-Version: 2` are protocol contracts, not client app versions. Conversely, retain Antigravity's hub `User-Agent` (bare legacy UA causes partial 200 responses that omit Argon).
- Display validated account email directly left of the plan badge with middle truncation and a full-email tooltip. Never infer account email from organization names, nicknames or primary browser-profile metadata, and never show masked emails or session hashes as email.

## 7. Known implementation gaps

The current implementation is not yet universally compliant with the policy above. Examples remaining in source: Kimi requires bounded usage; generic Additional Usage visibility uses positive-value gates and reset rows use `availableCount > 0`; some bounded-progress and reset fallback helpers default to zero or `No reset` without proving those semantics; Google Flow `nzlxg` element 5 (equal to the balance in the only live sample) may be the monthly allotment but is unverified, so no Flow progress bar is shown; Flow Music shows no reset because `/__api/billing/subscription` reports no `current_period_end`; Colab compute units are deferred. These are audit follow-ups, not approved exceptions. Change runtime behavior only within the requested scope; a documentation update alone does not fix or live-verify these adapters.

### Dola paid quota coverage

The no-subscription response is live-verified using Edge, including reported usage 0% and OGF quota 0/0. Paid entitlement/group response schemas have not yet been established. Nonempty entitlement/window groups produce compatibility warnings rather than guessed quotas. The OGF counter retains the provider's identifier because its product meaning is not established; no money/credit or reset semantics are inferred. Subscription agreement prices/cadences and raw status/source enums are not interpreted without established units/meaning.

### Shared credential error messages

Shared cookie/crypto readers must be provider-neutral. Provider adapters add their own name and selected source to storage errors; never leak another provider’s error text (e.g. Gemini) through a shared helper. Distinguish local decryption/storage failure from API session rejection and network unavailability, and never hide it with a fallback login.

### Single-flight rotation in Qoder and MiniMax

`QoderProvider` and `MiniMaxProvider` desktop OAuth refreshes persist rotated tokens, but do not yet wrap refreshes in an unstructured single-flight task to protect against actor reentrancy or mid-refresh caller cancellation; tracked as an audit follow-up outside the current Qwen scope.
