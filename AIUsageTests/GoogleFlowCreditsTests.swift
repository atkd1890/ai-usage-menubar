import XCTest
@testable import AIUsage

final class GoogleFlowCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let edgePath = "~/Library/Application Support/Microsoft Edge/Default/Cookies"
    private let chromePath = "~/Library/Application Support/Google/Chrome/Default/Cookies"
    private let flowPage = #"<html><script>window.WIZ_global_data = {"FdrFJe":"-1","SNlM0e":"fake-at-token:1800000000000","cfb2h":"fake-build"};</script></html>"#
    private let flowBody = """
    )]}'

    149
    [["wrb.fr","nzlxg","[420,1,2,2,null,1050,[1800100000,951000000]]",null,null,null,"generic"],["di",313],["af.httprm",313,"-1",4]]
    25
    [["e",4,null,null,185]]
    """
    private let musicBody = #"{"data":{"tokens_remaining":96000.0,"credits_remaining":8000.0},"add_token_transactions":[]}"#
    private let stitchBody = """
    )]}'

    118
    [["wrb.fr","N5xENe","[null,null,null,null,null,null,null,null,2,400,null,10000000,null,null,null,null,1,1,1]",null,null,null,"generic"]]
    """
    private let notebookLMBody = """
    )]}'

    160
    [["wrb.fr","EylDcb","[1,[[null,null,null,null,1,[1800018000,621738000],null,75],[null,null,null,null,2,[1800604800,621742000],null,90]]]",null,null,null,"generic"]]
    """

    // MARK: Google Flow

    func testFlowPageTokenIsExtractedAndValidated() {
        XCTAssertEqual(GoogleFlowCredits.pageToken(in: Data(flowPage.utf8)), "fake-at-token:1800000000000")
        XCTAssertNil(GoogleFlowCredits.pageToken(in: Data("<html>signed out</html>".utf8)))
        XCTAssertNil(GoogleFlowCredits.pageToken(in: Data(#""SNlM0e":"bad token\r\nX: y""#.utf8)))
    }

    func testFlowBalanceAndResetParseFromBatchResponse() throws {
        let parsed = try XCTUnwrap(GoogleFlowCredits.parseFlow(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(flowBody.utf8)), now: now))
        XCTAssertEqual(parsed.balance, 420)
        XCTAssertEqual(parsed.resetsAt, Date(timeIntervalSince1970: 1_800_100_000))
    }

    func testFlowZeroIsZeroAndMalformedOrFailedReturnsNil() throws {
        let zero = flowBody.replacingOccurrences(of: "[420,", with: "[0,")
        let parsedZero = try XCTUnwrap(GoogleFlowCredits.parseFlow(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(zero.utf8)), now: now))
        XCTAssertEqual(parsedZero.balance, 0)
        for body in [")]}'\n[[\"wrb.fr\",\"nzlxg\",null,null,null,[3],\"generic\"]]", "<html>", ""] {
            XCTAssertNil(GoogleFlowCredits.parseFlow(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)), now: now))
        }
        XCTAssertNil(GoogleFlowCredits.parseFlow(response: HTTPResponse(statusCode: 500, headers: [:], body: Data(flowBody.utf8)), now: now))
    }

    func testFlowRequestIsReadOnlyRPCWithFormEncodedToken() throws {
        let request = GoogleFlowCredits.flowRequest(session: GeminiWebSession(cookieHeader: "__Secure-1PSID=fake"), token: "a+b:c")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.host, "flow.google.com")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "rpcids" })?.value, "nzlxg")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.hasSuffix("&at=a%2Bb%3Ac"))
        XCTAssertEqual(body.components(separatedBy: "&").first?.removingPercentEncoding?.dropFirst(6),
                       #"[[["nzlxg","[]",null,"generic"]]]"#)
        XCTAssertEqual(request.headers["Cookie"], "__Secure-1PSID=fake")
        XCTAssertNil(request.headers["Authorization"])
    }

    // MARK: Plan Allotments & QuotaWindow Mapping

    func testMediaQuotaWindowsCalculatePercentFromPlanAllotmentAndClampDailyBonus() {
        XCTAssertEqual(GoogleFlowCredits.flowAllotment(forPlan: "Google AI Pro"), 1_000)
        XCTAssertEqual(GoogleFlowCredits.flowAllotment(forPlan: "Google AI Ultra"), 25_000)
        XCTAssertEqual(GoogleFlowCredits.flowAllotment(forPlan: "Free"), 100)
        XCTAssertEqual(GoogleFlowCredits.flowAllotment(forPlan: nil), 1_000)

        XCTAssertEqual(GoogleFlowCredits.flowMusicAllotment(forPlan: "Google AI Pro"), 10_000)
        XCTAssertEqual(GoogleFlowCredits.flowMusicAllotment(forPlan: "Google AI Ultra"), 30_000)
        XCTAssertEqual(GoogleFlowCredits.flowMusicAllotment(forPlan: "Free"), 100)
        XCTAssertEqual(GoogleFlowCredits.flowMusicAllotment(forPlan: nil), 10_000)

        let reset = Date(timeIntervalSince1970: 1_800_100_000)
        let flowPartial = GoogleFlowCredits.window(
            id: "gemini.flow",
            title: "Flow Video Monthly",
            reading: .available(balance: 420, resetsAt: reset),
            allotment: GoogleFlowCredits.flowAllotment(forPlan: "Google AI Pro")
        )
        XCTAssertEqual(flowPartial.usedPercent, 58, accuracy: 0.01)
        XCTAssertEqual(flowPartial.remainingCount, 420)
        XCTAssertEqual(flowPartial.limitCount, 1_000)
        XCTAssertEqual(flowPartial.resetsAt, reset)

        // 1,000 monthly + 50 daily free credits -> denominator expands to 1,050 (0% used, never negative).
        let flowWithBonus = GoogleFlowCredits.window(
            id: "gemini.flow",
            title: "Flow Video Monthly",
            reading: .available(balance: 1_050, resetsAt: reset),
            allotment: GoogleFlowCredits.flowAllotment(forPlan: "Google AI Pro")
        )
        XCTAssertEqual(flowWithBonus.usedPercent, 0, accuracy: 0.01)
        XCTAssertEqual(flowWithBonus.remainingCount, 1_050)
        XCTAssertEqual(flowWithBonus.limitCount, 1_050)

        let expiredMusic = GoogleFlowCredits.window(
            id: "gemini.flowmusic",
            title: "Flow Music Monthly",
            reading: .unavailable(status: "Expired"),
            allotment: GoogleFlowCredits.flowMusicAllotment(forPlan: "Google AI Pro")
        )
        XCTAssertTrue(expiredMusic.isInactive)
        XCTAssertEqual(expiredMusic.inactiveDetail, "Expired")
    }

    // MARK: Flow Music

    func testFlowMusicChunkedSupabaseCookieDecodes() throws {
        let cookies = musicCookies(expiresAt: 1_800_003_600)
        let session = try XCTUnwrap(GoogleFlowCredits.flowMusicSession(cookies: cookies))
        XCTAssertEqual(session.accessToken, "fake.music.jwt")
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertNil(GoogleFlowCredits.flowMusicSession(cookies: ["sb-sb-auth-token.1": "orphan"]))
        XCTAssertNil(GoogleFlowCredits.flowMusicSession(cookies: ["sb-sb-auth-token": "base64-!!!"]))
    }

    func testFlowMusicCreditsMapZeroRejectedSessionAndSchemaDrift() {
        let clean = GoogleFlowCredits.mapFlowMusic(response: httpResponse(json: musicBody))
        XCTAssertEqual(clean.reading, .available(balance: 8000, resetsAt: nil))
        XCTAssertTrue(clean.warnings.isEmpty)

        XCTAssertEqual(GoogleFlowCredits.mapFlowMusic(response: httpResponse(json: #"{"data":{"credits_remaining":0}}"#)).reading, .available(balance: 0, resetsAt: nil))
        XCTAssertEqual(GoogleFlowCredits.mapFlowMusic(response: httpResponse(401, json: #"{"detail":"Unauthorized"}"#)).reading, .unavailable(status: "Expired"))
        XCTAssertEqual(GoogleFlowCredits.mapFlowMusic(response: httpResponse(json: #"{"data":{}}"#)).reading, .unavailable(status: "N/A"))

        let drifted = GoogleFlowCredits.mapFlowMusic(response: httpResponse(json: #"{"data":{"credits_remaining":100,"new_field":true}}"#))
        XCTAssertEqual(drifted.reading, .available(balance: 100, resetsAt: nil))
        XCTAssertTrue(drifted.warnings.contains { $0.id == "schema.added.Gemini Flow Music data" && $0.detail.contains("new_field") })
    }

    // MARK: Credential scope & 2-bar detail layout

    func testBrowserModeReadsFlowWithSecureOSIDAndFlowMusicFromSameBrowserOnly() async throws {
        let db = FlowTestSQLite(
            google: #"[{"name":"__Secure-1PSID","host":".google.com","value":"fake-google","encrypted":""}]"#,
            flow: #"[{"name":"__Secure-OSID","host":"flow.google.com","value":"fake-osid","encrypted":""}]"#,
            music: musicRows(expiresAt: 1_800_003_600),
            stitch: #"[{"name":"__Secure-OSID","host":"stitch.google.com","value":"fake-stitch-osid","encrypted":""}]"#,
            notebookLM: #"[{"name":"__Secure-OSID","host":"notebook.google.com","value":"fake-nb-osid","encrypted":""}]"#
        )
        let flowHTTP = MockHTTPClient([html(flowPage), HTTPResponse(statusCode: 200, headers: [:], body: Data(flowBody.utf8))])
        let musicHTTP = MockHTTPClient([httpResponse(json: musicBody)])
        let stitchHTTP = MockHTTPClient([html(flowPage), HTTPResponse(statusCode: 200, headers: [:], body: Data(stitchBody.utf8))])
        let notebookLMHTTP = MockHTTPClient([html(flowPage), HTTPResponse(statusCode: 200, headers: [:], body: Data(notebookLMBody.utf8))])
        let credits = GoogleFlowCredits(
            authStore: auth(db: db, path: edgePath),
            flowHTTP: flowHTTP,
            musicHTTP: musicHTTP,
            stitchHTTP: stitchHTTP,
            notebookLMHTTP: notebookLMHTTP,
            dateProvider: FixedDateProvider(value: now)
        )
        let result = await credits.fetch(source: .nativeAppEdge, googleSession: nil)
        XCTAssertEqual(result.flow, .available(balance: 420, resetsAt: Date(timeIntervalSince1970: 1_800_100_000)))
        XCTAssertEqual(result.music, .available(balance: 8000, resetsAt: nil))
        XCTAssertEqual(result.stitch, .available(used: 2, limit: 400, resetsAt: nil))
        XCTAssertEqual(result.notebookLMSession, .available(usedPercent: 25, resetsAt: Date(timeIntervalSince1970: 1_800_018_000)))
        XCTAssertEqual(result.notebookLMWeekly, .available(usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1_800_604_800)))
        XCTAssertTrue(result.diagnosticWarnings.isEmpty)

        let flowRequests = await flowHTTP.capturedRequests()
        XCTAssertEqual(flowRequests.map(\.url.host), ["flow.google.com", "flow.google.com"])
        XCTAssertEqual(flowRequests.map(\.method), [.get, .post])
        XCTAssertTrue(flowRequests.allSatisfy {
            $0.headers["Cookie"] == "__Secure-1PSID=fake-google; __Secure-OSID=fake-osid" && $0.headers["Authorization"] == nil
        })
        let stitchRequests = await stitchHTTP.capturedRequests()
        XCTAssertEqual(stitchRequests.map(\.url.host), ["stitch.google.com", "stitch.google.com"])
        XCTAssertTrue(stitchRequests.allSatisfy {
            $0.headers["Cookie"] == "__Secure-1PSID=fake-google; __Secure-OSID=fake-stitch-osid" && $0.headers["Authorization"] == nil
        })
        let notebookRequests = await notebookLMHTTP.capturedRequests()
        XCTAssertEqual(notebookRequests.map(\.url.host), ["notebook.google.com", "notebook.google.com"])
        XCTAssertTrue(notebookRequests.allSatisfy {
            $0.headers["Cookie"] == "__Secure-1PSID=fake-google; __Secure-OSID=fake-nb-osid" && $0.headers["Authorization"] == nil
        })
        let musicRequests = await musicHTTP.capturedRequests()
        XCTAssertEqual(musicRequests.count, 1)
        XCTAssertEqual(musicRequests[0].url.absoluteString, "https://www.flowmusic.app/__api/billing/credits")
        XCTAssertEqual(musicRequests[0].headers["Authorization"], "Bearer fake.music.jwt")
        XCTAssertNil(musicRequests[0].headers["Cookie"])

        XCTAssertTrue(db.queries.contains { $0.contains("host_key = '.google.com'") && $0.contains("'__Secure-1PSID', '__Secure-1PSIDTS'") })
        XCTAssertTrue(db.queries.contains { $0.contains("host_key = 'flow.google.com'") && $0.contains("('__Secure-OSID')") })
        XCTAssertTrue(db.queries.contains { $0.contains("host_key = 'stitch.google.com'") && $0.contains("('__Secure-OSID')") })
        XCTAssertTrue(db.queries.contains { $0.contains("host_key = 'notebook.google.com'") && $0.contains("('__Secure-OSID')") })
        XCTAssertFalse(db.queries.contains { $0.contains("'OSID'") })
        XCTAssertTrue(db.queries.contains { $0.contains("host_key = 'www.flowmusic.app'") && $0.contains("'sb-sb-auth-token.0'") })
        XCTAssertTrue(db.paths.allSatisfy { $0 == edgePath })
        XCTAssertTrue(db.writes.isEmpty)

        // The page token is reused per host for the same session.
        _ = await credits.fetch(source: .nativeAppEdge, googleSession: nil)
        let reused = await flowHTTP.capturedRequests()
        XCTAssertEqual(reused.count, 3)
        XCTAssertEqual(reused.last?.method, .post)
        let reusedStitch = await stitchHTTP.capturedRequests()
        XCTAssertEqual(reusedStitch.count, 3)
        XCTAssertEqual(reusedStitch.last?.method, .post)
        let reusedNotebook = await notebookLMHTTP.capturedRequests()
        XCTAssertEqual(reusedNotebook.count, 3)
        XCTAssertEqual(reusedNotebook.last?.method, .post)
    }

    // MARK: Stitch & NotebookLM

    func testStitchParsesUsedAndLimitAndHandlesProto3Zero() throws {
        let parsed = try XCTUnwrap(GoogleFlowCredits.parseStitch(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(stitchBody.utf8))))
        XCTAssertEqual(parsed.used, 2)
        XCTAssertEqual(parsed.limit, 400)

        let zeroBody = stitchBody.replacingOccurrences(of: ",2,400,", with: ",0,400,")
        let parsedZero = try XCTUnwrap(GoogleFlowCredits.parseStitch(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(zeroBody.utf8))))
        XCTAssertEqual(parsedZero.used, 0)
        XCTAssertEqual(parsedZero.limit, 400)

        let nullUsedBody = stitchBody.replacingOccurrences(of: ",2,400,", with: ",null,400,")
        let parsedNullUsed = try XCTUnwrap(GoogleFlowCredits.parseStitch(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(nullUsedBody.utf8))))
        XCTAssertEqual(parsedNullUsed.used, 0)
        XCTAssertEqual(parsedNullUsed.limit, 400)

        let exhaustedBody = stitchBody.replacingOccurrences(of: ",2,400,", with: ",400,400,")
        let parsedExhausted = try XCTUnwrap(GoogleFlowCredits.parseStitch(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(exhaustedBody.utf8))))
        XCTAssertEqual(parsedExhausted.used, 400)
        XCTAssertEqual(parsedExhausted.limit, 400)

        let zeroLimitBody = stitchBody.replacingOccurrences(of: ",2,400,", with: ",2,0,")
        XCTAssertNil(GoogleFlowCredits.parseStitch(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(zeroLimitBody.utf8))))
        XCTAssertNil(GoogleFlowCredits.parseStitch(response: HTTPResponse(statusCode: 500, headers: [:], body: Data(stitchBody.utf8))))
        XCTAssertNil(GoogleFlowCredits.parseStitch(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>".utf8))))

        let window = GoogleFlowCredits.stitchWindow(id: "gemini.stitch", title: "Stitch Daily", reading: .available(used: 2, limit: 400, resetsAt: nil))
        XCTAssertEqual(window.usedPercent, 0.5, accuracy: 0.001)
        XCTAssertEqual(window.remainingCount, 398)
        XCTAssertEqual(window.limitCount, 400)
        XCTAssertNil(window.resetsAt)

        let unavailable = GoogleFlowCredits.stitchWindow(id: "gemini.stitch", title: "Stitch Daily", reading: .unavailable(status: "N/A"))
        XCTAssertTrue(unavailable.isInactive)
        XCTAssertEqual(unavailable.inactiveDetail, "N/A")
    }

    func testStitchRequestIsReadOnlyBatchRPC() throws {
        let request = GoogleFlowCredits.stitchRequest(session: GeminiWebSession(cookieHeader: "__Secure-1PSID=fake"), token: "a+b:c")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.host, "stitch.google.com")
        XCTAssertEqual(request.url.path, "/_/Nemo/data/batchexecute")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "rpcids" })?.value, "N5xENe")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.hasSuffix("&at=a%2Bb%3Ac"))
        XCTAssertEqual(body.components(separatedBy: "&").first?.removingPercentEncoding?.dropFirst(6),
                       #"[[["N5xENe","[]",null,"generic"]]]"#)
        XCTAssertEqual(request.headers["X-Same-Domain"], "1")
        XCTAssertEqual(request.headers["Cookie"], "__Secure-1PSID=fake")
        XCTAssertNil(request.headers["Authorization"])
    }

    func testNotebookLMParsesSessionAndWeeklyPoolsAndHandlesZeroRemaining() throws {
        let parsed = try XCTUnwrap(GoogleFlowCredits.parseNotebookLM(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(notebookLMBody.utf8)), now: now))
        XCTAssertEqual(parsed.session, .available(usedPercent: 25, resetsAt: Date(timeIntervalSince1970: 1_800_018_000)))
        XCTAssertEqual(parsed.weekly, .available(usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1_800_604_800)))

        let zeroAndPastReset = """
        )]}'
        [["wrb.fr","EylDcb","[1,[[null,null,null,null,1,[1799999000,0],null,null],[null,null,null,null,2,[1800604800,0],null,null]]]",null,null,null,"generic"]]
        """
        let parsedZero = try XCTUnwrap(GoogleFlowCredits.parseNotebookLM(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(zeroAndPastReset.utf8)), now: now))
        // Pool 1 had a past reset and null remaining -> skipped; Pool 2 had future reset and null remaining -> 0% remaining (100% used).
        XCTAssertNil(parsedZero.session)
        XCTAssertEqual(parsedZero.weekly, .available(usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 1_800_604_800)))

        XCTAssertNil(GoogleFlowCredits.parseNotebookLM(response: HTTPResponse(statusCode: 500, headers: [:], body: Data(notebookLMBody.utf8)), now: now))
        XCTAssertNil(GoogleFlowCredits.parseNotebookLM(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>".utf8)), now: now))
    }

    func testNotebookLMRequestIsReadOnlyBatchRPC() throws {
        let request = GoogleFlowCredits.notebookLMRequest(session: GeminiWebSession(cookieHeader: "__Secure-1PSID=fake"), token: "a+b:c")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.host, "notebook.google.com")
        XCTAssertEqual(request.url.path, "/_/LabsTailwindUi/data/batchexecute")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "rpcids" })?.value, "EylDcb")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.hasSuffix("&at=a%2Bb%3Ac"))
        XCTAssertEqual(body.components(separatedBy: "&").first?.removingPercentEncoding?.dropFirst(6),
                       #"[[["EylDcb","[]",null,"generic"]]]"#)
        XCTAssertEqual(request.headers["X-Same-Domain"], "1")
        XCTAssertEqual(request.headers["Cookie"], "__Secure-1PSID=fake")
        XCTAssertNil(request.headers["Authorization"])
    }

    func testStaleFlowTokenWithHTTP200NullPayloadInvalidatesCacheAndRefetchesOnce() async {
        let db = FlowTestSQLite(google: "[]", flow: "[]", music: "[]")
        let flowHTTP = MockHTTPClient([
            html(flowPage),
            HTTPResponse(statusCode: 200, headers: [:], body: Data(flowBody.utf8)),
            // Second poll uses cached SNlM0e, server returns HTTP 200 with null wrb.fr payload -> must refetch HTML + retry POST.
            HTTPResponse(statusCode: 200, headers: [:], body: Data(")]}'\n[[\"wrb.fr\",\"nzlxg\",null,null,null,[3],\"generic\"]]".utf8)),
            html(flowPage),
            HTTPResponse(statusCode: 200, headers: [:], body: Data(flowBody.utf8))
        ])
        let credits = GoogleFlowCredits(authStore: auth(db: db, path: chromePath), flowHTTP: flowHTTP, musicHTTP: MockHTTPClient([]),
                                        dateProvider: FixedDateProvider(value: now))
        let first = await credits.fetch(source: .chrome, googleSession: GeminiWebSession(cookieHeader: "__Secure-1PSID=fake-google"))
        XCTAssertEqual(first.flow, .available(balance: 420, resetsAt: Date(timeIntervalSince1970: 1_800_100_000)))

        let second = await credits.fetch(source: .chrome, googleSession: GeminiWebSession(cookieHeader: "__Secure-1PSID=fake-google"))
        XCTAssertEqual(second.flow, .available(balance: 420, resetsAt: Date(timeIntervalSince1970: 1_800_100_000)))
        let requests = await flowHTTP.capturedRequests()
        XCTAssertEqual(requests.map(\.method), [.get, .post, .post, .get, .post])
    }

    func testDesktopOnlyModeNeverReadsBrowserCookiesAndOmitsMediaTiles() async {
        let db = FlowTestSQLite(google: "[]", flow: "[]", music: "[]")
        let flowHTTP = MockHTTPClient([])
        let credits = GoogleFlowCredits(authStore: auth(db: db, path: edgePath), flowHTTP: flowHTTP, musicHTTP: MockHTTPClient([]),
                                        dateProvider: FixedDateProvider(value: now))
        let result = await credits.fetch(source: .nativeApp, googleSession: nil)
        XCTAssertEqual(result, .empty)
        XCTAssertTrue(db.queries.isEmpty)
        let requests = await flowHTTP.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testExpiredFlowMusicSessionIsNeverRefreshedOrSent() async {
        let db = FlowTestSQLite(google: #"[{"name":"__Secure-1PSID","host":".google.com","value":"fake-google","encrypted":""}]"#,
                                flow: "[]",
                                music: musicRows(expiresAt: 1_799_999_000))
        let musicHTTP = MockHTTPClient([])
        let credits = GoogleFlowCredits(authStore: auth(db: db, path: chromePath),
                                        flowHTTP: MockHTTPClient([html(flowPage), HTTPResponse(statusCode: 200, headers: [:], body: Data(flowBody.utf8))]),
                                        musicHTTP: musicHTTP, dateProvider: FixedDateProvider(value: now))
        let result = await credits.fetch(source: .chrome, googleSession: GeminiWebSession(cookieHeader: "__Secure-1PSID=fake-google"))
        XCTAssertEqual(result.music, .unavailable(status: "Expired"))
        let requests = await musicHTTP.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testMergingMediaCreditsPlacesTwoDetailBarsInOneRowWithoutAlteringAdditionalCredits() {
        let reset = Date(timeIntervalSince1970: 1_800_100_000)
        let base = ProviderSnapshot(
            provider: .gemini,
            planName: "Google AI Pro",
            windows: [
                QuotaWindow(kind: .session, usedPercent: 10, resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(kind: .weekly, usedPercent: 20, resetsAt: now.addingTimeInterval(86_400))
            ],
            fetchedAt: now,
            credentialSource: "Gemini app",
            usageDetails: [
                ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "AI Credits 0 · Off")
            ]
        )
        let media = GoogleFlowCreditsResult(
            flow: .available(balance: 1_050, resetsAt: reset),
            music: .unavailable(status: "Expired"),
            stitch: .available(used: 2, limit: 400, resetsAt: nil),
            notebookLMSession: .available(usedPercent: 25, resetsAt: reset),
            notebookLMWeekly: .available(usedPercent: 10, resetsAt: reset.addingTimeInterval(86_400)),
            diagnosticWarnings: []
        )
        let merged = base.mergingMediaCredits(media)
        XCTAssertEqual(merged.credentialSource, "Gemini app")
        XCTAssertEqual(merged.usageDetails, base.usageDetails)

        let summary = ProviderDetailsLayout.summaryWindows(merged)
        let details = ProviderDetailsLayout.detailWindows(merged)
        XCTAssertEqual(summary.map(\.kind), [.session, .weekly])
        XCTAssertEqual(details.map(\.kind), [
            .additional(id: "gemini.notebooklm.session", title: "NotebookLM Session"),
            .additional(id: "gemini.notebooklm.weekly", title: "NotebookLM Weekly"),
            .additional(id: "gemini.flow", title: "Flow Video Monthly"),
            .additional(id: "gemini.flowmusic", title: "Flow Music Monthly"),
            .additional(id: "gemini.stitch", title: "Stitch Daily")
        ])
        XCTAssertEqual(ProviderDetailsLayout.rows(details).count, 3)
        XCTAssertEqual(details[0].usedPercent, 25, accuracy: 0.01)
        XCTAssertEqual(details[1].usedPercent, 10, accuracy: 0.01)
        XCTAssertEqual(details[2].remainingCount, 1_050)
        XCTAssertEqual(details[2].limitCount, 1_050)
        XCTAssertEqual(details[2].usedPercent, 0, accuracy: 0.01)
        XCTAssertEqual(details[2].resetsAt, reset)
        XCTAssertTrue(details[3].isInactive)
        XCTAssertEqual(details[3].inactiveDetail, "Expired")
        XCTAssertEqual(details[4].remainingCount, 398)
        XCTAssertEqual(details[4].limitCount, 400)
        XCTAssertEqual(details[4].usedPercent, 0.5, accuracy: 0.01)
    }

    @MainActor
    func testCombinedLoginMethodsUpgradePreservationAndConsistentTitles() {
        let suite = "GoogleFlowCreditsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Brand-new install defaults to `.desktopEdge`.
        let fresh = AppPreferences(defaults: defaults)
        XCTAssertEqual(fresh.loginMethod(for: .gemini), .desktopEdge)
        XCTAssertFalse(fresh.geminiCredentialAccessAllowed)

        // Existing user who already enabled Gemini app without a stored source key keeps `.nativeApp`.
        let legacySuite = "GoogleFlowCreditsTests.legacy.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(true, forKey: GeminiNativeAuthStore.accessKey)
        let upgraded = AppPreferences(defaults: legacyDefaults)
        XCTAssertEqual(upgraded.loginMethod(for: .gemini), .desktop)
        XCTAssertEqual(upgraded.geminiSource, .nativeApp)
        XCTAssertTrue(upgraded.geminiCredentialAccessAllowed)

        fresh.setLoginMethod(.desktop, for: .gemini)
        XCTAssertEqual(fresh.geminiSource, .nativeApp)
        fresh.setLoginMethod(.desktopEdge, for: .gemini)
        XCTAssertEqual(fresh.geminiSource, .nativeAppEdge)
        XCTAssertTrue(fresh.geminiNativeAccessAllowed)
        XCTAssertTrue(fresh.geminiEdgeCookiesAllowed)
        XCTAssertFalse(fresh.geminiChromeCookiesAllowed)
        XCTAssertTrue(fresh.geminiCredentialAccessAllowed)
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.loginMethod(for: .gemini), .desktopEdge)
        XCTAssertEqual(GeminiCredentialSource.nativeAppChrome.browser, .chrome)
        XCTAssertTrue(GeminiCredentialSource.nativeAppChrome.usesNativeApp)
        XCTAssertNil(GeminiCredentialSource.nativeApp.browser)
        XCTAssertEqual(ProviderLoginMethod.supported(for: .gemini).map { $0.title(for: .gemini) }, [
            "Desktop app + Edge", "Desktop app + Chrome", "Desktop app", "Browser (Edge)", "Browser (Chrome)"
        ])
    }

    // MARK: Helpers

    private func auth(db: FlowTestSQLite, path: String) -> GeminiAuthStore {
        GeminiAuthStore(sqlite: db, keychain: MemoryKeychain(), files: MemoryFiles([path: "exists"]), allowChromeCookies: true)
    }

    private func html(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html"], body: Data(text.utf8))
    }

    private func musicCookies(expiresAt: Int) -> [String: String] {
        let json = #"{"access_token":"fake.music.jwt","token_type":"bearer","expires_in":3600,"expires_at":\#(expiresAt),"refresh_token":"fake-refresh","user":{"id":"fake-user"}}"#
        let encoded = "base64-" + Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let split = encoded.index(encoded.startIndex, offsetBy: encoded.count / 2)
        return ["sb-sb-auth-token.0": String(encoded[..<split]), "sb-sb-auth-token.1": String(encoded[split...])]
    }

    private func musicRows(expiresAt: Int) -> String {
        let cookies = musicCookies(expiresAt: expiresAt)
        return "[" + cookies.keys.sorted().map {
            #"{"name":"\#($0)","host":"www.flowmusic.app","value":"\#(cookies[$0]!)","encrypted":""}"#
        }.joined(separator: ",") + "]"
    }
}

private final class FlowTestSQLite: SQLiteValueReading, @unchecked Sendable {
    let google: String
    let flow: String
    let music: String
    let stitch: String
    let notebookLM: String
    private let lock = NSLock()
    private var reads: [(path: String, sql: String)] = []
    private var statements: [String] = []
    var queries: [String] { lock.withLock { reads.map(\.sql) } }
    var paths: [String] { lock.withLock { reads.map(\.path) } }
    var writes: [String] { lock.withLock { statements } }
    init(google: String, flow: String = "[]", music: String, stitch: String = "[]", notebookLM: String = "[]") {
        self.google = google
        self.flow = flow
        self.music = music
        self.stitch = stitch
        self.notebookLM = notebookLM
    }
    func queryValue(path: String, sql: String) throws -> String? {
        lock.withLock { reads.append((path, sql)) }
        if sql.contains("FROM meta") { return "24" }
        if sql.contains("flowmusic") { return music }
        if sql.contains("flow.google.com") { return flow }
        if sql.contains("stitch.google.com") { return stitch }
        if sql.contains("notebook.google.com") { return notebookLM }
        return google
    }
    func execute(path: String, sql: String) throws { lock.withLock { statements.append(sql) } }
}
