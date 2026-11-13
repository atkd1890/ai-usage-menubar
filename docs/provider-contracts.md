# Provider contracts

This document records the narrow external contract used by AI Usage. It is
intentionally limited to quota windows that can be fetched from credentials
the supported tools already store locally.

The reference implementation was OpenUsage `v0.7.6`, its local language-server
discovery from `v0.7.16`, and provider updates through commit
`fdf7a234b76b6a71522880cc9ab5b38044471698`. These are undocumented provider
endpoints and may change; fixture tests protect the currently known behavior.

## Claude Code

Credential source order:

1. macOS Keychain current-user item
2. macOS Keychain legacy service-only item
3. `$CLAUDE_CONFIG_DIR/.credentials.json`, otherwise
   `~/.claude/.credentials.json`

The production Keychain service is `Claude Code-credentials`. With
`CLAUDE_CONFIG_DIR`, the app first tries the service suffixed with the first
eight lowercase SHA-256 characters of the normalized directory, then the
production service.

`CLAUDE_CODE_OAUTH_TOKEN` is not a live-usage credential and is never selected.
A stored non-empty `scopes` array must contain `user:profile`; absent or empty
scope metadata is treated as unknown and allowed.

Usage request:

- `GET https://api.anthropic.com/api/oauth/usage`
- `Authorization: Bearer <access token>`
- `anthropic-beta: oauth-2025-04-20`
- `User-Agent: claude-cli/2.1.318 (external, cli)`

At most once an hour, the same read adds `?cedar_ember=1`, which also returns
Claude Code's banked usage-limit reset grants in `cedar_ember`. Anthropic
throttles this variant when it is polled, so it replaces the plain read instead
of adding a request, and a `429` on it postpones the next grants read by an
hour. Anthropic shows grants only to a recent Claude Code on its CLI surface;
`ineligible_reason` `surface` or `cli_version` is treated as unknown, while
`no_grant` is a known zero.

Mapped fields:

| JSON field | UI row |
| --- | --- |
| `five_hour.utilization` | Session |
| `seven_day.utilization` | Weekly |
| `seven_day_sonnet.utilization` | Sonnet |
| `limits[kind=weekly_scoped, scope.model.display_name=Fable].percent` | Fable |

Every row reads `resets_at`, accepting ISO-8601 with variable fractions and no
timezone (assumed UTC), epoch seconds, or epoch milliseconds.

A grant contributes `resets_left` resets until `ends_at`; a null `ends_at`
never expires, and expired grants are not counted. `extra_usage` reports
`used_credits` and `monthly_limit` in minor units of `currency` with
`decimal_places` digits, defaulting to US cents.

Refresh request:

- `POST https://platform.claude.com/v1/oauth/token`
- JSON body with `grant_type`, `refresh_token`, `client_id`, and `scope`
- client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- scope string:
  `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`

The access token is refreshed within five minutes of `expiresAt` (epoch
milliseconds). A usage `401` or `403` causes at most one refresh and one retry.
`invalid_grant` means the session expired. A `429` honors `Retry-After`
(seconds or HTTP date) up to an hour, and always waits at least the backoff:
five minutes, doubling with each consecutive `429` up to an hour. The cooldown
applies to manual refreshes too, because Anthropic budgets this endpoint per
account and keeps its own penalty.

The display plan follows Anthropic's names: `max` with a `20x` or `ultra`
`rateLimitTier` is **Ultra**, other `max` plans are **Max**, and other plans
are title-cased `subscriptionType` plus an `Nx` fragment from `rateLimitTier`.

## Codex

Credential source order:

1. `$CODEX_HOME/auth.json`, when `CODEX_HOME` is set
2. otherwise `~/.config/codex/auth.json`
3. then `~/.codex/auth.json`
4. macOS Keychain service `Codex Auth`

An auth document uses `tokens.access_token`, `refresh_token`, `id_token`, and
`account_id`, plus top-level `last_refresh`. A document containing only
`OPENAI_API_KEY` produces “Usage not available for API key.”

Usage request:

- `GET https://chatgpt.com/backend-api/wham/usage`
- `Authorization: Bearer <access token>`
- optional `ChatGPT-Account-Id`

The main `rate_limit.primary_window` and `secondary_window` objects use
`used_percent`. Response headers `x-codex-primary-used-percent` and
`x-codex-secondary-used-percent` are fallbacks.

Windows are classified by `limit_window_seconds`:

- `18000`: Session
- `604800`: Weekly
- unknown or missing duration: primary/secondary slot fallback

The first `additional_rate_limits` entry whose `limit_name` or
`metered_feature` contains `spark` case-insensitively is mapped through the
same classifier to Spark and Spark Weekly.

Reset time uses epoch-seconds `reset_at`, then relative
`reset_after_seconds`. The display plan uses OpenAI's published names:
`prolite` is `Pro 100`, `pro` is `Pro 200`, `promax` is `Pro 500`,
`self_serve_business_prolite` is `Business Premium`, and other
underscore-separated values are title-cased.

Credits come from `credits.balance`, then `x-codex-credits-balance`. When
`credits.has_credits` or `x-codex-credits-has-credits` is false, no Credits row
is shown.

