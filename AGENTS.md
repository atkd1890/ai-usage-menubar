# AGENTS.md

Read this file on every coding task. Keep universal working rules here; product behavior, provider contracts and implementation gaps belong in [SPECS.md](SPECS.md). Read only the relevant specs before editing.

## Project and scope

- Native macOS 26+ menu bar app, Swift 6 / Xcode 27+, reusing existing logins.
- Independent project, originally forked from `burakgon/ai-usage-menubar` at v0.4.0. Work on `develop` (the only branch). The `upstream` remote is reference-only.
- Preserve existing user changes, staged changes and persisted user data. Never discard, overwrite, commit or push them without explicit instruction.
- Never automatically commit/push. When requested, use one logical change per commit, an imperative summary and a body describing user-visible behavior.
- Stay within the requested scope; document discovered gaps rather than fixing unrelated runtime behavior as part of a documentation change.

## Read the relevant specs

| Change | Required sections in SPECS.md |
| --- | --- |
| Provider/auth/API | [2. Common contract](SPECS.md#2-data-presentation-and-login-contract), [3. Provider](SPECS.md#3-provider-contracts), [6. Compatibility](SPECS.md#6-compatibility) |
| Panel/Settings/menu bar | [1. Product](SPECS.md#1-product-behavior), [2. Presentation](SPECS.md#2-data-presentation-and-login-contract) |
| Tokens/Dashboard/history/storage | [4. Analytics and persistence](SPECS.md#4-analytics-and-persistence) |
| Notifications | [5. Alerts](SPECS.md#5-alerts) |
| Any behavior change | Check [7. Known gaps](SPECS.md#7-known-implementation-gaps) for relevant mismatches |

## Repository map

| Path | Contents |
| --- | --- |
| `AIUsage/AIUsageApp.swift`, `AppServices.swift` | App lifecycle, termination behavior and service wiring |
| `AIUsage/MenuBar/MenuBarController.swift` | `NSStatusItem` (`autosaveName`), non-activating `UsagePanel`, Settings/Dashboard windows, `AppSurfaceLayout` |
| `AIUsage/Models/ProviderModels.swift` | `ProviderID` (`enabledCases`, `region`, `installationIndicators`, `defaultMenuBarMetric`), `QuotaKind`, `QuotaWindow`, `ProviderSnapshot`, `ProviderFailure` |
| `AIUsage/Providers/<Name>/` | Per-provider adapters (`Adobe`, `Antigravity`, `Buddy`, `Claude`, `Codex`, `Copilot`, `Cursor`, `Dola`, `Gemini`, `MiniMax`, `Muse`, `Qoder`, `Qwen`, `ZAI`) |
| `AIUsage/Providers/WebUsageProvider.swift`, `ConsumerQuotaProvider.swift` | Browser/desktop cookie adapters (`Claude`, `Codex`, `Cursor`, `Manus`, `Kimi`) and `CredentialSelectingProvider` |
| `AIUsage/Providers/ConfirmedSchemaCatalog.swift`, `ResponseSchemaWatch.swift`, `ConfirmedSchemaStore.swift`, `QuotaDiscovery.swift` | API drift baselines, deprecation checks and unknown-bucket discovery |
| `AIUsage/Infrastructure/` | `SecurityKeychainAccessor`, `WebSessionStore`, `ReadOnlySessionSQLiteReader`, `ScopedLocalStorageReader`, `ChromiumSafeStorageCodec`, `BrowserDatabaseAccess`, `GeminiReadOnlyHTTPClient`, `AccountIdentity` |
| `AIUsage/Store/` | `UsageStore`, `AppPreferences`, `UsageHistory`, `TokenAnalytics`, `DashboardProjection`, `DashboardPlanPrice`, `UsageAlerts` |
| `AIUsage/Views/` | `ProviderSectionView`, `SettingsView`, `DashboardView`, `UsageDashboardView`, `MenuBarLabelView`, `ProviderIcon`, `UsagePalette` |
| `AIUsageTests/` | Isolated XCTest suite using fake fixtures and `com.burakgon.aiusage.test-host` |
| `scripts/install.sh` | Local Release build, `/Applications` install and launch |

## Privacy and credential safety

- Read credentials only from the explicitly selected source/account. No silent cross-source fallback; combined modes must be explicit and documented.
- Never log or expose tokens, cookies, emails or raw private payloads in errors, diagnostics, fixtures, reports or commits. Use fake test credentials.
- Use first-party HTTPS hosts only, explicit allowlists, no redirects, shared cookie jar or cache (`GeminiReadOnlyHTTPClient(allowedHosts:)`). Cookie import must use exact allowlisted domains/names, never read all cookies.
- Read macOS Keychain items only through `SecurityKeychainAccessor` (`/usr/bin/security`); never call `SecItemCopyMatching` directly from the app binary, because local/ad-hoc builds lack stable code-signing ACL persistence and re-prompt for the user's password on every launch/rebuild.
- Source app SQLite/LevelDB/auth storage is read-only. Only established Claude/Codex token-rotation writeback may update its originating auth source. Other provider rotations belong in this app's source-bound session store.
- Report macOS permission denial as storage failure. Use the normal user-granted permission/security-scoped bookmark path; never copy blocked databases, use immutable mode/helpers or bypass Keychain, signing, CAPTCHA or anti-bot gates.
- Never call generation/chat, purchase or reset-redemption endpoints. Auth refresh must preserve the source app/browser login, serialize rotating refresh-token calls single-flight inside an unstructured cancellation-safe task that persists rotations before returning, clear persisted sessions only on explicit authentication rejection (never on transient or rate-limit responses), proactively refresh or renew tokens before expiry, and use bounded retries.
- Parse/store/export only usage metadata from logs, never conversation content.

## Data and compatibility

- Use the shared card hierarchy: plan badge, compact quota summary, expandable secondary data. “Maximum meaningful data” is not a raw field dump; omit inapplicable/default metadata and redundant states. Verify the rendered collapsed and expanded card, not just mapper assertions.
- Show all meaningful valid response values, including free/no-plan data and numeric zero. Missing/null/unsupported is not zero; never invent percentages, capacity, plan names, prices, currencies, unlimited state or reset semantics.
- Keep pool, product, cadence, account and unit boundaries explicit; do not sum overlapping allowances or confuse consumed shares with remaining quota.
- Separate allowance tiers strictly: recurring plan quotas with real capacity or verified per-plan monthly allotments use `QuotaWindow`; fixed-total add-on/gift packs and monetary spend caps use `BoundedCreditProgress` or `BillingUsage.boundedSpend` (never `QuotaWindow`, so they do not pollute history, limit hits, alerts or the Menu Bar picker); unbounded top-up wallets and bonus balances stay plain numeric text with no percentage or bar.
- Keep stable IDs, raw values and persisted keys. Use deliberate versioned migrations; preserve user opt-outs, metric selections, order and login source.
- Scope credentials, caches, history and alerts to their owning source/account. Source changes must not inherit another login's snapshot or Connected badge.
- Update the relevant SPECS.md contract with intentional behavior changes; do not treat a documented legacy gap as the desired behavior. Keep schema baselines/tests aligned with supported parser changes.
- Investigate all relevant login methods; expose implemented methods supported by established contracts and distinguish live from fixture-only validation.

## Performance and verification

- Poll only through `UsageStore` at the user interval. Opening/expanding views must not add provider fetches; hidden UI must not tick countdowns or relayout.
- Keep idle CPU near zero. Avoid SwiftUI `ViewThatFits` or sizing feedback loops, repeated identity lookups, unchanged status-image assignments or `button.image = nil` flicker before image updates, and synchronous heavy UI work. Cache log imports/aggregates and reject obsolete async results.
- Keep a stable `NSStatusItem.autosaveName` (`MenuBarController.statusItemAutosaveName`) and never call `NSStatusBar.removeStatusItem` during app termination (`stop(removeStatusItem: false)`), so Hidden Bar and macOS menu bar managers preserve the icon's placement across quits and reinstalls.
- Add/run tests appropriate to changed behavior; use fake fixtures, isolated temporary storage and test UserDefaults, never the real app suite/data.
- Run the full suite before any Swift-changing commit. UI/performance fixes also need relevant lifecycle/idle verification; a build alone is insufficient.
- Report what changed, validation performed and remaining gaps. Clearly separate static inspection, fixture tests, build success and live API/UI verification.

## Build and install

```bash
xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage \
  -destination 'platform=macOS' -derivedDataPath DerivedData-Test

# Build Release, install to /Applications and launch when requested.
./scripts/install.sh
```

- Install and launch local builds only from `/Applications/AI Usage.app` (fallback `~/Applications` only when `/Applications` is not writable), and do not leave duplicate copies in `~/Applications/AI Usage.app`. Register the installed bundle with `lsregister -f` and unregister temporary build outputs (`DerivedData-*`) so menu bar managers (e.g. Hidden Bar) recognize it as the active system app. Verify the running executable path after restart.
- Never commit `DerivedData-*`, `dist/`, credentials or local usage databases.
- Preserve upstream release/OTA configuration (`appcast.xml`, Sparkle keys and packaging scripts); do not publish fork releases unless explicitly requested.
- When porting or cherry-picking from a newer upstream release, bump `UpdateController.syncedUpstreamVersion` (in `AIUsage/Services/UpdateController.swift`) along with `UpdateConfigurationTests` and `SPECS.md` so the passive `Upstream <version>` footer notice hides until a strictly higher upstream release ships.

## Documentation

- `README.md`: user introduction, supported features and build/use instructions.
- `AGENTS.md`: universal working rules and routing to relevant specs.
- `SPECS.md`: product behavior, provider contracts and known implementation gaps.
- Maintain these in place; do not add journals, dated update sections, probe logs or duplicate specs under `docs/`. Keep implementation trivia in code.
- Keep each prose paragraph/list item on one source line; do not manually wrap at a column width. Preserve intentional breaks in code blocks and tables.
- Preserve `LICENSE`, `NOTICE` and all required copyright/attribution blocks.
