# Provider compatibility and quota coverage audit

Checked 2026-11-13. Scope: the eight enabled provider IDs (Google AI combines Gemini and Antigravity in one card). Live checks used existing approved sources/endpoints; diagnostics emitted schema paths, quota kinds and safe feature enums only. No credentials, identities or account-specific balances are recorded here.

## Header and protocol coverage

| Provider | Current contract | Findings |
| --- | --- | --- |
| Antigravity | Hub User-Agent on quota summary; Connect v1 on loopback | Confirmed partial-200 problem with bare legacy UA: Argon omitted. Fixed hub identity resolves version from the installed hub, with a tested minimum compatibility version. Query the second host when only shared pools are present. |
| Claude | `claude-cli/2.1.318`, `anthropic-beta: oauth-2025-04-20` | Quota parses live. Reset grants explicitly gate CLI versions; hardcoded client version remains a maintenance risk. A newer installed CLI version alone does not prove incompatibility. |
| Codex | AIUsage UA; account ID; `OpenAI-Beta: codex-1` and `originator: Codex Desktop` on reset credits | Main quota parses live. Protocol/originator values are not app build numbers and must not be blindly replaced with installed versions. |
| GitHub Copilot | VS Code 1.96.2; plugin/UA 0.26.7; API version 2025-04-01 | Quota parses live, but editor/plugin build constants are old. The internal quota route's behavior is not fully documented by the public REST contract. Do not auto-bump API dates. |
| X / Cursor | Connect v1 for RPC; selected session cookie and Cursor Origin for dashboard | Quota parses live. No hardcoded editor build header. Endpoint/schema changes remain possible independently of headers. |
| Gemini native | Protobuf plus `X-Goog-Api-Format-Version: 2` | Two quota pools parse live. OAuth client configuration is already discovered from the installed native app. Format version is a protocol, not the Gemini app version. |
| Gemini browser | Persisted GraphQL query signature | Higher maintenance risk even without a build header: a signature/schema can change with web deployments. Browser source was not revalidated in this native-source audit. |
| Manus | Generic UA; scoped Edge cookie converted to Bearer | Quota HTTP probe succeeded previously; installed-app cookie access is OS-gated. That access denial must not be classified as a header compatibility failure. |
| Kimi | Generic UA; scoped native Bearer; GET refresh endpoint | Membership quota parses live after approved refresh. No pinned app build header; private RPC methods/schema remain version-sensitive. |

Devin, Kiro, Z.ai and Grok Build remain disabled. Their code was inspected statically, not live-tested; they must be revalidated before being re-enabled.

## Independent limits and missing coverage

| Provider | Current live coverage | Conditional or missing coverage |
| --- | --- | --- |
| Claude | Five-hour, weekly, Fable; spending/balance and reset grants | Sonnet/Opus and surface-specific weekly fields can be absent/null. Fable is a cap within regular weekly usage, not an additive allowance. Unknown active `limits[]` scopes should eventually trigger partial-data diagnostics. |
| Codex | Main session/weekly, credits and reset grants | `additional_rate_limits` and `code_review_rate_limit` exist but are null on the checked account. Current mapper only recognizes Spark among additional limits. `model_usage` reports per-model availability without a percentage and must not become a fabricated progress bar. |
| X / Cursor | Shared weekly pool plus per-product consumption breakdown and monthly paid usage | Per-product consumption is a share of the same pool, not a separate allowance. Legacy Cursor plan/auto/spend fields apply only when not unified. |
| Gemini native | Pool types 1 and 2 (session/weekly) | No additional pool types observed. This does not establish quota coverage for every Gemini feature such as video or research. |
| Antigravity | Shared Gemini 5h/weekly, Argon weekly, shared 3rd-party 5h/weekly | Carbon has separate bucket handling in current T3 Code source but is not returned for the checked Pro account. Hydrogen is not returned in this account's catalog; no dedicated Hydrogen quota can be claimed from equal percentages or its model name. Current mapper needs a generic bucket path before it can cover future model families automatically. |
| GitHub Copilot | Chat and completions; premium bucket parser already present | Premium is not a bounded active quota on the checked account. Billing SKUs, model multipliers and credit usage are not automatically independent model caps. |
| Manus | Daily bounded allowance | Monthly/periodic allowance may exist on other plans. Free/add-on credit balances without a capacity are not percentages or currency balances. |
| Kimi | Monthly membership `FEATURE_OMNI` ratio | Paid Code can have a 5-hour window, legacy weekly window, and shared Extra Usage wallet. The current adapter does not expose all those windows. Concurrency/project/task constraints are feature limits, not consumption percentages. |

## Recommended compatibility mechanism (not implemented by this audit)

- Read installed public client metadata once at startup and after the relevant app/CLI changes. Cache by path/version/mtime. Never execute an arbitrary binary found while scanning.
- Auto-sync only known client build fields. Keep beta flags, API dates, Origin, protobuf/Connect versions and OAuth client bindings pinned until their contract is validated.
- Reuse normal usage requests for capability validation: HTTP 200 is insufficient. Check quota IDs, active scopes, explicit ineligible reasons and unknown bucket families. Do not poll extra endpoints every time a view opens.
- Distinguish connection from completeness in Settings: Connected; Connected / partial data; Compatibility issue. A version mismatch is diagnostic information, not sufficient grounds for a warning.
- Warn when a previously observed account/source-bound bucket disappears, a new unsupported active bucket arrives, or the server explicitly rejects a client version. Do not flag legitimate plan differences, null/unlimited buckets, auth expiry or OS access denial as header errors.
- Keep the last known working profile and support a bounded validated fallback. Never download and execute arbitrary header recipes or guess new auth/Origin/endpoint values.
- For unknown future headers or field semantics, an adapter update is still required. There is no universal vendor endpoint that publishes the complete current private quota contract.

References:
- https://github.com/Draculabo/AntigravityManager/pull/369
- https://github.com/pingdotgg/t3code/blob/main/apps/server/src/provider/antigravityUsageLimits.ts
- https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan
- https://docs.github.com/en/rest/about-the-rest-api/api-versions
- https://www.kimi.ai/help/kimi-code/benefits

## Implemented coverage after audit

- Extensible quota IDs preserve existing string encodings and carry new labels through panel, menubar, history and dashboard Limits.
- Antigravity uses installed hub metadata and merges both summary hosts; enabled unknown model buckets with explicit fractions are retained.
- Claude non-null weekly fields and named scoped limits, Codex additional/review limits, Copilot unknown bounded snapshots, and Gemini unknown measured pools now have generic paths.
- Kimi membership balances plus scoped Code usage windows are retained separately; Manus monthly capacity/remaining is separate from daily allowance. No capacity means no invented percentage.
- Null blocks stay hidden. Recognized containers with unsupported non-null measurements generate partial-data diagnostics where supported, shown in Settings and dashboard. This does not guarantee detection of arbitrary future fields or silently omitted server data.
- Tokens/Value and Models continue to use local token logs; quota windows are never converted into token usage or API cost.
- Generic paths are covered with synthetic fixtures; this does not imply every paid-plan variant has been live-validated.
