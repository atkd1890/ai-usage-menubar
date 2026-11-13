# Credential sources and source policy

Audited against this local develop implementation on 2026-11-12. This table
states code behavior, not that every provider is installed or authenticated.
Live verification completed for Cursor, Copilot, Gemini native, and Antigravity
in the local task. No credentials are reproduced here.

| Provider | Current credential source order | Preferred source for this setup |
| --- | --- | --- |
| Claude Code | Current-user then legacy Claude Code Keychain item; file `<CLAUDE_CONFIG_DIR or ~/.claude>/.credentials.json` | Claude Code's own OAuth store; not Claude Desktop/browser cookies |
| Codex | `<CODEX_HOME>/auth.json` if overridden; otherwise `~/.config/codex/auth.json`, `~/.codex/auth.json`; Keychain `Codex Auth` fallback | The active Codex auth store for the selected account/workspace; do not substitute ChatGPT browser cookies |
| Cursor | Native `Cursor/User/globalStorage/state.vscdb`; token-specific Keychain fallback; a narrow legacy free-account mismatch rule can prefer Keychain | Cursor native encrypted SQLite auth |
| Antigravity | Keychain service `gemini`, account `antigravity`; derived access-token cache; running app or agy provides quota fallback | Official Antigravity session; runtime bridge as quota fallback |
| Copilot | Editor `apps.json` and `hosts.json` candidates; on auth rejection, GitHub CLI file then `gh:github.com` Keychain; duplicates skipped | GitHub CLI is the verified working fallback on this machine. Preferring it first remains a recommendation, not the implemented order |
| Devin | `~/.local/share/devin/credentials.toml`, then native Devin SQLite `windsurfAuthStatus` | Official credential store of the product/account actually used; native-over-CLI preference is not yet verified |
| Grok Build (CLI) | Entries in `~/.grok/auth.json` | Grok CLI's selected account; no browser/native consumer-app reader exists here |
| Kiro | `kiro-auth-token.json`, then `kiro-auth-token-cli.json` under AWS SSO cache, then `KIRO_API_KEY` | Native Kiro cache, with CLI as an explicitly understood alternate identity |
| Z.ai | `ZAI_API_KEY`, Claude Code settings pointed at Z.ai, OpenCode auth | One intentionally selected Coding Plan key; no native-app auth adapter exists |
| Gemini | Explicit source: native app (default), Edge Default, or Chrome Default; separate consent; no cross-source fallback | Native Gemini active account, verified with the quota RPC; browser sources remain explicit alternatives |

Devin, Kiro, and Z.ai are temporarily disabled in this build: their runtime
registrations are commented out and they are excluded from enabledCases,
installation checks, Settings, dashboard, and menu-bar readings. Their enum
identities, implementations, and saved preferences are retained for re-enabling.

## What sharing an account means

A browser OAuth flow can hand an authorization result back to a CLI or desktop
app. The client then keeps its own OAuth credential, with its own client ID,
scopes, refresh rules, and storage. Same account, shared subscription entitlement,
shared quota, and identical credential are four separate questions. A working
web login alone does not prove that the corresponding CLI token remains valid.

The tracker reads **credentials locally**, then obtains **usage from the
provider's remote API**. Antigravity additionally supports the official local
app/CLI quota bridge. Local credentials do not mean that usage is a local estimate.

## Recommended policy

Choose the official credential store of the exact product whose quota is being
measured. Prefer native where a verified native adapter exists, rather than
forcing unrelated products through desktop-app sessions. Do not copy refresh
tokens between app, CLI, and browser stores.

Pin or display the account/workspace and source. A fallback should only be
considered equivalent after its account identity and product scope are verified.
Most legacy providers currently auto-discover candidates; generic per-provider
source/account selection is not yet implemented. Gemini now has explicit source
selection and displays the native active account. Do not claim that every legacy
provider has been migrated to a single native-first channel.

Native app formats can also be private and change. In particular, Gemini's
local AES-GCM envelope, protobuf schema, and installed OAuth client config are
version-sensitive. Fail clearly on a format change; never display invented
0%/100% quota or silently read a different account.


## Current Google AI connection override (2026-11-12)

Gemini and Antigravity now BOTH use active Gemini native login (Gemini Safe Storage), via one
GoogleAISession access token with assistant + cloud-platform. No separate Antigravity credential or
fallback is used by the installed default path. Two quota APIs and independent failure states remain.
Settings exposes one Google AI group and native-login permission; browser adapters are retained in
source but not selectable for this shared production connection. Live one-refresh/two-service test passed.


### Settings login methods (2026-11-12)

Settings exposes a Login method column. Only methods implemented by each adapter appear in its dropdown. X uses Cursor desktop; Claude and Codex use their existing coding OAuth stores. Copilot defaults to editor credentials with GitHub CLI fallback and can be restricted to GitHub CLI only. Google AI uses Gemini desktop for both quota adapters. Connection status is not a login method. Browser cookie adapters are not selectable for the unified Google AI group because they do not supply both quota services. Changing a supported method clears the old source snapshot/status, cancels the previous refresh and starts a new one. Connection status is shown beneath the provider name; Google AI requires successful snapshots from both services.


