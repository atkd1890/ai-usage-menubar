# AGENTS.md

Rules for anyone (human or agent) changing this repository. Read this before
editing code. Keep it current: if a change makes a statement here false, fix
this file in the same commit.

This is a personal fork of
[burakgon/ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar),
forked at `v0.4.0` (`f0c9cfe`). Fork work lives on `develop`; `main` mirrors
upstream.

## 1. What the app is

A native macOS 26+ menu bar app (SwiftUI + AppKit, Swift 6, no Dock icon) that
shows remaining quota for AI subscriptions by reusing logins that already exist
on the Mac (desktop apps, CLIs, Edge/Chrome Default profiles). It never asks
for a password or API key.

## 2. Repository map

| Path | Contents |
| --- | --- |
| `AIUsage/AIUsageApp.swift`, `AppServices.swift` | App entry, service wiring |
| `AIUsage/MenuBar/MenuBarController.swift` | Status item, borderless `UsagePanel`, Settings/Dashboard windows, `AppSurfaceLayout` sizes |
| `AIUsage/Models/ProviderModels.swift` | `ProviderID` (+ `enabledCases`, `region`, install indicators, default metric), `QuotaKind`, `MenuBarMetricID`, `QuotaWindow`, `ProviderSnapshot`, `ProviderFailure` |
| `AIUsage/Providers/<Name>/` | One adapter per provider (auth store, client, mapper) |
| `AIUsage/Providers/WebUsageProvider.swift` | Browser/desktop cookie adapters for Claude, Codex, Cursor + `CredentialSelectingProvider` |
| `AIUsage/Providers/ConsumerQuotaProvider.swift` | Manus and Kimi |
| `AIUsage/Providers/ResponseSchemaWatch.swift`, `ConfirmedSchemaCatalog.swift`, `ConfirmedSchemaStore.swift` | API drift detection |
| `AIUsage/Providers/QuotaDiscovery.swift` | Helpers for unknown/extra quota buckets |
| `AIUsage/Infrastructure/` | HTTP, Keychain, read-only SQLite, LevelDB local-storage reader, Chromium Safe Storage codec, cookie import, account identity |
| `AIUsage/Store/` | `UsageStore` (polling), `AppPreferences`, `UsageHistory`, `TokenAnalytics`, `UsageAlerts`, dashboard projection/prices |
| `AIUsage/Views/` | Panel cards (`ProviderSectionView`), Settings, analytics dashboard |
| `AIUsageTests/` | XCTest suite, one file per provider/feature |
| `scripts/` | `install.sh` (local Release install), upstream release/screenshot scripts |

## 3. Non-negotiable rules

### Privacy and credentials

- Read credentials only from the exact source the user selected for that
  provider. **No silent fallback** to another source, browser, or account.
- Never print, log, or put tokens/cookies/emails in errors, diagnostics, test
  fixtures, or commit messages. Fixtures use obviously fake values.
- Requests go only to that provider's first-party hosts. Every client uses
  `GeminiReadOnlyHTTPClient(allowedHosts:)` (HTTPS only, host allowlist,
  redirects refused, no cookie jar, no cache). Add a host to the allowlist
  only when the adapter needs it.
- Cookie import (`WebSessionStore`) is read-only and limited to the allowlisted
  domain → cookie-name table. Add new cookie names there, never read all
  cookies.
- SQLite/LevelDB/auth files of other apps are opened read-only. Never write to
  another app's storage, except writing back a rotated token to the same
  source it came from when that tool requires it (Claude, Codex, upstream
  behavior).
- macOS privacy denial (`SQLITE_AUTH`, `EPERM`) is reported as a storage
  error. Do not bypass it (no DB copies, no immutable mode, no helper
  processes). The only sanctioned path is the user-picked security-scoped
  bookmark in `BrowserDatabaseAccess`.
- Never bypass CAPTCHA, anti-bot pages, Keychain access groups, or code-signing
  boundaries.
- Read-only: never redeem resets, buy credits, or call generation/chat
  endpoints.

### Data honesty

- Show provider values as reported. Missing data stays missing: never invent
  0%/100%, plan names, prices, or percentages from counters with no capacity.
- Shares of consumed usage (Claude breakdown, X/Cursor product split) are not
  quotas. Credit balances are not money unless the API says so.
- Free/missing plans render as **inactive** gray placeholders
  (`QuotaWindow(isInactive: true, inactiveDetail:)`), unlimited plans as
  `isUnlimited`. Neither is selectable in the menu bar.
- Failure policy: `transient`, `rateLimited`, `invalidResponse` keep the last
  snapshot (marked stale); `authentication`, `storage` clear it.

### Performance

