# New consumer-provider live probes — 2026-11-12

These are read-only probe results, not registered providers in the installed app. No credential values are recorded.

## Muse personal agent

- Native Meta app-group Keychain query returns `errSecMissingEntitlement` (-34018). Do not bypass Meta's signing/access-group boundary.
- Edge Default acquired `hatch_sess` and `hatch_gw` after the user signed in. Only these two cookies were read/decrypted; Stripe/device cookies were excluded.
- Anonymous public scripts did not include the settings action. The signed-in document was streamed through an HTML parser that only collected same-origin static script URLs; inline bootstrap content was ignored, never logged or saved. Subsequent asset requests carried no cookies.
- The settings module exposed `fetchSubscriptionAction`. The read-only subscription action returned HTTP 200 and a successfully parsed subscription.
- Plan: Muse Free. Weekly usage: 0%. Reset: 2026-11-19 21:40 JST. No top-up and no paid renewal date in this response.
- Action IDs are deployment-specific. An implementation needs cached IDs, bounded settings-module rediscovery, strict same-host redirects-off transport and schema validation. Never use arbitrary actions or conversation APIs.
- This account is the selected Edge session. It has not been matched to Muse desktop's account.

## Microsoft Copilot (consumer, not GitHub Copilot)

- The active account was resolved from MSAL's active-account filter in Edge Default's `https://copilot.microsoft.com` local-storage namespace. Other origins were not decoded.
- Two access tokens existed: Copilot ChatAI and Microsoft Graph. Both had expired; the Graph credential was never sent to Copilot.
- Only the matching account/client refresh token was used, requesting `140e65af-45d1-4427-bf08-3e7295db6836/ChatAI.ReadWrite`.
- A missing Origin caused AADSTS90023. Supplying the original SPA Origin yielded refresh HTTP 200. No token/cache was persisted or overwritten.
- `GET https://copilot.microsoft.com/c/api/user?api-version=3` returned HTTP 200, `accountTier: m365-personal`, and a direct subscription with automatic renewal.
- `remainingUsage`: reasoningCalls 9999; podcastGenerations 6; researchCalls 15; taskCreations 1000; taskBudgetFreePercentage 100; taskBudgetPercentage 100; visionCallSeconds 21600; videoGenerations 3.
- Task budget has an actual percentage. Other fields are remaining counters; no capacity/reset was returned for those counters. Do not manufacture percentages, interpret 9999 as an exact meaningful allowance, sum free/paid task budgets, or classify the account as Free from the legacy `isPro: false` flag.
- An app integration still needs an efficient, scoped, read-only MSAL store reader and in-memory token refresh/cache. The temporary forensic reader is not bundled or registered as an app dependency.

## Meta AI

- Native app-group Keychain access also returned -34018.
- Edge Default had `ecto_1_sess`; Chrome Default had no matching login cookie.
- The cookie was read/decrypted only in memory. Usage-schema GraphQL probes to the approved `meta.ai` and `www.meta.ai` hosts returned HTTP 403. No usable quota response was obtained.
- This does not establish that the account has expired or that Meta AI has no quota. The private usage query/transport contract remains unverified. Do not substitute Muse Code/API billing or invent 0%/100% usage.

## Product status

No new provider card has been added based solely on these probes. Muse and Microsoft Copilot have usable live data to implement against; Meta AI does not yet have a verified usage contract. The existing installed build remains the tested collapse/expand build.

## Additional probes — 2026-11-13

### Manus

- Explicitly approved source: Edge Default `session_id` for `manus.im`; Bearer only to `https://api.manus.im/user.v1.UserService/GetAvailableCredits`.
- Read/decrypted only that cookie in memory. Read-only POST returned HTTP 401 on repeat; no usable credits response was obtained.
- No redirects, refresh, native-token fallback or writes to the browser cache were performed. Re-authentication in the selected browser is needed before retrying this source.

### Kimi

- Explicitly approved source: native `~/Library/Application Support/kimi-desktop`, `https://www.kimi.ai` origin; access token only to the three approved membership/usage APIs.
- No live `access_token`/`accessToken` was found in that origin's Local Storage. Cookie metadata contained preferences and anti-bot cookies, not a login session.
- IndexedDB database/store metadata was inspected only. Draft/message stores and the unidentified store were not decoded. No quota request was sent without a matching credential.
- This establishes only that the scoped reader did not find a supported credential; it does not establish that the native app is logged out.
- Official membership documentation distinguishes legacy weekly limits from new plans with a rolling five-hour window. Do not hard-code weekly limits for every account: https://www.kimi.ai/help/kimi-code/benefits

### Qwen and DeepSeek

- Qwen desktop is installed. Consumer chat/subscription usage has not yet been validated live. The official Qwen Code subscription design documents shared Core credentials across coding clients; this alone does not prove that consumer chat and coding quota are identical: https://github.com/QwenLM/qwen-code/blob/main/docs/design/qwen-subscription.md
- DeepSeek consumer chat quota has not been verified. API/platform monetary balance must not be substituted for consumer chat usage.
- No new credential egress was performed for either provider.

No new provider was registered from the failed Manus/Kimi probes. Muse remains a successful probe pending a production adapter with deployment-aware action discovery.

## Successful re-authentication and integration — 2026-11-13

