# AI Usage — personal fork

A native macOS menu bar app for AI subscription quotas, credit balances, reset times, alerts and local token analytics. It reuses logins from supported desktop apps, CLIs and Edge/Chrome profiles; no new account, password or API key is required.

Forked from [burakgon/ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar) at v0.4.0 (`f0c9cfe`). It has since diverged from upstream; development lives on `develop`, and upstream is kept only as a reference. This fork is built locally and is not published as a signed/notarized release.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Using the app](#using-the-app)
- [Supported providers](#supported-providers)
- [Data, privacy and limitations](#data-privacy-and-limitations)
- [Development](#development)
- [Tests](#tests)
- [Debugging and troubleshooting](#debugging-and-troubleshooting)
- [Build, install and update](#build-install-and-update)
- [Documentation and contributions](#documentation-and-contributions)
- [Credits and license](#credits-and-license)

## Requirements

- macOS 26 or later and full Xcode 27 or later, including its macOS SDK. Command Line Tools alone do not provide the complete app build environment.
- Git and network access for the initial checkout, Swift Package Manager resolution and provider requests. Xcode resolves Sparkle, the project's pinned package dependency.
- An existing login for each provider you want to track. Browser adapters currently read only the Edge/Chrome **Default** profile, not arbitrary profiles.

Check the selected toolchain before building:

```bash
xcodebuild -version
xcode-select -p
```

If these select Command Line Tools or an older Xcode, select the intended Xcode under Xcode → Settings → Locations → Command Line Tools. Complete Xcode's first-run setup before returning to the build.

## Quick start

```bash
git clone https://github.com/atkd1890/ai-usage-menubar.git
cd ai-usage-menubar
git checkout develop
./scripts/install.sh
```

The script builds Release, installs `AI Usage.app` to `/Applications` (with `~/Applications` fallback if `/Applications` is not writable), registers it in LaunchServices and opens it. It uses `DerivedData-Install` for build output and disables hardened runtime and base debug entitlements (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`) for this local install. If an older copy is running, quit it from its menu before installing; replacing the app on disk does not restart the existing process.

The app normally lives in the menu bar. Settings opens on first launch. A Dock icon is also present while Settings or Dashboard is open; closing both returns it to menu-bar-only operation. Launch at login may be enabled by default when running an installed copy; review Startup in Settings or macOS Login Items.

## Using the app

1. Sign in to the provider using the source you intend to select: its supported desktop app/CLI, Edge Default or Chrome Default.
2. Open AI Usage → Settings. Turn tracking on for that provider and choose its login method. A browser choice never silently falls back to the desktop/CLI or another account.
3. Allow the normal macOS Keychain/file-access prompt if needed. For a browser storage failure, use the provider's **Allow Edge access…** or **Allow Chrome access…** button when offered, and select the exact Default profile Cookies file.
4. Refresh and check the provider's status. Choose which available metrics appear in the menu bar. Tracking and menu-bar visibility are separate: hiding metrics does not stop collection.
5. Use the panel's **US | CN** switch to change the visible group. Expand a card to inspect secondary quotas, balances, reset grants, billing details and warnings. Drag providers within their Settings region to reorder them.
6. Choose **Left/Used** to change bounded quota presentation. Warning colors always reflect consumed usage: orange at 60%, red at 85%. Unlimited/unavailable placeholders are not selectable menu-bar metrics.
7. Open Dashboard for Tokens/Value, provider/model breakdowns, the 53-week heatmap, observed limit hits and CSV export. In Alerts, enable only the notifications you want and grant macOS notification permission; Focus remains in effect.

When AI Usage is active, ⌘, opens Settings and ⌘Q quits the app.

If a card has an API warning, inspect it before choosing **Update**. Update acknowledges the reviewed schema locally; it does not download new parser code or repair unsupported fields.

## Supported providers

| Provider | What you see | Login sources |
| --- | --- | --- |
| **Claude** | Session, weekly, Fable/scoped limits, consumed-usage breakdown (Code, Chats, Cowork), reset grants, extra usage | Claude Code OAuth, Claude desktop, Edge, Chrome |
| **Codex** | Session, weekly, Spark and other limits, flex credits, banked resets | Codex / ChatGPT desktop OAuth, Edge, Chrome |
| **Cursor / X Subscription** | Total/Auto/API usage, or the shared weekly pool with Cursor/Grok product split, additional usage, prepaid balance | Cursor desktop, Edge, Chrome |
| **Antigravity** | Antigravity app Gemini, Argon and 3rd-party pools; Code Assist excluded | Antigravity desktop |
| **GitHub Copilot** | Monthly and completions quotas, unlimited plans | Copilot editor login, GitHub CLI |
| **Gemini** | Five-hour and weekly Gemini app limits, AI credits, Google Flow and Flow Music credits | Gemini desktop app (optionally + Edge/Chrome for Flow), Edge, Chrome |
| **Muse** | Weekly usage, top-up balance | Edge, Chrome |
| **Adobe** | Monthly generative credits, Firefly credits | Edge, Chrome |
| **Manus** | Daily and monthly credits | Manus desktop, Edge, Chrome |
| **Kimi** | Membership usage, Kimi Code windows | Kimi desktop, Edge, Chrome |
| **Qwen** | Daily/weekly, latest-model frequency limits, video/image credits, reset cards | Qwen desktop, Edge, Chrome |
| **MiniMax** | Token plan, Agent/Design/Hailuo credits | MiniMax desktop, Edge, Chrome |
| **Qoder** | Plan usage | Qoder app/IDE, Edge, Chrome |
| **Dola** | Subscription status, reported usage, OGF counts; paid buckets flagged when unsupported | Dola desktop (default), Edge, Chrome |
| **Z.ai** | Coding Plan windows and model counters; ZCode Start Plan model token allowances, resets and expiry; explicit unavailable states | ZCode desktop (default), Edge, Chrome |
| **Buddy** | Shared WorkBuddy/CodeBuddy credits, separate gift/add-on packages, expiry and monthly reset | CodeBuddy desktop (default), CodeBuddy web in Edge or Chrome |

Antigravity reads only the Antigravity app pool. The retired personal-account Code Assist pool is neither requested nor displayed. Gemini remains a separate provider.

Dola lists Desktop first, followed by Edge and Chrome; existing login-source selections are preserved. Desktop and Edge free-account flows are verified live (default 0% usage and OGF `0/0` render as an unavailable quota rather than active allowances), while Chrome uses the same scoped adapter. Lark Suite credentials are excluded, and nonempty paid entitlement groups produce compatibility warnings until verified.

Z.ai browser sources read the API platform login on `z.ai` (the current destination of `api.z.ai`); `chat.z.ai` login is separate. ZCode desktop additionally supplies the native Start Plan token and existing device context needed to read its free/paid model allowances. Native and Edge logins are live-verified; Chrome uses the same scoped loader with fixture coverage. The adapter does not create API keys, claim benefits, generate content or redeem resets.

Buddy is one shared credit card, not separate WorkBuddy and CodeBuddy totals. CodeBuddy desktop (default) is live-verified with the same personal international account pool as WorkBuddy, while browser loaders read only CodeBuddy session cookies in Edge or Chrome. WorkBuddy's own native auth uses a different protected format and is not an advertised method, and rejected browser sources report authentication failure without falling back to desktop. China-site accounts and enterprise allocations are not currently supported by Buddy.

Features and API availability can vary by account, plan, region and selected login source. [SPECS.md](SPECS.md#3-provider-contracts) documents provider contracts and [known implementation gaps](SPECS.md#7-known-implementation-gaps); the table is not a guarantee that every method works with every account.

## Data, privacy and limitations

- Credentials are read from the selected source only. Provider requests use first-party hosts; there is no analytics/telemetry service operated by this fork. Credential values must never be included in logs, issues or fixtures.
- Provider access is read-only: the app does not generate content, buy credits or redeem resets. Some adapters refresh credentials; independent/source-bound session handling is described in SPECS.md.
- Quota percentages are provider measurements. Unknown data is not zero; unavailable entitlements use gray placeholders. A free/no-plan account can still have valid quotas or credits.
- Dashboard Tokens come from local Codex/Claude usage metadata. Web chats and other devices are excluded, and local logs may span multiple accounts. Message/tool content is not persisted or exported.
- Dashboard **Value** is an API-price equivalent, not actual subscription spending, savings or an invoice. Unpriced models stay in Tokens and are excluded from Value. Plan-cost comparisons use labeled estimates or user overrides.
- History retains up to 13 months. Earlier quota events cannot be reconstructed if they were not observed; imported token metadata survives removal of source logs within retention.

Local state is stored in these locations:

| Location | Contents |
| --- | --- |
| UserDefaults domain `com.burakgon.aiusage` | Preferences, provider/login selections, browser access bookmarks and identity cache |
| `~/Library/Application Support/AI Usage/quota-history.json` | Hourly observed quotas |
| `~/Library/Application Support/AI Usage/quota-limit-hits.json` | Observed exhaustion events |
| `~/Library/Application Support/AI Usage/token-history.json` and `token-file-cache.json` | Imported token metadata and parsing cache |
| `~/Library/Application Support/AI Usage/confirmed-schemas.json` | Acknowledged API schema changes |
| Provider `*-auth.json` files in the same directory | Source-bound rotated sessions for adapters that need persistence; sensitive, never share |

Quit the app before backing up local state. Treat backups as private, especially session files, account identities and preferences. Do not delete state as a first troubleshooting step.

## Development

Read [AGENTS.md](AGENTS.md) for working rules and the relevant [SPECS.md](SPECS.md) sections before changing behavior. Specs describe intended behavior and identify current gaps; tests/builds do not by themselves establish live API compatibility.

```bash
open AIUsage.xcodeproj
```

Select the **AIUsage** scheme and **My Mac** destination. Run with ⌘R, test with ⌘U and use breakpoints/LLDB for the failing path. Debug builds and the installed app share the production bundle identifier and local state, so quit the installed copy before launching a Debug build. Run fixture tests for isolated checks instead of using a live account as a fixture.

| Code area | Entry points |
| --- | --- |
| Startup and service wiring | `AIUsage/AIUsageApp.swift`, `AppServices.swift` |
| Polling, refresh/failure handling | `AIUsage/Store/UsageStore.swift` |
| Preferences and source picker | `AIUsage/Store/AppPreferences.swift`, `AIUsage/Views/SettingsView.swift` |
| Native windows/status item | `AIUsage/MenuBar/MenuBarController.swift` |
| Provider adapters | `AIUsage/Providers/<Provider>/`; Manus/Kimi also use `ConsumerQuotaProvider.swift` |
| Auth/storage/HTTP helpers | `AIUsage/Infrastructure/` |
| Quota models and card presentation | `AIUsage/Models/ProviderModels.swift`, `AIUsage/Views/ProviderSectionView.swift` |
| API drift detection | `ConfirmedSchemaCatalog.swift`, `ResponseSchemaWatch.swift`, `ConfirmedSchemaStore.swift` |
| Analytics, history and alerts | `AIUsage/Store/TokenAnalytics.swift`, `DashboardProjection.swift`, `UsageHistory.swift`, `UsageAlerts.swift` |
| Regression tests | `AIUsageTests/` |

For a new provider, follow the [provider checklist](SPECS.md#adding-or-changing-a-provider): establish the read-only contract, investigate login methods, map all meaningful data, register source/identity/preferences/UI/schema support, then add fake-fixture tests and update the provider contract. Preserve saved identifiers and user choices.

## Tests

Run the full macOS suite:

```bash
xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage \
  -destination 'platform=macOS' -derivedDataPath DerivedData-Test
```

Run only a relevant test class while iterating:

```bash
xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage \
  -destination 'platform=macOS' -derivedDataPath DerivedData-Test \
  -only-testing:AIUsageTests/DolaTests
```

Xcode prints the `.xcresult` path under `DerivedData-Test/Logs/Test/`; open it in Xcode for assertion failures, attachments and logs. The README showcase renderer is intentionally skipped unless its explicit environment is configured. Simulator warnings are separate from the macOS test result: inspect the final result and actual build/assertion error rather than treating every warning as a failed test.

Tests use fake credentials and isolated preferences; the app test host uses `com.burakgon.aiusage.test-host`. New tests must use temporary storage and must not mutate the installed app's preferences, sessions or history. Run the full suite before a Swift-changing commit, and verify the specific live/UI behavior separately when the change depends on it.

## Debugging and troubleshooting

Start by identifying the failing layer: selected credential source → request/HTTP status → mapper/schema → stored snapshot → presentation. Reproduce with a fake response where possible; never dump credential headers or raw account payloads into the console.

| Symptom | What to check |
| --- | --- |
| No visible app window | This is a menu-bar app. Click its status item or reopen the installed app to access Settings; verify macOS is not hiding the menu item. |
| Wrong/old behavior after rebuilding | Quit the running copy and open the intended build by absolute path. Check for copies in both `/Applications` and `~/Applications`; replacing files is not a process restart. |
| Authentication/session expired | Confirm the exact selected source/account is logged in, sign in there if necessary and refresh. Do not substitute another source invisibly. |
| Storage/Keychain denied | Use the normal macOS permission flow or the provider's Allow access button. The accepted browser path is the Default profile Cookies file. Do not copy a denied database or bypass Keychain restrictions. |
| Source logged in but no session found | Confirm it is the Default browser profile and a supported credential format. Check the provider contract; successful UI login does not prove the adapter can read that session. |
| 403, CAPTCHA or account restriction | Inspect the provider's supported account scope. Do not bypass access controls or treat a product entitlement denial as an invalid password. |
| Rate limit or transient network error | Respect Retry-After/reset information. Existing data may remain marked stale; avoid rapid manual retry loops. |
| Gray/unlimited card or no selectable metric | Inspect the entitlement/measurement state. No plan is not zero usage; unlimited or inactive quotas cannot serve as bounded menu-bar percentages. |
| API warning/new bucket | Check the schema diff and mapper. Acknowledge only after review; unsupported data needs code support, not just Update. |
| Dashboard missing history/value | Check local log availability, 13-month retention, five-minute import cooldown and unpriced model coverage. Use Dashboard Refresh to force a scan. |
| High idle CPU or layout jitter | Reproduce open/closed and expand/resize behavior. Inspect Activity Monitor/Xcode Instruments; check UI timers, sizing feedback loops and unnecessary image/aggregate updates. |
| Build cannot find SDK or resolve Sparkle | Check selected full Xcode, first-run setup, network and SwiftPM cache permissions. Resolve the actual error before cleaning caches. |
| Signing/build-install failure | Inspect Xcode Signing & Capabilities and the first build error. The local install script uses `ENABLE_HARDENED_RUNTIME=NO`; signed distribution is a separate workflow. |

Panel lifecycle events use macOS Unified Logging:

```bash
log stream --style compact --predicate 'subsystem == "com.burakgon.aiusage" AND category == "panel"'
```

To save build/test output, redirect `xcodebuild` output to a local file and inspect the final status plus the first compiler/assertion error. If using `tee`, enable your shell's `pipefail` so a logging pipeline does not hide a failed build. Console.app, the Xcode debugger, `.xcresult` attachments and Instruments are complementary; provider request payloads are not intended as public diagnostic logs.

When reporting a bug, include the commit, macOS/Xcode version, provider/login-method name, reproducible steps, expected/actual result and a redacted error or failing test. Exclude cookies, Authorization headers, session files, email addresses and raw private responses.

## Build, install and update

Build Debug without installing:

```bash
xcodebuild build -project AIUsage.xcodeproj -scheme AIUsage \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData-Dev
open './DerivedData-Dev/Build/Products/Debug/AI Usage.app'
```

Build and install Release with the existing script:

```bash
./scripts/install.sh
```

Install without launching:

```bash
AI_USAGE_SKIP_OPEN=1 ./scripts/install.sh
```

Local builds install to `/Applications/AI Usage.app` (fallback `~/Applications` only if `/Applications` is not writable) without duplicate copies in `~/Applications`. Build artifacts stay in `DerivedData-Install/Build/Products/Release/`. After restarting, verify that the running executable is under `/Applications/AI Usage.app`.

To update a local checkout, first inspect `git status` and preserve any uncommitted work, update `develop` with your intended Git workflow, quit the old app and rerun the install script. The bundle retains upstream Sparkle feed configuration with automatic installation disabled; upstream update information is not a distribution channel for this fork. Do not use release packaging/appcast scripts unless intentionally maintaining a separate signed release workflow.

## Documentation and contributions

- [AGENTS.md](AGENTS.md): universal working rules and task-specific reading guidance.
- [SPECS.md](SPECS.md): intended product behavior, common data/login contracts, per-provider details and known implementation gaps.
- This README: setup, usage, development and operational troubleshooting.

Write each prose paragraph or list item on one source line; use blank lines and headings for structure, not manual column-width wrapping. Keep intentional line breaks in code blocks and tables. Update existing sections rather than adding dated journals or duplicate specifications. Commits/pushes are explicit user actions; preserve unrelated work and keep changes reviewable.

## Credits and license

Based on [AI Usage](https://github.com/burakgon/ai-usage-menubar) by Burak Gon. Provider contracts were partly adapted from [OpenUsage](https://github.com/robinebers/openusage), and Claude/Codex icon paths from [CodexBar](https://github.com/steipete/CodexBar). See [NOTICE](NOTICE). Provider names and marks belong to their owners and do not imply endorsement.

MIT License — see [LICENSE](LICENSE).