## Explicit login methods and email identity (2026-11-12, current override)

The selector now routes real adapters rather than just labelling a fixed source:

| Provider | Selectable sources | Live probe result on this machine |
| --- | --- | --- |
| Claude | Claude Code OAuth; Claude desktop session; Edge Default; Chrome Default | Desktop/Edge/Chrome organization + usage API returned 200, including Fable, breakdown and three reset grants. OAuth/web identity APIs returned email. A synthetic Mozilla User-Agent triggered 403; the normal client request succeeded. |
| Codex | Local Codex OAuth; Edge Default; Chrome Default | Both browser sessions returned 200 for auth/session and wham usage, with different account/workspace IDs from the local OAuth account. Browser cookies may be chunked. Email is already in usage. Codex desktop's cookie store contained no ChatGPT login; do not invent a separate desktop cookie method. |
| X Subscription | Cursor desktop; Edge Default; Chrome Default | Edge weekly pool/breakdown and prepaid balance returned 200; Chrome currently has no Cursor session. Cursor auth/me returns email. |
| Google AI | Gemini desktop; Browser (Edge) — Gemini; Browser (Chrome) — Gemini | Both browsers returned Gemini usage. Browser selection suppresses Antigravity fetches, cards, and available metrics; desktop restores both services. Gemini CLI refresh succeeded, but both Cloud Code quota endpoints and Gemini usage returned 403, so CLI is not exposed as an equivalent method. |
| GitHub Copilot | Editor + CLI fallback; Editor login; Terminal CLI | Editor credential returned 401; CLI returned 200 for quota. Identity email lookup was unavailable (emails 404; user request timed out), so no email is guessed. |

Web import reads only the approved session-cookie names and selected source, uses a read-only SQLite handle without database copies, and never falls back to another account's local OAuth. Requests use ephemeral, redirect-blocked sessions restricted to the service hosts. Selecting a source clears old quota/status and cancels the previous refresh generation. macOS data-access denial is reported as a storage permission failure.

Email is a separate optional identity field. It appears directly left of the plan badge, with middle truncation and a full-email tooltip. Google AI shows one shared email only when its displayed children agree. Organization names and primary browser-profile emails are not treated as authenticated account email.

Additional identity APIs are attempted once for a login-method selection, including initial connection. The result or failed attempt persists across app relaunches; regular usage refresh never retries it. Only email, selection identifier and a non-reversible credential fingerprint are saved, never raw cookies/tokens. Changing method creates a new selection identifier. If credential binding changes without an explicit method selection, the old email is hidden and no background identity call is made. Native refresh-token binding avoids unnecessary loss on access-token rotation where possible. Codex usage email and Gemini native email require no additional identity request.


Login-method labels are normalized to Local OAuth for Claude/Codex. Copilot exposes Auto (Copilot config then GitHub CLI on credential rejection), Local OAuth (Copilot config only), and GitHub CLI OAuth (gh credential only). GitHub CLI is not the Copilot CLI. These are two credential sources plus an automatic-selection policy, not three independent logins. No separate Codex desktop-cookie method is exposed because its inspected cookie store had no ChatGPT login.


### ChatGPT desktop / local OAuth verification (2026-11-12)

The installed `/Applications/ChatGPT.app` identifies as `com.openai.codex`; its packaged application is `openai-codex-electron` and its Owl runtime selects the Codex data directory. Inspection of the packaged client shows it asks its bundled Codex app-server for `getAuthStatus` / `getAuthToken`, rather than exposing a second browser-cookie login. The bundled `codex login status` reports ChatGPT login. A read-only request with the local OAuth credential to wham/usage returned HTTP 200, email, both quota windows, and an account ID matching the credential. Therefore the current Local OAuth option already reads this installed ChatGPT/Codex login; a duplicate Desktop app source is not added. This does not establish the storage layout of other/older ChatGPT native builds.

### Manus and Kimi (live-verified 2026-11-13)

| Provider | Selectable method | Credential source | Read-only usage destination |
| --- | --- | --- | --- |
| Manus | Browser (Edge) | Edge Default `manus.im` cookie `session_id`, Edge Safe Storage | `api.manus.im/user.v1.UserService/GetAvailableCredits` |
| Kimi | Desktop app | `kimi-desktop/Local Storage/leveldb`, exact `https://www.kimi.ai` access-token keys | `www.kimi.ai/apiv2/` membership `GetSubscription` and `GetSubscriptionStats` |

No browser/native fallback or refresh-token exchange is implemented for these sources. Kimi Code quota was probed separately; the displayed card uses the membership pool. Raw credits are not displayed as money. macOS database access denial must be resolved through system permission, not bypassed.

Kimi refresh was separately approved and verified later on 2026-11-13: exact native-origin `refresh_token`/`refreshToken` is sent only as Bearer to `GET https://www.kimi.ai/api/auth/token/refresh`. Returned access tokens are used only at the two membership APIs above. Rotated tokens remain in RAM; native storage is untouched. The permission flag `kimiNativeRefreshAllowed.v1` must be enabled before reading/using refresh credentials. A native credential change invalidates the in-memory session binding; rejected refresh requires native sign-in again.