After the user signed in again in Edge and Kimi desktop:

- Manus returned HTTP 200: daily remaining 300 of 300; separate free credits 1,000; total credits 1,300. The adapter displays the bounded daily percentage only. Free credits are not added to the daily denominator, converted to money or used to infer a plan.
- Kimi returned HTTP 200 from all three approved endpoints. Membership is Free; `FEATURE_OMNI` membership `amountUsedRatio` is 0. The subscription balance expires on 2026-12-13; the Code-scoped `GetUsages` separately returned 100 of 100. The adapter displays membership Total Usage, not an assumed weekly or Code quota.
- Production methods: Manus = Browser (Edge Default) only; Kimi = Desktop app only. There is no cross-source fallback. The active providers are seeded once in existing preferences; later user disable choices remain respected.
- The native Kimi reader implements bounded read-only LevelDB log/table/Snappy decoding, manifest live-file selection, checksums, sequence/tombstone handling and exact origin/key filtering. Only the approved `access_token`/`accessToken` values are decoded. It does not use Python, external forensic readers, DB locks or disk credential copies.
- Manus sends Bearer only to `api.manus.im/user.v1.UserService/GetAvailableCredits`. Kimi sends the selected native credential only to the verified membership `GetSubscription`/`GetSubscriptionStats` endpoints at `www.kimi.ai`. Both use ephemeral HTTP without cookie persistence or redirects. No identity endpoint or token refresh was added.
- Expired sessions require signing in again in the chosen source. Other origins, chat records and browser accounts are not used as fallback.

### Native application validation caveat

The Xcode test host's direct read-only SQLite open of Edge Cookies returned `SQLITE_AUTH` (23), while the separately authorized shell probe succeeded. That is a process-specific access denial, not an expired session. The importer reports a macOS Privacy & Security access error for this status; it does not copy the database, use immutable mode, or launch another process to bypass the denial. Installed-app validation is separate from the live HTTP probe and deterministic unit tests.

### Installed application check

- Native Settings inspection confirmed both new rows and their exact method selections. Manus reported a macOS cookie DB access denial; Kimi reported quota HTTP 401. A current shell probe still returned Manus HTTP 200 but Kimi HTTP 401, confirming the latter session had expired since the earlier successful probe.
- Added user-operated `Allow Edge access…` for Manus storage failures. It opens NSOpenPanel, accepts only Edge Default's Cookies file, and stores an OS read-only security-scoped bookmark, not cookies. No programmatic OS grant or alternate-process bypass is used. Successful access through this dialog still requires user verification.
- Kimi refresh-token access and the additional refresh endpoint require separate consent; no refresh request has been made under the original usage-only approval.
- Adding rows exposed a Settings layout feedback loop: the installed app sampled at ~92% CPU on the main thread in NSHostingView/ScrollView fitting. Replacing ViewThatFits with one ScrollView, disabling automatic hosting-view size extrema and removing unbounded scroll fitting brought the restarted app to 0% sampled idle CPU (~94 MB RSS). Regression suite passed 300 tests, one skip after that fix.

### Approved Kimi refresh validation

The user explicitly approved the additional native refresh-token source and refresh destination. Static inspection of the installed app's public token module confirmed GET `/auth/token/refresh` with `/api` base URL. The live request to `https://www.kimi.ai/api/auth/token/refresh` returned HTTP 200 with access/refresh tokens; subsequent membership and subscription-stats requests both returned HTTP 200. No token values were printed/persisted and no native files were modified. The production adapter retries membership once after an approved refresh, coalesces refresh requests, and retains rotated credentials only in memory bound to the source token fingerprint.

Final installed Release UI verification: Kimi now reports Connected with the Desktop app method and exposes Total Usage. Manus still reports macOS database access denial and exposes the new Allow Edge access button; the OS file selection has not been performed by the user yet. Final automated suite: 302 passed, one skipped. Installed app signature verified.

## Recheck and Muse integration — 2026-11-13

- Meta AI: scoped Edge `ecto_1_sess` read-only GraphQL probe still returns HTTP 403 on both `meta.ai` and `www.meta.ai`; Chrome Default has no matching cookie. Public Meta AI fetch is also forbidden. This is not proof of an expired account or of no quota. No Meta AI provider is registered.
- Muse: scoped Edge `hatch_sess`/`hatch_gw` subscription action returns HTTP 200, Muse Free, weekly utilization 0%, reset timestamp 1795183771, no top-up. Registered as its own provider using Edge Default only, with the official SVG linked from muse.ai.
- Muse stores only the public action ID; tokens/cookies stay in memory. A stale action triggers bounded named-action rediscovery: streamed homepage script-src attributes only, inline bootstrap discarded, static settings chunks fetched without cookies, only `fetchSubscriptionAction` accepted. No conversation/generation/action-execution endpoints are used.
- History and alerts are scoped to a one-way hash of the selected Muse session cookie; gateway-cookie rotation does not change the series. Native Meta Keychain access-group restrictions are not bypassed.
- DeepSeek Chat: public discovery returns HTTP 403. Qwen Chat: public HTTP 200 is an Aliyun CAPTCHA page, not an application bootstrap. No CAPTCHA bypass, authenticated consumer quota request, API-balance substitution, or Cloud/Code-quota substitution was performed. Their consumer usage adapters remain unverified.
