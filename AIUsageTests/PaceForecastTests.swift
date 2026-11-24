import XCTest
@testable import AIUsage

final class PaceForecastTests: XCTestCase {
    func testSessionOnPaceToRunOutBeforeResetProjectsExhaustion() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3_600)
        let measured = start.addingTimeInterval(2 * 3_600)
        let window = QuotaWindow(
            kind: .session,
            usedPercent: 50,
            resetsAt: reset,
            startsAt: start
        )

        XCTAssertEqual(
            window.projectedExhaustion(measuredAt: measured),
            start.addingTimeInterval(4 * 3_600)
        )
    }

    func testSessionOnPaceToFinishAfterResetIsNotAtRisk() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3_600)
        let measured = start.addingTimeInterval(2 * 3_600)
        let window = QuotaWindow(
            kind: .session,
            usedPercent: 25,
            resetsAt: reset,
            startsAt: start
        )

        XCTAssertNil(window.projectedExhaustion(measuredAt: measured))
    }

    func testNoForecastAtZeroOrHundredPercent() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3_600)
        let measured = start.addingTimeInterval(2 * 3_600)

        for percent in [0.0, 100.0] {
            let window = QuotaWindow(
                kind: .session,
                usedPercent: percent,
                resetsAt: reset,
                startsAt: start
            )
            XCTAssertNil(window.projectedExhaustion(measuredAt: measured))
        }
    }

    func testNoForecastBeforeTenPercentOfWindowHasPassed() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3_600)
        let justBeforeThreshold = start.addingTimeInterval(5 * 3_600 * 0.1 - 1)
        let atThreshold = start.addingTimeInterval(5 * 3_600 * 0.1)
        let window = QuotaWindow(
            kind: .session,
            usedPercent: 50,
            resetsAt: reset,
            startsAt: start
        )

        XCTAssertNil(window.projectedExhaustion(measuredAt: justBeforeThreshold))
        XCTAssertNotNil(window.projectedExhaustion(measuredAt: atThreshold))
    }

    func testNoForecastAtOrAfterReset() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3_600)
        let window = QuotaWindow(
            kind: .session,
            usedPercent: 80,
            resetsAt: reset,
            startsAt: start
        )

        XCTAssertNil(window.projectedExhaustion(measuredAt: reset))
        XCTAssertNil(window.projectedExhaustion(measuredAt: reset.addingTimeInterval(60)))
    }

    func testNoForecastForWindowsOfOneDayOrLonger() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lengths: [TimeInterval] = [24 * 3_600, 7 * 86_400, 30 * 86_400]
        for length in lengths {
            let reset = start.addingTimeInterval(length)
            let measured = start.addingTimeInterval(length * 0.25)
            let window = QuotaWindow(
                kind: .weekly,
                usedPercent: 80,
                resetsAt: reset,
                startsAt: start
            )
            XCTAssertNil(window.projectedExhaustion(measuredAt: measured))
        }
    }

    func testNoForecastForInactiveUnlimitedOrMultiSeriesWindows() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3_600)
        let measured = start.addingTimeInterval(2 * 3_600)

        let inactive = QuotaWindow(kind: .session, usedPercent: 80, resetsAt: reset, startsAt: start, isInactive: true)
        let unlimited = QuotaWindow(kind: .session, usedPercent: 80, resetsAt: reset, startsAt: start, isUnlimited: true)
        let dual = QuotaWindow(
            kind: .session,
            usedPercent: 80,
            resetsAt: reset,
            startsAt: start,
            series: [
                QuotaSeriesReading(id: "a", title: "A", usedPercent: 80, resetsAt: reset),
                QuotaSeriesReading(id: "b", title: "B", usedPercent: 40, resetsAt: reset)
            ]
        )

        XCTAssertNil(inactive.projectedExhaustion(measuredAt: measured))
        XCTAssertNil(unlimited.projectedExhaustion(measuredAt: measured))
        XCTAssertNil(dual.projectedExhaustion(measuredAt: measured))
    }

    func testTimingPresentationFormatsOutCountdownAndStopsPastReset() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3_600)
        // 2h elapsed -> 2h / 0.8 = 2.5h total -> exhaustion at start + 2.5h (30m after measured)
        let measured = start.addingTimeInterval(2 * 3_600)
        let window = QuotaWindow(
            kind: .session,
            usedPercent: 80,
            resetsAt: reset,
            startsAt: start
        )

        let active = QuotaTimingPresentation(window: window, measuredAt: measured, now: measured)
        XCTAssertTrue(active.isAtRisk)
        XCTAssertEqual(active.compactText, "Out 30m")
        XCTAssertEqual(active.text, "Out 30m · Reset 3h 1m")
        XCTAssertEqual(active.accessibilityText, "runs out in 30m at this pace, Reset 3h 1m")

        let soon = QuotaTimingPresentation(
            window: window,
            measuredAt: measured,
            now: start.addingTimeInterval(2.5 * 3_600)
        )
        XCTAssertTrue(soon.isAtRisk)
        XCTAssertEqual(soon.compactText, "Out soon")
        XCTAssertEqual(soon.text, "Out soon · Reset 2h 30m")

        let pastReset = QuotaTimingPresentation(
            window: window,
            measuredAt: measured,
            now: reset.addingTimeInterval(60)
        )
        XCTAssertFalse(pastReset.isAtRisk)
        XCTAssertEqual(pastReset.text, "Resetting")
        XCTAssertEqual(pastReset.compactText, "Resetting")
    }

    func testMappersPopulateStartsAtForSessionWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset5h = now.addingTimeInterval(3 * 3_600)
        let start5h = reset5h.addingTimeInterval(-5 * 3_600)

        // Claude
        let claude = try ClaudeUsageMapper.map(
            response: httpResponse(json: """
            {"five_hour":{"utilization":60,"resets_at":\(reset5h.timeIntervalSince1970)}}
            """),
            credentials: ClaudeOAuth(accessToken: "t", refreshToken: nil, expiresAt: nil, subscriptionType: nil, rateLimitTier: nil, scopes: []),
            now: now
        )
        XCTAssertEqual(claude.sessionWindow?.startsAt, start5h)

        // Codex
        let codex = try CodexUsageMapper.map(
            response: httpResponse(json: """
            {"rate_limit":{"primary_window":{"used_percent":60,"limit_window_seconds":18000,"reset_at":\(reset5h.timeIntervalSince1970)}}}
            """),
            now: now
        )
        XCTAssertEqual(codex.sessionWindow?.startsAt, start5h)

        // Antigravity
        let agy = try XCTUnwrap(AntigravityUsageMapper.summary(
            [Data("""
            {"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.4,"resetTime":\(reset5h.timeIntervalSince1970)}]}]}
            """.utf8)],
            planName: nil,
            now: now
        ))
        XCTAssertEqual(agy.sessionWindow?.startsAt, start5h)

        // Z.ai
        let zai = try ZAIProvider.map(
            subscription: httpResponse(json: "{\"code\":200,\"data\":[]}"),
            quota: httpResponse(json: """
            {"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":60,"nextResetTime":\(Int(reset5h.timeIntervalSince1970 * 1_000))}]}}
            """),
            start: nil,
            auth: ZAICredential(token: "t", zcodeToken: nil, email: nil, source: "Z.ai")
        )
        XCTAssertEqual(zai.sessionWindow?.startsAt, start5h)

        // MiniMax
        let miniMax = try MiniMaxProvider.map(
            remains: httpResponse(json: """
            {"model_remains":[{"model_name":"general","current_interval_total_percent":100,"current_interval_used_percent":60,"start_time":\(Int(start5h.timeIntervalSince1970)),"end_time":\(Int(reset5h.timeIntervalSince1970))}]}
            """),
            now: now
        )
        XCTAssertEqual(miniMax.sessionWindow?.startsAt, start5h)

        // Kimi Code
        let reset5hISO = ISO8601DateFormatter().string(from: reset5h)
        let kimi = try ConsumerQuotaProvider.kimi(
            subscription: httpResponse(json: "{}"),
            stats: httpResponse(json: "{}"),
            code: httpResponse(json: """
            {"usages":[{"scope":"FEATURE_CODING","limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":100,"remaining":40,"resetTime":"\(reset5hISO)"}}]}]}
            """)
        )
        let kimiSession = try XCTUnwrap(kimi.windows.first { $0.kind.rawValue == "additional:kimi.code.FEATURE_CODING.5.0.TIME_UNIT_HOUR" })
        XCTAssertEqual(kimiSession.startsAt, start5h)
    }
}