Banked rate-limit resets are counted from `rate_limit_reset_credits.available_count`
on every read. Their expirations come from
`GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` with the same
bearer and account headers plus `OpenAI-Beta: codex-1` and
`originator: Codex Desktop`. Only `available` entries are listed. The list is
read only while resets exist: hourly, or after five minutes when its
`available_count` no longer matches the usage count. A list that disagrees with
the current count never supplies expirations. Nothing is redeemed.

Refresh request:

- `POST https://auth.openai.com/oauth/token`
- `application/x-www-form-urlencoded`
- client ID `app_EMoamEEZ73f0CkXaXp7hrann`

JWT `exp` is the primary refresh clock with five minutes of slack. Only when
`exp` cannot be decoded does `last_refresh` older than eight days trigger a
refresh. With neither value, no proactive refresh occurs. Before proactive
refresh, the exact credential source is re-read so a token already rotated by
the Codex CLI is adopted.

The recognized refresh failures are `refresh_token_expired`,
`refresh_token_reused`, and `refresh_token_invalidated`. A usage `401` or `403`
causes at most one refresh and one retry.

## Additional providers

| Provider | Local credential source | First-party usage contract | Mapped metrics |
| --- | --- | --- | --- |
| Cursor | Cursor state SQLite database, then `cursor-access-token` and `cursor-refresh-token` Keychain items | `api2.cursor.sh` DashboardService Connect RPCs | Total, Auto, API, personal on-demand spend |
| Antigravity | Keychain service `gemini`, account `antigravity` | Google Cloud Code quota summary, then a running Antigravity app or `agy` CLI | Gemini session/weekly, Argon weekly, Claude session/weekly |
| GitHub Copilot | Copilot editor config, GitHub CLI config, then `gh:github.com` Keychain item | `api.github.com/copilot_internal/user` | Credits, Chat, Completions |
| Devin | `~/.local/share/devin/credentials.toml`, then Devin state SQLite database | Codeium SeatManagement Connect RPC | Daily, Weekly |
| Grok | `~/.grok/auth.json` | Grok CLI billing and settings APIs | Weekly |
| Kiro | `~/.aws/sso/cache/kiro-auth-token.json` (or `-cli.json`), then `KIRO_API_KEY` | `q.<region>.amazonaws.com/getUsageLimits` | Credits, Free Trial |
| Z.ai | `ZAI_API_KEY`, Claude Code `settings.json` pointed at Z.ai, then OpenCode `auth.json` | `GET /api/monitor/usage/quota/limit` on `api.z.ai` or `open.bigmodel.cn` | Session, Weekly, Web Searches |

Copilot tries editor credentials first, then the GitHub CLI config and Keychain
if a credential is rejected with `401` or a non-rate-limit `403`. Duplicate
tokens are tried once per fetch; fallback Keychain reads are deferred until
needed. Rate limits, network errors, server failures, and response parsing errors
do not trigger credential fallback. A final `403` reports an access/permissions
problem rather than asserting that the token expired. Credentials are never
removed or rewritten by this fallback.

On macOS, Cursor SQLite credentials prefixed with `cursor-safe-storage:v1:`
are Electron safeStorage values. AI Usage decrypts the Chromium `v10` envelope
in memory using the existing `Cursor Safe Storage` Keychain password (PBKDF2
SHA-1, 1003 iterations, AES-128-CBC). It never creates or replaces that key.
Refreshed access tokens retain the encrypted SQLite format; legacy plaintext
and token-specific Keychain credentials remain supported. Missing or denied
Keychain access and invalid envelopes report storage errors, not expired sessions.
No plaintext credentials are logged or written to temporary files.

Cursor, Antigravity, and Grok refresh expiring access tokens using the refresh
credential already stored by the corresponding tool. Kiro does the same, but
only with the client registration Kiro itself stored. Refreshed tokens are
persisted only where necessary; Antigravity's derived access token is cached
privately by AI Usage and bound to a hash of the current refresh credential.

Devin omits a zero `*QuotaRemainingPercent` in proto3 JSON, so a window with a
reset time and no share is fully used. Grok answers `412` with "no personal
team" for team accounts, which have no personal quota. GitHub sends rate limits
as `429` or as `403` with `x-ratelimit-remaining: 0` or `Retry-After`; those
wait until `x-ratelimit-reset` instead of reporting a rejected token. Cursor's
`spendLimitUsage` is shown as extra usage only for a personal limit or personal
spend, never for a team's shared pool.

### Kiro

Kiro and `kiro-cli` keep their AWS SSO token in
`~/.aws/sso/cache/kiro-auth-token.json` (`kiro-auth-token-cli.json` for
`kiro-cli`). Only Kiro's own client registration is read: the `*.json` file
named by the record's `clientIdHash`. Other files in that directory belong to
whatever else signed in through `aws sso login` on the Mac, and their client
secrets are never sent in a refresh. When no token file exists, `KIRO_API_KEY`
is read through `LoginShellEnvironment` and used directly as the bearer token.
Kiro documents that variable, and that it may be unset to sign out, in the
CLI's bundled `features/api-key-authentication` guide (`kiro-cli login --help`,
`kiro-cli logout`). AI Usage never asks for credentials.