- Idle CPU must stay ~0%. Avoid SwiftUI feedback loops (`ViewThatFits`,
  unbounded scroll fitting, re-assigning the status image on every
  appearance KVO). Hidden panel = no timers, no relayout.
- Polling happens only in `UsageStore` at the user interval; opening UI must
  not add fetches. Identity/email lookups run once per login-method selection
  (`AccountIdentityCache`).

## 4. Persisted state

`UserDefaults` (bundle `com.burakgon.aiusage`; tests use the
`com.burakgon.aiusage.test-host` suite and must never touch the real one) holds
preferences, login methods (`<provider>LoginMethod.v1`), seeding flags
(`<provider>ProviderAdded.v1`), email cache (`accountIdentity.v1.*`), Muse
action ID, browser bookmarks.

`~/Library/Application Support/AI Usage/`:

| File | Owner | Contents |
| --- | --- | --- |
| `quota-history.json`, `quota-limit-hits.json` | `UsageHistory` | Hourly quota samples and limit hits, 13 months, keyed by source + account identity |
| `token-history.json`, `token-file-cache.json` | `TokenAnalytics` | Token counts parsed from local `~/.codex/sessions`, `~/.codex/archived_sessions`, `~/.claude/projects` JSONL (metadata only, no message text) |
| `confirmed-schemas.json` | `ConfirmedSchemaStore` | User-approved schema changes |
| `kimi-auth.json`, `qwen-auth.json`, `minimax-auth.json`, `qoder-auth.json` | provider session stores | Rotated tokens for that provider, bound to a fingerprint of the source credential; dropped when the source changes or refresh is rejected |

Never change an existing key/raw value (`ProviderID`, `QuotaKind`,
`MenuBarMetricID`, defaults keys) — saved preferences and history depend on
them. Add new versioned keys instead.

## 5. Providers

`ProviderID.enabledCases` is the single list of providers that run and show.
Region splits the panel and Settings (US/CN segmented switch).

| Provider | Region | Login methods (first = default) | Credential source | Main endpoints |
| --- | --- | --- | --- | --- |
| Claude | US | Local OAuth, Claude desktop, Edge, Chrome | Keychain `Claude Code-credentials` / `~/.claude/.credentials.json`; desktop/browser `sessionKey*` cookies | `api.anthropic.com/api/oauth/usage` (`?cedar_ember=1` hourly for reset grants); `claude.ai/api/organizations/{id}/usage` |
| Codex | US | Desktop app / Local OAuth, Edge, Chrome | `$CODEX_HOME`/`~/.config/codex`/`~/.codex` `auth.json`, Keychain `Codex Auth`; `__Secure-next-auth.session-token*` | `chatgpt.com/backend-api/wham/usage`, `.../wham/rate-limit-reset-credits` |
| Cursor (shows as **X Subscription** when merged) | US | Desktop, Edge, Chrome | Cursor `state.vscdb` (safeStorage `v10`, `Cursor Safe Storage`); `WorkosCursorSessionToken` | `api2.cursor.sh` DashboardService RPCs; `cursor.com/api/dashboard/v2/usage-status`, `get-sand-usage-status` |
| Antigravity | US | Desktop | `Antigravity IDE` (else `Antigravity`) `state.vscdb` key `antigravityUnifiedStateSync.oauthToken` | `oauth2.googleapis.com/token`; `loadCodeAssist` + `retrieveUserQuotaSummary` on `cloudcode-pa` (Code Assist pool) and `daily-cloudcode-pa` (app pool), shown as two series |
| GitHub (Copilot) | US | Local OAuth / GitHub CLI, Local OAuth, GitHub CLI OAuth | `~/.config/github-copilot/{apps,hosts}.json`, `gh` config / Keychain `gh:github.com` | `api.github.com/copilot_internal/user` |
| Gemini | US | Desktop, Edge, Chrome | Gemini.app active account (`com.google.GeminiMacOS`, Keychain `Gemini Safe Storage`); browser `__Secure-1PSID(TS)` | `robinfrontend-pa.googleapis.com/.../GetUsageInfo` (protobuf); web `gemini.google.com` GraphQL |
| Muse | US | Edge, Chrome | `hatch_sess`, `hatch_gw` | `muse.ai` Next.js `fetchSubscriptionAction` (action ID rediscovered from public chunks when rotated) |
| Adobe | US | Edge, Chrome | `ims_sid` | Silent IMS `adobeid-na1.services.adobe.com/ims/authorize/v1` → `firefly.adobe.io/v1/credits/balance` |
| Manus | CN | Desktop, Edge, Chrome | `session_id` | `api.manus.im/user.v1.UserService/GetAvailableCredits` |
| Kimi | CN | Desktop, Edge, Chrome | `kimi-desktop` / browser Local Storage `access_token`/`refresh_token` (origin `https://www.kimi.ai`), else `kimi-auth` cookie | `www.kimi.ai/apiv2/...MembershipService/GetSubscription(Stats)`, `BillingService/GetUsages`; refresh `www.kimi.ai/api/auth/token/refresh` (needs `kimiNativeRefreshAllowed.v1`) |
| Qwen | CN | Desktop, Edge, Chrome | Qwen app / browser Local Storage `qwen_access_token_state`, `refresh_token` cookie | `auth.qwen.ai` refresh + `authorize/code` (forks an independent session so the app/browser login is not revoked); `sg-entitlement.qwen.com`, `sg-member.qwen.com` |
| MiniMax | CN | Desktop, Edge, Chrome | `~/.minimax/auth/prod/*/mcode-public/auth.json` (OAuth), MiniMax Hub `hub-config-global.json` (`v2enc` + `.token-key`); browser `_token` | `agent.minimax.io` membership, `platform.minimax.io` token plan, `design.minimax.io` wallet/profile, `hailuoai.video` credit/equity (signed requests) |
| Qoder | CN | Desktop, Edge, Chrome | `com.qoder.app.stable/auth.v1.dat` (`Qoder App Safe Storage`), else Qoder IDE `state.vscdb` (`Qoder Safe Storage`); `qoder_session_cookie` | `openapi.qoder.sh` usage/plan/refresh; `qoder.com/sash/api/v2/me/usage` |

