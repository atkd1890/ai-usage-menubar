import XCTest
@testable import AIUsage

final class AntigravityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let prod = "https://cloudcode-pa.googleapis.com"
    private let daily = "https://daily-cloudcode-pa.googleapis.com"

    // MARK: - Mapper

    func testSummaryMergesPoolsAcrossHostsWithTheFirstAnswerWinning() throws {
        let production = summary("""
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-5h","window":"5h","remainingFraction":0.9},
          {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.8}
        ]}
        """)
        let dailyHost = summary("""
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,
           "resetTime":"2027-01-15T12:00:00Z"},
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.25}
        ]},
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-5h","window":"5h","remainingFraction":0.1}
        ]}
        """)

        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            [production, dailyHost],
            planName: "Google AI Pro",
            now: now
        ))

        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.session, .weekly, .claudePool, .claudePoolWeekly]
        )
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [50, 75, 10, 20])
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.planName, "Google AI Pro")
    }

    func testArgonWeeklyComesFromItsGroupOrKnownBucket() throws {
        let byGroup = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
        {"displayName":"Gemini 4 Argon","buckets":[
          {"bucketId":"test-weekly","window":"weekly","remainingFraction":0.25},
          {"bucketId":"test-5h","window":"5h","remainingFraction":0}
        ]},
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.6}
        ]},
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.5}
        ]}
        """)], planName: nil, now: now))
        XCTAssertEqual(
            byGroup.windows.map(\.kind),
            [.weekly, .claudePoolWeekly, .argonWeekly]
        )
        XCTAssertEqual(byGroup.windows.map(\.usedPercent), [40, 50, 75])

        let byIdentifier = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-argon-wtu-weekly","remainingFraction":0.8}
        ]}
        """)], planName: nil, now: now))
        XCTAssertEqual(byIdentifier.windows.map(\.kind), [.argonWeekly])
        XCTAssertEqual(byIdentifier.windows.map(\.usedPercent), [20])
    }

    func testAmbiguousOrDisabledArgonIsNotShown() throws {
        let cases = [
            """
            {"bucketId":"first","window":"weekly","remainingFraction":0.9},
            {"bucketId":"second","window":"weekly","remainingFraction":0.1}
            """,
            #"{"bucketId":"only","window":"weekly","remainingFraction":0.5,"disabled":true}"#,
            #"{"bucketId":"only","window":"weekly","remainingFraction":0.5,"disabled":"no"}"#,
            #"{"bucketId":"only","window":"weekly"}"#
        ]
        for buckets in cases {
            let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
            {"displayName":"Gemini 4 Argon","buckets":[\(buckets)]}
            """)], planName: nil, now: now))
            XCTAssertEqual(snapshot.windows, [], buckets)
        }
    }

    func testBucketWithoutAFractionIsDroppedInsteadOfInvented() throws {
        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.75},
          {"bucketId":"gemini-weekly","resetTime":"2027-01-15T12:00:00Z"}
        ]}
        """)], planName: nil, now: now))

        XCTAssertEqual(snapshot.windows.map(\.kind), [.session])
        XCTAssertNil(AntigravityUsageMapper.summary(
            [Data(#"{"models":{}}"#.utf8)],
            planName: nil,
            now: now
        ))
    }

    func testSharedPoolsAloneDoNotProveArgonCompleteness() {
        XCTAssertFalse(AntigravityUsageMapper.isCompleteSummary(completeSummary))
        XCTAssertFalse(AntigravityUsageMapper.isCompleteSummary(summary("""
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-5h","remainingFraction":1},
          {"bucketId":"3p-weekly","remainingFraction":1}
        ]}
        """)))
    }

    func testPlanUsesThePaidTierAndProjectComesFromCodeAssist() {
        let paid = Data("""
        {
          "currentTier": {"id": "free-tier", "name": "Antigravity"},
          "paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"},
          "cloudaicompanionProject": "project-1"
        }
        """.utf8)
        XCTAssertEqual(AntigravityUsageMapper.plan(paid), "Google AI Pro")
        XCTAssertEqual(AntigravityUsageMapper.project(paid), "project-1")

        let unknownPaid = Data(
            #"{"paidTier":{"id":"g1-new","name":"Google AI Ultra for Business"}}"#.utf8
        )
        XCTAssertEqual(AntigravityUsageMapper.plan(unknownPaid), "Google AI Ultra")

        let free = Data(#"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#.utf8)
        XCTAssertEqual(AntigravityUsageMapper.plan(free), "Free")

        let unnamed = Data(#"{"currentTier":{"id":"standard-tier","name":"Antigravity"}}"#.utf8)
        XCTAssertNil(AntigravityUsageMapper.plan(unnamed))
        XCTAssertNil(AntigravityUsageMapper.project(unnamed))
    }

    private var withArgonJSON: String {
        var root = try! JSONSerialization.jsonObject(with: completeSummary) as! [String: Any]
        var groups = root["groups"] as! [[String: Any]]
        groups.append(["displayName": "Gemini 4 Argon", "buckets": [[
            "bucketId": "gemini-argon-wtu-weekly", "window": "weekly",
            "remainingFraction": 0.0082632, "resetTime": "2026-11-18T10:06:53Z"
        ]]])
        root["groups"] = groups
        return String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
    }

    func testArgonHasItsOwnRowWithoutSplittingThirdPartyPair() {
        let kinds: [QuotaKind] = [.session, .weekly, .claudePool, .claudePoolWeekly, .argonWeekly]
        let windows = kinds.map { QuotaWindow(kind: $0, usedPercent: 0, resetsAt: nil) }
        XCTAssertEqual(ProviderDetailsLayout.rows(windows).map { $0.map(\.kind) },
                       [[.session, .weekly], [.claudePool, .claudePoolWeekly], [.argonWeekly]])
    }

    func testHubIdentityUsesInstalledVersionAndRejectsStaleOrMalformedVersions() {
        XCTAssertTrue(AntigravityUsageClient.hubUserAgent(version: "2.31.2").hasPrefix("antigravity/hub/2.31.2 "))
        for value in [nil, "2.24.0", "not-a-version", "2.31.2\r\nInjected: value"] {
            XCTAssertTrue(AntigravityUsageClient.hubUserAgent(version: value).hasPrefix("antigravity/hub/2.26.0 "))
        }
    }

    func testDailyHostCanAddConsumedArgonAfterAllSharedPoolsArePresent() async throws {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(json: withArgonJSON)]
        ])
        let outcome = await AntigravityUsageClient(http: http).quotaSummary(accessToken: "test", project: nil, now: now)
        guard case .success(let summaries) = outcome else { return XCTFail("Expected quota summaries") }
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.map(\.host), [.ide, .app])
        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary(summaries, planName: nil, now: now))
        let argon = try XCTUnwrap(snapshot.windows.first { $0.kind == .argonWeekly })
        XCTAssertEqual(argon.kind.title, "Argon")
        XCTAssertEqual(MenuBarMetricID.argonWeekly.title, "Argon")
        XCTAssertEqual(argon.usedPercent, 99.17)
        XCTAssertEqual(argon.resetsAt, ISO8601DateFormatter().date(from: "2026-11-18T10:06:53Z"))
        let requests = await http.capturedRequests()
        XCTAssertTrue(requests.allSatisfy { $0.headers["User-Agent"]?.hasPrefix("antigravity/hub/") == true })
    }

    func testDualHostSummaryBuildsMergedRow1AndSeparateAppAndIDESections() throws {
        let appBody = Data("""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.90293604,"resetTime":"2026-11-19T07:10:14Z"},
            {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.850154,"resetTime":"2026-11-25T00:02:41Z"}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-5h","window":"5h","remainingFraction":1},
            {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1}
          ]},
          {"displayName":"Gemini 4 Argon","buckets":[
            {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":0.21893626,"resetTime":"2026-11-25T00:02:00Z"}
          ]}
        ]}
        """.utf8)
        let ideBody = Data("""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"resetTime":"2026-11-19T07:25:03Z"},
            {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-11-25T10:15:48Z"}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-5h","window":"5h","remainingFraction":1},
            {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.7359272,"resetTime":"2026-11-20T14:41:49Z"}
          ]},
          {"displayName":"Gemini 4 Argon","buckets":[
            {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-11-25T10:06:53Z"}
          ]}
        ]}
        """.utf8)

        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            [
                AntigravityHostSummary(host: .ide, data: ideBody),
                AntigravityHostSummary(host: .app, data: appBody)
            ],
            planName: "Google AI Pro",
            now: now
        ))

        XCTAssertEqual(snapshot.dashboardSubtitle, "Separate app limits • Antigravity & Antigravity IDE")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .claudePool, .claudePoolWeekly, .argonWeekly])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 9.71)
        XCTAssertEqual(snapshot.windows[0].series.map(\.id), ["antigravity-app", "antigravity-ide"])
        XCTAssertEqual(snapshot.windows[0].series.map(\.usedPercent), [9.71, 0])
        XCTAssertEqual(snapshot.windows[1].usedPercent, 14.98)
        XCTAssertEqual(snapshot.windows[1].series.map(\.usedPercent), [14.98, 0])
        XCTAssertEqual(snapshot.windows[3].usedPercent, 26.41)
        XCTAssertEqual(snapshot.windows[4].usedPercent, 78.11)

        XCTAssertEqual(snapshot.quotaSections.map(\.title), ["Antigravity", "Antigravity IDE"])
        XCTAssertEqual(snapshot.quotaSections[0].windows.map(\.usedPercent), [9.71, 14.98, 0, 0, 78.11])
        XCTAssertEqual(snapshot.quotaSections[1].windows.map(\.usedPercent), [0, 0, 0, 26.41, 0])
        for section in snapshot.quotaSections {
            XCTAssertEqual(
                ProviderDetailsLayout.rows(section.windows).map { $0.map(\.kind) },
                [[.session, .weekly], [.claudePool, .claudePoolWeekly], [.argonWeekly]]
            )
        }

        let credentialed = snapshot.withCredential(source: "Antigravity app", account: "user@example.com")
        XCTAssertEqual(credentialed.quotaSections, snapshot.quotaSections)
    }

    func testSingleHostSummaryDoesNotCreateDuplicateSections() throws {
        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            [AntigravityHostSummary(host: .app, data: Data(withArgonJSON.utf8))],
            planName: nil,
            now: now
        ))

        XCTAssertEqual(snapshot.quotaSections, [])
        XCTAssertEqual(snapshot.windows.first?.series, [])
    }

    func testDualQuotaBarLayoutPlacesLongerBarUnderneathAndSplitsEqualBars() {
        let series = [
            QuotaSeriesReading(id: "antigravity-app", title: "Antigravity", usedPercent: 9.71, resetsAt: nil),
            QuotaSeriesReading(id: "antigravity-ide", title: "Antigravity IDE", usedPercent: 0, resetsAt: nil)
        ]

        let remaining = DualQuotaBarLayout.layout(series: series, displayMode: .remaining)
        XCTAssertFalse(remaining.splitEqual)
        XCTAssertEqual(remaining.layers.map(\.id), ["antigravity-ide", "antigravity-app"])

        let used = DualQuotaBarLayout.layout(series: series, displayMode: .used)
        XCTAssertFalse(used.splitEqual)
        XCTAssertEqual(used.layers.map(\.id), ["antigravity-app", "antigravity-ide"])

        let equalUnused = DualQuotaBarLayout.layout(
            series: [
                QuotaSeriesReading(id: "antigravity-app", title: "Antigravity", usedPercent: 0, resetsAt: nil),
                QuotaSeriesReading(id: "antigravity-ide", title: "Antigravity IDE", usedPercent: 0, resetsAt: nil)
            ],
            displayMode: .remaining
        )
        XCTAssertTrue(equalUnused.splitEqual)
        XCTAssertEqual(equalUnused.layers.map(\.id), ["antigravity-app", "antigravity-ide"])
    }

    // MARK: - Cloud Code client

    func testQuotaSummaryUsesTheClientIdentityAndChecksBothHosts() async {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: withArgonJSON)]
        ])
        let client = AntigravityUsageClient(http: http)

        let outcome = await client.quotaSummary(
            accessToken: "token",
            project: "project-1",
            now: now
        )

        guard case let .success(summaries) = outcome else {
            return XCTFail("Expected a summary, got \(outcome)")
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.host, .ide)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].headers["User-Agent"], AntigravityUsageClient.quotaSummaryUserAgent)
        XCTAssertTrue(AntigravityUsageClient.quotaSummaryUserAgent.hasPrefix("antigravity/"))
        let body = try? JSONSerialization.jsonObject(
            with: requests[0].body ?? Data()
        ) as? [String: String]
        XCTAssertEqual(body, ["project": "project-1"])
    }

    func testQuotaSummaryAsksTheDailyHostWhenProductionIsIncomplete() async {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: """
            {"groups":[{"buckets":[{"bucketId":"3p-weekly","remainingFraction":1}]}]}
            """)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)]
        ])

        let outcome = await AntigravityUsageClient(http: http).quotaSummary(
            accessToken: "token",
            project: nil,
            now: now
        )

        guard case let .success(summaries) = outcome else {
            return XCTFail("Expected summaries, got \(outcome)")
        }
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.map(\.host), [.ide, .app])
        let body = await http.capturedRequests().first?.body
        XCTAssertEqual(body, Data("{}".utf8))
    }

    func testQuotaSummarySeparatesDenialRefusalAndRateLimits() async {
        func outcome(_ status: Int, headers: [String: String] = [:]) async
            -> AntigravitySummaryOutcome {
            let http = RoutedHTTPClient([
                prod + AntigravityUsageClient.summaryPath: [
                    httpResponse(status, headers: headers)
                ],
                daily + AntigravityUsageClient.summaryPath: [
                    httpResponse(status, headers: headers)
                ]
            ])
            return await AntigravityUsageClient(http: http).quotaSummary(
                accessToken: "token",
                project: nil,
                now: now
            )
        }

        guard case .denied = await outcome(403) else {
            return XCTFail("403 must be a denial, not a sign-in failure")
        }
        guard case .tokenRefused = await outcome(401) else {
            return XCTFail("401 must refuse the token")
        }
        guard case let .rateLimited(retryAt) = await outcome(
            429,
            headers: ["Retry-After": "90"]
        ) else {
            return XCTFail("429 must be a rate limit")
        }
        XCTAssertEqual(retryAt, now.addingTimeInterval(90))
        guard case .unavailable = await outcome(503) else {
            return XCTFail("503 must be unavailable")
        }
    }

    func testCodeAssistFallsThroughToTheDailyHostAfterAProductionDenial() async {
        let fallthroughHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(403)],
            daily + AntigravityUsageClient.planPath: [httpResponse(json: "{}")]
        ])
        let outcome = await AntigravityUsageClient(http: fallthroughHTTP)
            .loadCodeAssist(accessToken: "token")
        guard case .success = outcome else {
            return XCTFail("403 on production must not end the host loop")
        }

        let deniedHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(403)],
            daily + AntigravityUsageClient.planPath: [httpResponse(403)]
        ])
        let denied = await AntigravityUsageClient(http: deniedHTTP)
            .loadCodeAssist(accessToken: "token")
        guard case .denied = denied else {
            return XCTFail("403 on every host is a denial, not a sign-in failure")
        }
    }

    func testQuotaSummaryDoesNotReportDenialWhenAHostIsUnreachable() async {
        let partialHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)]
        ])
        let partial = await AntigravityUsageClient(http: partialHTTP)
            .quotaSummary(accessToken: "token", project: nil, now: now)
        guard case .unavailable = partial else {
            return XCTFail("A 403 from one of two unreachable hosts is transient")
        }

        let mixedHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(503)]
        ])
        let mixed = await AntigravityUsageClient(http: mixedHTTP)
            .quotaSummary(accessToken: "token", project: nil, now: now)
        guard case .unavailable = mixed else {
            return XCTFail("403 plus a failing host is transient, not a denial")
        }
    }

    func testCodeAssistSendsTheClientMetadata() async throws {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: "{}")]
        ])

        _ = await AntigravityUsageClient(http: http).loadCodeAssist(accessToken: "token")

        let requests = await http.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.body, AntigravityUsageClient.codeAssistPayload)
        XCTAssertEqual(request.headers["User-Agent"], AntigravityUsageClient.userAgent)
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
    }

    // MARK: - Provider

    func testProviderReadsCloudQuotaWithPlanAndNeverTheModelList() async throws {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: """
            {"paidTier":{"id":"g1-ultra-tier"},"cloudaicompanionProject":"p"}
            """)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)]
        ])
        let provider = makeProvider(http: http)

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, "Google AI Ultra")
        XCTAssertEqual(snapshot.windows.count, 4)
        let urls = await http.capturedRequests().map(\.url.absoluteString)
        XCTAssertFalse(urls.contains { $0.contains("fetchAvailableModels") })

        // The plan and project are read hourly, not on every refresh.
        _ = try await provider.fetch()
        let planReads = await http.capturedRequests()
            .filter { $0.url.path.hasSuffix("loadCodeAssist") }
        XCTAssertEqual(planReads.count, 1)
    }

    func testRefusedTokenIsRenewedOnceAndCached() async throws {
        let files = MemoryFiles()
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [
                httpResponse(401),
                httpResponse(json: "{}")
            ],
            AntigravityUsageClient.googleOAuthURL.absoluteString: [
                httpResponse(json: #"{"access_token":"fresh","expires_in":3600}"#)
            ],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)]
        ])
        let provider = makeProvider(http: http, files: files)

        _ = try await provider.fetch()

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer fresh")
        XCTAssertNotNil(files.value(at: AntigravityAuthStore.cachePath))
    }

    func testDeniedQuotaFallsBackToTheRunningCLI() async throws {
        let cloud = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: """
            {"paidTier":{"id":"g1-pro-tier"}}
            """)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(403)]
        ])
        let loopback = RoutedHTTPClient([
            "https://127.0.0.1:5555" + AntigravityLocalClient.summaryPath: [
                httpResponse(json: """
                {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
                  {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.3868888}
                ]}]}}
                """)
            ]
        ])
        let inspector = FixedProcessInspector(
            running: [LocalProcess(pid: 10, executablePath: "/usr/local/bin/agy")],
            commandLines: [
                10: ProcessCommandLine(arguments: ["agy"], environment: []),
                11: ProcessCommandLine(
                    arguments: ["bash"],
                    environment: ["ANTIGRAVITY_CSRF_TOKEN=csrf-1"]
                )
            ],
            childProcesses: [10: [11]],
            ports: [10: [5555]]
        )
        let provider = makeProvider(
            http: cloud,
            local: AntigravityLocalClient(inspector: inspector, http: loopback)
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [61.31])
        XCTAssertEqual(snapshot.planName, "Google AI Pro")
        let local = await loopback.capturedRequests()
        XCTAssertEqual(local.first?.headers["X-Codeium-Csrf-Token"], "csrf-1")
    }

    func testDeniedQuotaWithoutALocalToolKeepsTheLastReading() async {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: "{}")],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(403)]
        ])

        await assertFailure(makeProvider(http: http), kind: .transient)
    }

    func testRejectedRefreshTokenIsAnExpiredSignIn() async {
        let http = RoutedHTTPClient([
            AntigravityUsageClient.googleOAuthURL.absoluteString: [
                httpResponse(400, json: #"{"error":"invalid_grant"}"#)
            ]
        ])
        let provider = makeProvider(http: http, expiry: "2020-01-01T00:00:00Z")

        await assertFailure(provider, kind: .authentication)
    }

    func testUnavailableRefreshIsTransient() async {
        let http = RoutedHTTPClient([
            AntigravityUsageClient.googleOAuthURL.absoluteString: [httpResponse(503)]
        ])
        let provider = makeProvider(http: http, expiry: "2020-01-01T00:00:00Z")

        await assertFailure(provider, kind: .transient)
    }

    // MARK: - Local discovery

    func testEndpointsUseTheAppTokenAndSkipOtherEditors() {
        let inspector = FixedProcessInspector(
            running: [
                LocalProcess(
                    pid: 1,
                    executablePath: "/Applications/Windsurf.app/Contents/Resources/bin/language_server_macos_arm"
                ),
                LocalProcess(
                    pid: 2,
                    executablePath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
                ),
                LocalProcess(pid: 3, executablePath: "/opt/homebrew/bin/agy"),
                LocalProcess(pid: 4, executablePath: "/usr/bin/ssh")
            ],
            commandLines: [
                1: ProcessCommandLine(
                    arguments: ["language_server", "--ide_name", "windsurf", "--csrf_token", "other"],
                    environment: []
                ),
                2: ProcessCommandLine(
                    arguments: [
                        "language_server", "--csrf_token=app-token",
                        "--extension_server_port", "7777"
                    ],
                    environment: []
                ),
                3: ProcessCommandLine(
                    arguments: ["agy"],
                    environment: ["ANTIGRAVITY_CSRF_TOKEN=cli-token"]
                )
            ],
            ports: [1: [5000], 2: [6000], 3: [6100]]
        )

        let endpoints = AntigravityLocalClient(inspector: inspector).endpoints()

        XCTAssertEqual(endpoints.map(\.url.absoluteString), [
            "https://127.0.0.1:6000" + AntigravityLocalClient.summaryPath,
            "http://127.0.0.1:6000" + AntigravityLocalClient.summaryPath,
            "http://127.0.0.1:7777" + AntigravityLocalClient.summaryPath,
            "https://127.0.0.1:6100" + AntigravityLocalClient.summaryPath,
            "http://127.0.0.1:6100" + AntigravityLocalClient.summaryPath
        ])
        XCTAssertEqual(
            endpoints.map(\.csrfToken),
            ["app-token", "app-token", "app-token", "cli-token", "cli-token"]
        )
    }

    func testParsesProcessArgumentsAndEnvironment() throws {
        var bytes = withUnsafeBytes(of: Int32(3).littleEndian) { Array($0) }
        bytes += Array("/usr/local/bin/agy".utf8) + [0, 0, 0, 0]
        for value in ["agy", "", "--flag", "A=1", "ANTIGRAVITY_CSRF_TOKEN=secret", ""] {
            bytes += Array(value.utf8) + [0]
        }
        bytes += [0, 0]

        let commandLine = try XCTUnwrap(
            SystemProcessInspector.parseCommandLine(bytes)
        )

        XCTAssertEqual(commandLine.arguments, ["agy", "", "--flag"])
        XCTAssertEqual(commandLine.environment, ["A=1", "ANTIGRAVITY_CSRF_TOKEN=secret"])
        XCTAssertEqual(commandLine.environmentValue("ANTIGRAVITY_CSRF_TOKEN"), "secret")
        XCTAssertNil(commandLine.value(forFlag: "--flag"))
        XCTAssertNil(SystemProcessInspector.parseCommandLine([1, 0]))
    }

    func testListeningPortsAreScopedToTheProcessAndLoopback() {
        let runner = ScriptedProcessRunner([
            "/usr/sbin/lsof": ProcessResult(exitCode: 0, stdout: """
            COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            agy 42 me 10u IPv4 0x1 0t0 TCP 127.0.0.1:61234 (LISTEN)
            agy 42 me 11u IPv6 0x2 0t0 TCP [::1]:61234 (LISTEN)
            agy 42 me 12u IPv4 0x3 0t0 TCP *:5555 (LISTEN)
            agy 42 me 13u IPv4 0x4 0t0 TCP 192.168.1.2:7000 (LISTEN)
            agy 42 me 14u IPv4 0x5 0t0 TCP 127.0.0.1:50000->127.0.0.1:443 (ESTABLISHED)
            """, stderr: "")
        ])
        let inspector = SystemProcessInspector(runner: runner)

        XCTAssertEqual(inspector.listeningPorts(of: 42), [61234, 5555])
        let arguments = runner.recordedCalls().first?.arguments ?? []
        XCTAssertTrue(arguments.contains("-a"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["-p", "42"])
    }

    func testProcessListReadsOnlyIdentifiersAndExecutables() {
        let processes = SystemProcessInspector.parseProcesses("""
          101 /usr/local/bin/agy
            7 /Applications/Antigravity.app/Contents/Resources/bin/language_server
        bad line
        """)

        XCTAssertEqual(processes, [
            LocalProcess(pid: 101, executablePath: "/usr/local/bin/agy"),
            LocalProcess(
                pid: 7,
                executablePath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
            )
        ])
        XCTAssertEqual(processes[1].executableName, "language_server")
    }

    func testLoopbackClientRefusesOtherHosts() async {
        do {
            _ = try await LoopbackHTTPClient().send(HTTPRequest(
                method: .post,
                url: URL(string: "https://example.com/")!
            ))
            XCTFail("Expected a refusal")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private var completeJSON: String {
        """
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-5h","remainingFraction":1},
            {"bucketId":"gemini-weekly","remainingFraction":0.5}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-5h","remainingFraction":1},
            {"bucketId":"3p-weekly","remainingFraction":0.75}
          ]}
        ]}
        """
    }

    private var completeSummary: Data { Data(completeJSON.utf8) }

    private func summary(_ groups: String) -> Data {
        Data(#"{"groups":[\#(groups)]}"#.utf8)
    }

    private func makeProvider(
        http: HTTPClient,
        files: MemoryFiles = MemoryFiles(),
        expiry: String = "2027-06-01T00:00:00Z",
        local: AntigravityLocalClient = AntigravityLocalClient(
            inspector: FixedProcessInspector(),
            http: RoutedHTTPClient([:])
        )
    ) -> AntigravityProvider {
        let date = FixedDateProvider(value: now)
        return AntigravityProvider(
            authStore: AntigravityAuthStore(
                runner: keychainRunner(antigravityToken: """
                {"token":{"access_token":"stored","refresh_token":"refresh",
                 "expiry":"\(expiry)"}}
                """),
                files: files,
                dateProvider: date
            ),
            client: AntigravityUsageClient(http: http),
            localClient: local,
            dateProvider: date
        )
    }

    private func assertFailure(
        _ provider: AntigravityProvider,
        kind: ProviderFailureKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetch()
            XCTFail("Expected a \(kind) failure", file: file, line: line)
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, kind, failure.message, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