`GET https://q.<region>.amazonaws.com/getUsageLimits?origin=AI_EDITOR&resourceType=AGENTIC_REQUEST`
returns a `usageBreakdownList`. A `CREDIT` entry with a `usageLimit` is
Credits, the only limit a live account has been seen to report; any other
entry is left out rather than given a label Kiro never used. An active
`freeTrialInfo` on an entry adds a Free Trial window, with its own limit and
`freeTrialExpiry`, beside that entry's Credits. Each window appears once, so a
repeated entry cannot collide with another on one window id. The plan is
`subscriptionInfo.subscriptionTitle` without the leading "Kiro", so
`KIRO PRO+` reads as Pro+. Without a title there is no plan: a missing
subscription is not evidence of Free, and `type` is an internal identifier
such as `Q_DEVELOPER_STANDALONE_STUDENT`. An enabled `overageConfiguration`
adds on-demand spend from `overageCharges`, capped by `overageCap × overageRate`
only when Kiro reports both. No rate is assumed.

A `401`/`403` refreshes the token once through
`https://oidc.<region>.amazonaws.com/token` and writes the rotated access and
refresh tokens back into the same file, preserving unknown fields. Because Kiro
refreshes the same token, the store re-reads the file before writing and
abandons the write when `refreshToken` changed since the state was loaded.
`region` comes from the token file and is interpolated into both hosts, so it is
accepted only when it matches an AWS region name
(`^[a-z]{2}(-[a-z]+)+-\d+$`); anything else falls back to `us-east-1`. A `5xx`
from the OIDC endpoint is a transient failure, not a sign-out. A rejected
`KIRO_API_KEY` is reported as the key's rejection, since there is no sign-in to
renew. A `429` honors `Retry-After`.

### Antigravity

Cloud Code requests use the Antigravity client's own identity:
`User-Agent: antigravity/2.24.0 (aidev_client; os_type=darwin; arch=arm64)`
(`amd64` on Intel). With any other User-Agent, Google answers the quota summary
without the Gemini group and `loadCodeAssist` without `paidTier`.

1. `POST /v1internal:loadCodeAssist` with
   `{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}`,
   read at most hourly, supplies the plan (`paidTier.id` `g1-pro-tier`,
   `g1-ultra-tier`, or `g1-ultra-lite-tier`, then the tier name) and
   `cloudaicompanionProject`.
2. `POST /v1internal:retrieveUserQuotaSummary` with `{"project": …}` goes to
   `cloudcode-pa.googleapis.com` first, then `daily-cloudcode-pa.googleapis.com`
   unless production already returned all four shared pools. Buckets are merged
   by id, first answer winning.

`gemini-5h`, `gemini-weekly`, `3p-5h`, and `3p-weekly` map to Session, Weekly,
Claude, and Claude Weekly. Argon Weekly is the single enabled weekly bucket of
the `Gemini 4 Argon` group, or a `gemini-argon-wtu-weekly` bucket. A bucket
without a usable `remainingFraction` is dropped rather than shown as 0% or 100%.
`fetchAvailableModels` is not used: it reports `remainingFraction: 1` for every
model even when the weekly quota is nearly gone.