Removed in the fork: Devin, Kiro, Z.ai, Grok. Do not resurrect them without
re-verifying live.

### Adding or changing a provider

1. Verify the contract live with the user's own login first (read-only
   requests only). Record nothing secret.
2. Add the `ProviderID` case (new raw value), `displayName`, icon asset
   (`Provider<Name>` template SVG), `region`, install indicators, default
   metric, `dashboardSubtitle`, `historyIdentity` prefix if session-scoped,
   `ProviderLoginMethod.supported`, seeding flag in `AppPreferences`, and
   registration in `UsageStore.defaultProviders()`.
3. Allowlist hosts and cookie names; fail closed on anything unexpected.
4. Map to `QuotaWindow`s; unknown buckets go through `QuotaDiscovery` /
   `.additional(id:title:)`, never dropped silently or guessed.
5. Add a baseline to `ConfirmedSchemaCatalog` and call `ResponseSchemaWatch`
   (headers, body deprecation, confirmed keys, enums) in the mapper.
6. Add tests with fake fixtures (mapper, auth loader, failure kinds).
7. Update the provider table above and the one in `README.md`.

### Schema drift watch

Each mapper diffs live responses against `ConfirmedSchemaCatalog` (+ user
overrides). New/missing keys, deprecation headers/bodies, unknown enums and
unsupported quota entries surface as a warning badge on the card; **Update**
records the reviewed diff in `confirmed-schemas.json`. When you change a
mapper to support a new field, update the catalog in the same commit so users
are not asked to confirm it. Previews must stay secret-redacted.

## 6. UI conventions

- Panel width 440 pt, Settings window fixed 750×640 (screen-clamped), dashboard
  min 1080×700 (`AppSurfaceLayout`).
- Cards start collapsed (first quota row only); chevron expands secondary rows,
  consumption share, resets, Additional Usage/Credits.
- Severity colors are shared by panel and menu bar: normal < 60% used,
  orange 60–85%, red ≥ 85% (`UsageSeverity`).
- Left/Used mode never inverts share charts.
- Use semantic system colors and solid backgrounds; preserve accessibility
  labels.

## 7. Build, test, install

Requires macOS 26+ and Xcode 27+.

```bash
# full test suite (run before every commit that touches Swift)
xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage \
  -destination 'platform=macOS' -derivedDataPath DerivedData-Test

# install a local Release build to ~/Applications and launch it
./scripts/install.sh
```

`DerivedData-*` and `dist/` are build output; never commit them.

Release/OTA (`scripts/package_release.sh`, `appcast.xml`, Sparkle key in
`Info.plist`) belong to upstream. The app's update check still points at the
upstream appcast with automatic install disabled. Do not publish fork releases
or edit `appcast.xml` unless the user asks.

## 8. Documentation and commits

- Docs are exactly `README.md` (user-facing) and `AGENTS.md` (maintainer
  rules + provider reference). Do not add `docs/`, journals, probe logs, or
  dated "update" sections. Edit the relevant section in place.
- `LICENSE` and `NOTICE` are legal obligations (MIT from upstream, OpenUsage,
  CodexBar). Never delete them or remove a copyright block.
- Commit messages: imperative summary line; body lists user-visible changes.
  One logical change per commit.
- When syncing upstream, merge `upstream/main` into `develop`; keep fork
  removals (Devin/Kiro/Z.ai/Grok) removed.