A `401` renews the Google token once. A `403` means Google does not share quota
for this account (such as `PERMISSION_DENIED` #3501 on Starter accounts); it is
not a sign-out, so the last reading stays visible while AI Usage asks a running
Antigravity tool instead. That fallback finds the Antigravity app's
`language_server` (by its `--ide_name` or `--app_data_dir` flag, or its app
bundle path) or the `agy` CLI, reads only those processes' own listening ports
with `lsof -a -p`, and calls `RetrieveUserQuotaSummary` on `127.0.0.1` with the
tool's CSRF token. The app passes its token as `--csrf_token`; `agy` hands it to
the processes it starts as `ANTIGRAVITY_CSRF_TOKEN`. The loopback listener's
self-signed certificate is trusted only for `127.0.0.1`.

### Z.ai

AI Usage never asks for a Z.ai key. It reuses the first GLM Coding Plan key it
finds: `ZAI_API_KEY`; Claude Code `settings.json` whose
`env.ANTHROPIC_BASE_URL` points at `api.z.ai` or `open.bigmodel.cn`, with
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`; or OpenCode's
`~/.local/share/opencode/auth.json` entries `zai-coding-plan`, `zai`,
`zhipuai-coding-plan`, and `zhipuai`. Zhipu keys go only to `open.bigmodel.cn`,
the others only to `api.z.ai`. Z.ai is shown only while such a key exists.

`CREDIT_LIMIT` and `TOKENS_LIMIT` entries become windows from `unit` (3 hours,
4 days, 6 weeks) times `number`: shorter than a day is Session, shorter than a
week Daily, and shorter than four weeks Weekly. `percentage` is the used share
and `nextResetTime` is epoch milliseconds. `TIME_LIMIT` is Web Searches,
`currentValue` of `usage`. `data.level` is the plan.

OpenCode is intentionally not included: its current limits require scanning
local usage databases and are machine-local estimates, which conflicts with
AI Usage's no-background-log-scanning design. OpenRouter is also excluded
because it requires users to add an API key instead of reusing a local agent
login.

## Persistence and failure policy

Rotated credentials are persisted only to the source from which they were
loaded. Claude compares the complete ordered credential generation before
writing and again before publishing usage. Codex compares the exact source
before writing. This prevents an in-flight refresh from overwriting a new CLI
login.

Temporary network failures, `429`, server errors, denied Antigravity quota, and
invalid response shapes preserve the last-good in-memory snapshot and mark it
stale. Authentication and storage failures clear that provider's snapshot.
Every `Retry-After` is honored for at most an hour.

## Gemini native app

Gemini defaults to the explicit `nativeApp` credential source. Settings permits
Gemini app, Edge Default, or Chrome Default. Each source has separate consent;
there is no automatic native/browser or cross-account credential fallback.
The card shows the selected credential source and, for native, its active
account email. That label is UI-only and is never logged.

Native credential discovery was verified against Gemini.app 1.135.1.1291:

- Root: `~/Library/Application Support/com.google.GeminiMacOS`.
- Read `account_config` protobuf field 4 for the active local `userN` directory.
  Accept only that directory-name format; never scan other accounts for a token.
- Read only `Data/<active>/auth` and Keychain service `Gemini Safe Storage`,
  account `Gemini Keys`. `/usr/bin/security -w` represents its binary Keystore
  protobuf as hexadecimal. Match credentials key ID 1 and the envelope version.
- The auth envelope starts with two little-endian `0xcafeba2e` values and a
  little-endian uint32 preamble length. DataPreamble fields are key ID (1), key
  version (2), data format (3), nonce (4), and ciphertext length (5). Format 1
  is AES-256-GCM with a 12-byte nonce, a trailing 16-byte tag, and no AAD.
- StoredCredentialData fields used are email (2), refresh token (4), and ID
  token (8). The ID token audience chooses the installed app's public OAuth
  client ID. Read the client config from the installed executable, require that
  audience to be present, and require an unambiguous valid client-secret marker.
  Version 1.135 ships the 35-byte public installed-app secret XOR 0x5a. It is
  not copied into source or logged. A changed binary layout fails explicitly.

Use POST `https://oauth2.googleapis.com/token` with the native client config,
refresh grant, and `https://www.googleapis.com/auth/assistant` scope. Gemini's
`gemini` scope alone is insufficient for this native quota RPC. Then POST an
empty protobuf request to:

`https://robinfrontend-pa.googleapis.com/$rpc/assistant.mobile.robin.RobinService/GetUsageInfo`

Use Bearer authorization and `application/x-protobuf`. This backend does not
accept JSON/JSPB for the service. GetUsageInfoResponse field 3 repeats Usage
records: field 1 is pool type (1 = five-hour, 2 = weekly); field 2 is GxuPool.
GxuPool field 1 is the reset Timestamp (seconds 1, nanos 2); field 2 is a float32
used fraction. Missing fractions remain absent. Native tier enums are not
mapped to plan names until their meaning is independently verified.

The access-token cache is memory-only, expires with a 60-second safety margin,
and is bound to the native client ID and refresh credential. Each fetch reloads
the active account; account changes invalidate token reuse. Only a 401 triggers
one refresh/retry. Browser cookies, native auth files, and Keychain entries are
never rewritten; no tokens are persisted in the tracker. Both native hosts are
allowlisted and all redirects are refused. Native access requires the separate
`geminiNativeAccessAllowed.v1` setting.

Live native OAuth, quota parsing, cache reuse, and Antigravity comparison were
verified locally on 2026-11-11. Regression fixtures contain only independently
generated fake credentials and ciphertext. These are private Google app formats
and can change; native means the active app's account, not a guarantee that its
internal API will never change.

## Gemini web/app fallback

This provider reads the Gemini **web/app** usage meter, not Gemini CLI,
Antigravity, or Gemini API quota. The card is `Gemini`; its source label identifies the chosen browser.

Credential access is opt-in and separate for Chrome Default
(`geminiChromeCookiesAllowed.v1`) and Edge Default (`geminiEdgeCookiesAllowed.v1`).
Both default to false. Provider tracking, source selection, and credential
consent are separate settings. Default profiles are supported; the macOS default
browser does not change the selected source. Read-only SQLite queries select exactly `__Secure-1PSID`
and optional `__Secure-1PSIDTS` at `.google.com`. Encrypted values use the existing
selected browser’s `Chrome Safe Storage` or `Microsoft Edge Safe Storage` Keychain password and macOS Chromium OSCrypt v10. For
cookie schema v24+, the SHA-256 host prefix is verified and removed. Nothing
is copied to temporary storage or written back to the browser. Chat content,
history, and other cookies are not read.

The authenticated GET endpoint is:

`https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery`

The UsagePageQuery signature is
`2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g=`. Variables request the
`GEMINI_USAGE_SETTINGS_UPGRADE_BANNER` entrypoint and empty Workspace surface
recommendations. This undocumented contract was cross-checked with
[CodexBar's Gemini web implementation](https://github.com/steipete/CodexBar/blob/7447bc77c2497323d9c41e40164ce705533493c8/Sources/CodexBarCore/Resources/Plugins/gemini-web.ts).
The client allows HTTPS requests only to `gemini.google.com`, refuses all
redirects, uses ephemeral URLSession storage, and never logs request cookies.

After stripping Google's XSSI prefix, read
`data.viewer.rpcs.getUsageInfo.pools`. `GXU_FIVE_HOURLY` maps to Session and
`GXU_WEEKLY` to Weekly. `percentageUsed` is a fraction (multiply by 100);
`gxu.windowRefreshesAt` supplies each reset. Missing/null/invalid meters stay
absent, never 0% or 100%. Only `subscriptionTier == TIER1` is currently mapped
to Google AI Pro; unknown tier enums remain unnamed. Null viewers, auth
redirects, and HTML sign-in pages require web sign-in. A 429 remains rate
limited and 5xx remains transient; schema changes report invalidResponse.

Google's current product documentation distinguishes these entitlements:

- [Gemini web/app](https://support.google.com/gemini/answer/17004136?hl=en)
  uses compute-based five-hour and weekly limits.
- [Antigravity](https://www.antigravity.google/docs/plans) has its own
  baseline quota and weekly limits; Google One describes its baseline as
  [specific to Antigravity](https://support.google.com/googleone/answer/14534406?hl=en).
  Neither implementation treats web and Antigravity meters as interchangeable.
- [Gemini CLI consumer migration](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/):
  AI Pro/Ultra and free individual access stopped on June 18, 2026 in favor
  of Antigravity CLI. Enterprise and paid API-key modes remain separate.
  A Gemini API key is not a credential for the web subscription usage meter.

Live verification status is recorded in the local task, not inferred from
fixture tests. The GraphQL signature and schema may change independently of
this app's releases.


### X Subscription (unified Cursor account)

The Cursor adapter keeps its persisted provider ID so tracking, order and menu selections survive.
On `GetPlanInfo.isMerged == true` (or a weekly plan confirmed by `isUnified`), the same card becomes
**X Subscription**, including Settings and the menu bar. Legacy accounts retain a single Cursor card.
There is no second X card and no duplicate independent Cursor pool.

Credential: existing Cursor native SQLite safeStorage token. Derive the user from its JWT subject
and send `WorkosCursorSessionToken=<user>%3A%3A<token>` only to these read-only Cursor dashboard routes:
- GET `/api/dashboard/v2/usage-status?scope=user`
- POST `/api/dashboard/get-sand-usage-status` with `{}`

The HTTP client disables cookies/cache, restricts HTTPS hosts to cursor.com/api2.cursor.sh, and rejects redirects.
`weeklyIncludedUsage.usedCents / budgetCents` gives the shared weekly percentage; use current period dates.
Product breakdown is shown only if all valid entries sum to total within one cent. Unknown product identifiers
remain literal (e.g. `grok-tasks`); they are not guessed to be Cursor or independent quotas.
`monthlyUsage.usedCents / limitCents` supplies Additional Usage with its own reset and enabled flag;
`creditsUsedCents` is not added. Missing/expired monthly data is unavailable, never the old RPC's false zero.
`prepaidAvailableCents` is a separate USD balance. Included cents are quota weights, not cash balance.
`resetCounter` is not mapped to available reset inventory. Old menu metric selections resolve to the weekly
pool for compatibility; the dashboard renders it once.

Verified live through the actual Swift provider on 2026-11-12: unified weekly window, current Additional
Usage, and prepaid balance all present. Synthetic regression tests cover legacy behavior, unavailable billing,
expired periods, incomplete breakdown, native identity cookie and endpoint restriction.


### Shared quota labels and scoped credits (2026-11-12)

- Claude card is named Claude: subscription limits apply across Chat and Code. Credential service names and stored IDs remain unchanged.
- Codex retains its product name and explicitly describes shared Codex/ChatGPT Work allowance. Do not label all ordinary ChatGPT chat as included before account-specific rollout evidence. Official announced broader sharing starts December 2026.
- Antigravity `3p-*` buckets are labelled Third-party, not Claude. They are not the user's direct Anthropic subscription quota.
- Gemini and Antigravity remain separate baseline quota cards; neither duplicates an invented Google AI Pro master quota or AI credit balance.
- Copilot credits_used is displayed per returned Chat/Completions/Premium bucket, never summed or converted to USD. has_quota=false buckets are omitted. Missing credit values are not zero; invalid numbers are ignored. Included budget/actual extra spending are not inferred from credits_used.
- Live Copilot Individual response: token_based_billing true, Chat credits_used 0, Completions credits_used 138, Premium has_quota false. This does not prove the two bucket counters are disjoint.
- Live Codex Plus response: five-hour/weekly rate limits; additional_rate_limits/code_review_rate_limit null, model availability but no product split, no monetary spend limit. Banked resets available_count=1 but applicable_available_count=0; the UI now distinguishes banked inventory from resets usable now.


### Google AI presentation group

Gemini and Antigravity render inside one Google AI card, anchored at the first visible Google product
in saved order. They retain independent provider IDs, authentication, fetch/error/stale state and menu metrics.
Each child keeps its actual plan/account/source. A shared header plan badge is allowed only when both
nonempty account labels and plan names match; plan-name equality alone is not identity evidence.
Settings groups the two product rows under Google AI and keeps separate tracking and metric controls.
Menu accessibility labels explicitly qualify Google AI plus the selected product. There is no averaged
Google percentage, synthetic shared quota or duplicated AI credit wallet. One disabled/uninstalled product
is omitted without hiding the other. One failing product cannot discard the other's last valid quota.

X breakdown rechecked live on 2026-11-12: backend still returned grok-tasks=324 and grok-chat=29,
matching shared usedCents=353. No Cursor-specific entry was returned. This is not evidence of zero Cursor
usage, and grok-tasks is not relabelled Cursor without a verified product mapping.


### Live cross-credential experiment (2026-11-12)

Tested Gemini-native first, Antigravity-native second, without altering installed app connections or
persisting access/refresh tokens. Temporary credential-reading XCTest probes were removed afterwards.

- Gemini native refresh with assistant only: Gemini usage HTTP 200 (2 quota windows), Antigravity
  production/daily plan and quota APIs HTTP 403 ACCESS_TOKEN_SCOPE_INSUFFICIENT.
- Gemini native refresh with its existing grants or cloud-platform: Antigravity production/daily plan
  and quota APIs HTTP 200, 4 quota windows. No new interactive grant was requested.
- Antigravity native refresh with its existing grants: Antigravity plan/quota HTTP 200, Gemini usage HTTP 403.
- Antigravity native refresh requesting assistant: token endpoint HTTP 403 restricted_client.
- Final minimal-scope test: ONE access token refreshed from Gemini native credentials with exactly
  assistant + cloud-platform successfully fetched Gemini session/weekly (2 windows), and Antigravity
  Gemini session/weekly + third-party session/weekly (4 windows), plan Google AI Pro.

Thus one Gemini native credential source and one in-memory scoped access token can serve both providers
on the tested account. Two quota APIs remain necessary; the pools remain independent. This is a live
feasibility result, not yet an installed production connection change or a universal guarantee for other accounts.
Result metadata only: /tmp/google-combined-credential-result.json; no credentials in that report.


### Production shared Google AI connection (supersedes separate native logins)

Default UsageStore now constructs one GoogleAISession and injects it into GeminiNativeProvider and
GoogleAIAntigravityProvider. The active Gemini native credential refreshes ONE access token with exactly
assistant + cloud-platform. Concurrent consumers share an in-flight refresh. Token/refresh credentials
are never persisted by this session. Each read rechecks consent and active account; mismatched account
responses are rejected. A 401 can renew once; an old rejection cannot invalidate a newer token.
Antigravity requests use a redirect-blocked, HTTPS host-restricted client, with the native client metadata.
There is NO fallback to Antigravity Keychain/cache/loopback or browser login in this production path.
Legacy adapters remain available in source for compatibility/tests but are not instantiated by default.

Google AI Settings is one row: master Track and Menu Bar switches, product-qualified quota checkboxes
on the right, and one native credential permission. Saved provider/metric IDs remain intact. Browser
alternatives are no longer offered by the shared connection settings. The badge appears at the Google AI
header; embedded product headers have no plan badges. A known plan from one product can label the group
only when all displayed account identities agree; unknown Gemini native tier is never guessed.

Live final production-session test passed: simultaneous Gemini (2 windows) and Antigravity (4 windows),
same account, one OAuth refresh, Google AI Pro header. 112 targeted regression tests passed before final
wiring cleanup. Temporary live credential tests were removed.


### X dashboard visualization

Weekly quota remains the primary progress bar. Immediately below it, a stacked product bar visualizes
shares of consumed weekly usage, with stable colors for grok-tasks, grok-chat and cursor. The legend
includes zero-valued reported products; an all-zero breakdown uses an empty track and no artificial
segment widths. Its denominator is consumed usage and does not change with Left/Used mode.
Additional Usage has its own bounded-spend progress bar, respecting Left/Used mode, and a separate
monthly reset. Missing or zero spend caps do not create an invented percentage. Prepaid stays a balance.


### Unified sections and menu colors (2026-11-12)

One Additional Usage section renders actual monetary spend/cap, a progress bar only when enabled with a
known positive cap, and optional monetary balance in its header (no standalone prepaid row). Explicit Off
remains visible, without a progress bar or spending rows; missing data is never inferred to be Off or $0.
Claude OAuth now exposes typed `spend.used`, `spend.limit`, `spend.balance`: money requires explicit
amount_minor/currency/exponent. Live account: spend.enabled=false and balance=null, so show Off only.
Legacy extra_usage is retained as fallback when typed spending is absent. Current Google quota responses
have no verified monetary balance/spend cap; no synthetic billing or reset inventory is created.
Codex raw credit balances and their old fixed-rate USD estimate are excluded from panel/menu choices.
Copilot raw per-bucket credits_used details are no longer populated; percentage quotas remain.

Codex applicable_available_count now lives in UsageResets.usableCount. Its inline presentation can read
`1 available · 0 usable now`, with existing expiry context; there is no separate usable row. Expiry clamps
usable counts to remaining banked resets. Claude's existing reset grants remain. X resetCounter is still
not treated as an inventory. No confirmed banked-reset response exists in the current Google connection.

Panel/menu percentage text shares thresholds: normal below 60% consumed, orange 60–<85, red >=85.
Left mode severity derives from consumed percentage. The status image is non-template to preserve
per-number color; icons/labels use appearance-aware label color and rerender on effective appearance
changes. A pixel-level test verifies simultaneous orange/red rendering. 3rd-party replaces Third-party.
X share caption is `Share of usage consumed` in primary text; product names are secondary and share
percentages primary. Both quota and product-share bars are 4px high.


### Claude consumed-usage breakdown

Claude OAuth seven_day_breakdown.rows supplies key/display_name/percent for Claude Code, Chats,
Cowork and Other. These are shares of consumed weekly usage, not independent quotas or share of total
weekly capacity. The common stacked chart now renders both Claude and X, with 4px bars, secondary
product names and primary percentage text. Claude places it after Session/Weekly and before Fable.
Left/Used does not invert attribution shares. Preserve API labels and reported zeros, and reject duplicate
keys, invalid/partial totals, future or expired/previous-period data. Missing data hides the breakdown.
Live inspection on 2026-11-12 returned Cowork=100%, the other three=0%; this is backend attribution,
not an inference about which desktop/CLI client ran the request. No new credential or endpoint is needed.


### Display preference update (latest, 2026-11-12)

Claude breakdown claude_code is labelled Code. Claude quota order is Session/Weekly, then Fable,
then other scoped quotas, followed by consumed-usage breakdown. Additional Usage is hidden when
explicitly Off or when no meaningful monetary spend/cap/positive balance is reported. This supersedes
the earlier show-Off-row rule. Codex with no credits has no Additional Usage section; raw credit
counts and estimated dollar conversions remain hidden.


### Card separator rule (2026-11-12)

Render only one horizontal divider at the boundary between quota/share content and monetary/reset
content, and only when both sides contain visible data. Quota cells, scoped quota rows, consumed-share
charts and Google product subsections have no internal dividers. Google subsections use spacing instead.
Banked reset inventories currently come from Claude and Codex; X resetCounter is not treated as inventory.


### Latest layout refinements

Google AI retains one horizontal divider between Gemini and Antigravity. Its plan badge strips the
redundant Google AI prefix (e.g. Pro). Consumed-share legends/segments omit exact zero entries while
preserving positive values even when rounded display is 0.0%. Raw attribution remains intact. The panel
maximum height is now 100% of the active screen's visibleFrame, with overflow scrolling as before.


### Native Settings window

The gear button and Settings menu open a reusable titled NSWindow, not a settings route inside the
status-item popover. Opening Settings closes the usage popover and activates the app; reopening brings
the existing settings window forward. Standard close/minimize controls and Window menu Cmd-W/Cmd-M
are available. The obsolete back-to-Usage header is hidden in the window. Settings retain shared live
preferences, fixed readable width, vertical resizing and overflow scrolling. Closing Settings does not
stop polling or close the menu-bar app. The controller closes/releases its window during shutdown.
Window lifecycle and light/dark layout tests passed; old 500px/nine-provider layout assertions were
updated to match the previously authorized full-height dashboard and current provider grouping.


### Fixed Settings design size (supersedes resizing)

Settings uses a fixed 560x640-point content area, clamped vertically only when the active screen cannot
fit it. Resizable style is removed, min/max content sizes match, and the zoom button is hidden.
Overflow stays inside the existing scroll fallback; users move/close/minimize the window without resizing it.


### Lightweight arrowless dashboard (supersedes NSPopover/glass)

The usage surface is now one lazily created borderless UsagePanel, not NSPopover, so it has no native
arrow. The NSPanel/NSHostingController are reused across opens and released on controller shutdown.
Frame/visibility changes and native window transitions use no animation. Dashboard/cards/badges/footer
and Settings use solid appearance-aware backgrounds instead of Liquid Glass/material containers.
Settings remains a separate fixed-size 560x640 window (screen-clamped), with zoom/resize disabled.

Outside-click monitors exist only while the panel is visible, and are removed on dismissal. Escape,
local/global outside clicks and key resignation dismiss the panel; clicking the status item toggles it.
Panel placement is anchored to its status button and clamped to that screen's full visible frame.
Visible data/order changes remeasure the existing host; hidden changes do not trigger panel sizing.

Cached quota/reset timers use UsageMinuteSchedule: one initial value and no periodic entries while
hidden. Hidden refresh/status spinners and relative footer time are also paused. Provider polling stays
active for the menu bar, and opening the panel does not add a separate fetch loop. Unchanged menu-bar
readings reuse their existing image; effective appearance changes still force recoloring.
Regression tests verify reuse, no animation, Escape/outside click dismissal, hidden schedule behavior,
fixed Settings, and light/dark layouts. These are structural resource reductions; no RAM/CPU percentage
benchmark was claimed.


### CPU redraw feedback-loop fix (2026-11-12)

Live AI Usage PID 54862 sustained 98.5% CPU. sample showed NSStatusItem replication/drawing plus
MenuBarController.start effectiveAppearance KVO tasks repeatedly forcing updateStatusItem. AppKit emits
appearance invalidations during status-item replication even without a real light/dark change; forcing
button.image assignment from every notification created a redraw → KVO → redraw feedback loop.

Status image updates now compare both actual readings and resolved aqua/dark/high-contrast appearance,
recording the rendered key before assigning the image. Unchanged notifications do not replace the image.
Regression sends 1,000 same-appearance notifications and also lets native queued callbacks settle while
asserting image identity remains stable. Genuine appearance changes still invalidate the render cache.
24 relevant tests passed; Release installed and signature/binary verified.

Post-fix installed PID 83820: after 8s startup settling, 7 ps samples over 12.09s were all 0.0% CPU;
CPU-time delta was 0.01s (~0.083% average). A new 3s sample showed the main thread waiting in mach_msg,
not redrawing. This is an idle measurement, not a claim that active refresh/render CPU is always zero.
Metadata: /tmp/aiusage-cpu-fix-measurement.json; before/after stacks: /tmp/aiusage-highcpu-sample.txt and
/tmp/aiusage-fixed-cpu-sample.txt. No credentials were logged in these diagnostics.


### Status-item presentation fix (2026-11-12)

Dashboard presentation no longer depends on NSStatusBarButton.window, which can be absent for a
replicated status item. Capture a source rect when valid, otherwise anchor from the actual mouse click
and its NSScreen. Keep that context during visible relayout. Start the cached panel with a nonzero frame.
Actual NSStatusBarButton actions defer presentation until the current tracking turn unwinds. UsagePanel
is nonactivating and does not call NSApplication.activate; Settings still activates normally.
Transient windowDidResignKey no longer dismisses a newly opening panel. Outside click/Escape and an
actual foreground-app switch handle dismissal. Ignore old global mouse events preceding monitor install,
and distinguish missing event windows from a real status-item window. Logging category panel records
only toggle/presentation/dismissal state, not quota credentials or conversations.

Native regression uses NSApplication.sendAction with the actual status button target/selector, waits for
focus settling, and checks window visibility plus nonzero hosting-view bounds, close/reopen and cache reuse.
The original outside-click test used window number 0, which can resolve to the current key panel; it now
uses a distinct real AppKit window. CPU appearance-loop regression remains enabled and passes.


Installed presentation-fix verification: user confirmed the real status-item click now opens the panel.
App log for PID 94993 recorded toggle and Panel presented: visible=true. After the brief opening-render
spike, a 6.01s follow-up interval had 0.00 CPU seconds and ps showed 0.0%; no sustained redraw loop.


### Settings Dock visibility and upstream updater (2026-11-12)

Opening Settings promotes the app to regular activation policy (Dock and Cmd-Tab), restores a minimized Settings window and activates it. Closing Settings restores accessory policy; a Dock reopen restores Settings. The window remains fixed-size and reused. The Star on GitHub footer link is removed. The updater itself is unchanged: Sparkle checks the signed upstream burakgon appcast at startup and on its 24-hour schedule, and the Settings action opens Sparkle's interactive update check. Automatic installation is disabled in Info.plist; this is still an upstream feed, not a fork build updater.


### Collapsed provider cards (2026-11-12)

Cards start collapsed and show only the first quota-grid row. The disclosure chevron is immediately to the right of the provider name; the name and chevron toggle together without animation. Expanding restores secondary quota rows, consumption share, billing and reset inventory. A card without additional details has no meaningless disclosure control. Google AI expands as one group; collapsed it shows only its first displayed product's primary quota row, while expanded it shows all available Google products. Cached SwiftUI state preserves user choices during the running app session; expansion does not trigger usage fetches. Natural-height invalidation resizes the existing native panel and its NSScrollView viewport.


### Argon quota discovery correction (2026-11-13)

`retrieveUserQuotaSummary` must use `antigravity/hub/<version>` with an Argon-capable compatibility version (minimum 2.26.0; prefer the installed Antigravity app version). The previous bare `antigravity/2.24.0` identity returned ordinary Gemini and Claude/GPT pools but omitted the independent `Gemini 4 Argon` weekly group. A successful four-pool response therefore does not prove completeness: try the second host when Argon is absent. Never interpret ordinary Gemini quota as Argon availability.

The mapper keeps `gemini-argon-wtu-weekly` separate, preserves its actual reset and retains hundredth-percent precision. The panel gives Argon Weekly its own row, keeping the 3rd-party session/weekly pair together. No extra credential source or generation call is required; the selected shared Google AI session continues to work.

References: https://github.com/Draculabo/AntigravityManager/pull/369 and https://github.com/pingdotgg/t3code/issues/24800 . Verified with quota-only live reads; no credentials or account-specific quota observations are stored here.

### Independent Google products

Gemini and Antigravity are separate providers in the panel, Settings, menubar and dashboard. Their persisted provider IDs and quota history stay unchanged. Tracking, metric selections, order, disclosure state and dashboard filtering are independent.

Gemini retains Gemini native or selected browser authentication. Antigravity reads only the exact native `antigravityUnifiedStateSync.oauthToken` and `antigravityAuthStatus` keys from the IDE profile (legacy app profile only when no IDE profile exists). It refreshes with its own client and keeps access tokens in RAM; it never falls back to Gemini credentials or a CLI identity. A source change intentionally starts a distinct history series.

### Native Gemini tier and Antigravity identity

Gemini's installed SwiftProtobuf `Assistant_Mobile_Robin_UserSubscriptionTier` name map identifies `2` as `TIER1`; the verified display name is Pro. Only this tier is mapped; unknown values stay unlabeled. Native GetUsageInfo currently returns GXU five-hour and weekly pools on the checked account, plus non-quota display/settings metadata. Additional non-GXU pools with nonempty payloads produce compatibility diagnostics rather than invented percentages.

The current Antigravity IDE stores the account email in the exact `userStatusSentinelKey` payload, UserStatus field 7. It can be used even when the legacy `antigravityAuthStatus` JSON is absent. Conflicting native identity caches do not produce an email label. No Gemini identity is used.

Codex model availability booleans are not quota measurements and are intentionally not displayed.
