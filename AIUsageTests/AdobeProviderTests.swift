import XCTest
@testable import AIUsage

final class AdobeProviderTests: XCTestCase {
    private let sampleBalanceJSON = """
    {
      "total": {
        "quota": {
          "total": 4000,
          "used": 0,
          "available": 4000
        },
        "planCap": "HARD",
        "availableUntil": "2026-12-04T05:12:58.886Z"
      },
      "credits": {
        "firefly_plan_credit": {
          "quota": {
            "total": 4000,
            "used": 0,
            "available": 4000
          }
        }
      }
    }
    """

    private let sampleJWT = "header.eyJlbWFpbCI6InVzZXJAZXhhbXBsZS5jb20iLCJzdWIiOiIxMjM0NTY3OCJ9.signature"

    func testAdobeMappingWithTotalAndFireflyQuotas() throws {
        let data = Data(sampleBalanceJSON.utf8)
        let now = Date()
        let snapshot = try AdobeProvider.map(
            data: data,
            accessToken: sampleJWT,
            credentialSource: "Edge Default",
            now: now
        )

        XCTAssertEqual(snapshot.provider, .adobe)
        XCTAssertEqual(snapshot.planName, "Creative Cloud")
        XCTAssertEqual(snapshot.credentialSource, "Edge Default")
        XCTAssertEqual(snapshot.accountEmail, "user@example.com")
        XCTAssertEqual(snapshot.windows.count, 2)

        // 1. Monthly (Total Generative Credits)
        let monthly = snapshot.windows[0]
        XCTAssertEqual(monthly.kind, .monthly)
        XCTAssertEqual(monthly.usedPercent, 0)
        XCTAssertEqual(monthly.remainingCount, 4000)
        XCTAssertEqual(monthly.limitCount, 4000)
        XCTAssertNotNil(monthly.resetsAt)
        XCTAssertEqual(monthly.countText(for: .remaining), "4,000 / 4,000")
        XCTAssertEqual(monthly.countText(for: .used), "0 / 4,000")

        // 2. Firefly Plan Credits
        let firefly = snapshot.windows[1]
        XCTAssertEqual(firefly.kind, .firefly)
        XCTAssertEqual(firefly.usedPercent, 0)
        XCTAssertEqual(firefly.remainingCount, 4000)
        XCTAssertEqual(firefly.limitCount, 4000)
        XCTAssertNotNil(firefly.resetsAt)
        XCTAssertEqual(firefly.countText(for: .remaining), "4,000 / 4,000")
        XCTAssertEqual(firefly.countText(for: .used), "0 / 4,000")
    }

    func testAdobeMappingWithPartialUsageCalculatesCorrectPercentages() throws {
        let json = """
        {
          "total": {
            "quota": {
              "total": 4000,
              "used": 1000,
              "available": 3000
            },
            "availableUntil": "2026-12-04T05:12:58.886Z"
          },
          "credits": {
            "firefly_plan_credit": {
              "quota": {
                "total": 4000,
                "used": 2000,
                "available": 2000
              }
            }
          }
        }
        """
        let data = Data(json.utf8)
        let snapshot = try AdobeProvider.map(
            data: data,
            accessToken: sampleJWT,
            credentialSource: "Chrome Default",
            now: Date()
        )

        XCTAssertEqual(snapshot.windows.count, 2)

        let monthly = snapshot.windows[0]
        XCTAssertEqual(monthly.kind, .monthly)
        XCTAssertEqual(monthly.usedPercent, 25.0)
        XCTAssertEqual(monthly.remainingCount, 3000)
        XCTAssertEqual(monthly.limitCount, 4000)
        XCTAssertEqual(monthly.countText(for: .remaining), "3,000 / 4,000")
        XCTAssertEqual(monthly.countText(for: .used), "1,000 / 4,000")

        let firefly = snapshot.windows[1]
        XCTAssertEqual(firefly.kind, .firefly)
        XCTAssertEqual(firefly.usedPercent, 50.0)
        XCTAssertEqual(firefly.remainingCount, 2000)
        XCTAssertEqual(firefly.limitCount, 4000)
        XCTAssertEqual(firefly.countText(for: .remaining), "2,000 / 4,000")
        XCTAssertEqual(firefly.countText(for: .used), "2,000 / 4,000")
    }

    func testAdobeFetchSuccessFlow() async throws {
        let authHTML = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta http-equiv="refresh" content="0;url=https://account.adobe.com#access_token=\(sampleJWT)&token_type=bearer&expires_in=86399">
        </head>
        </html>
        """
        let authResponse = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            body: Data(authHTML.utf8)
        )
        let balanceResponse = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(sampleBalanceJSON.utf8)
        )

        let http = MockHTTPClient([authResponse, balanceResponse])
        let provider = AdobeProvider(
            http: http,
            cookies: { ("ims_sid=valid-session-id", "Edge Default") },
            dateProvider: { Date() }
        )

        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.provider, .adobe)
        XCTAssertEqual(snapshot.accountEmail, "user@example.com")
        XCTAssertEqual(snapshot.windows.count, 2)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)

        // 1st request: Silent auth GET to IMS
        let authReq = requests[0]
        XCTAssertEqual(authReq.method, .get)
        XCTAssertEqual(authReq.url.host, "adobeid-na1.services.adobe.com")
        XCTAssertEqual(authReq.headers["Cookie"], "ims_sid=valid-session-id")

        // 2nd request: Balance GET to firefly
        let balReq = requests[1]
        XCTAssertEqual(balReq.method, .get)
        XCTAssertEqual(balReq.url.host, "firefly.adobe.io")
        XCTAssertEqual(balReq.headers["Authorization"], "Bearer \(sampleJWT)")
        XCTAssertEqual(balReq.headers["x-api-key"], "SunbreakWebUI1")
    }

    func testAdobeAuthFailureThrowsAuthenticationError() async {
        let errorHTML = "<html><body>error=login_required</body></html>"
        let authResponse = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            body: Data(errorHTML.utf8)
        )

        let http = MockHTTPClient([authResponse])
        let provider = AdobeProvider(
            http: http,
            cookies: { ("ims_sid=expired-session", "Edge Default") }
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication error")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAdobeBalance401ThrowsAuthenticationError() async {
        let authHTML = #"<meta http-equiv="refresh" content="0;url=https://account.adobe.com#access_token=\#(sampleJWT)">"#
        let authResponse = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            body: Data(authHTML.utf8)
        )
        let balanceResponse = HTTPResponse(
            statusCode: 401,
            headers: [:],
            body: Data("{\"error\":\"invalid_token\"}".utf8)
        )

        let http = MockHTTPClient([authResponse, balanceResponse])
        let provider = AdobeProvider(
            http: http,
            cookies: { ("ims_sid=valid-session", "Edge Default") }
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication error on 401 balance")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTokenExtractionFromLocationHeader() {
        let response = HTTPResponse(
            statusCode: 302,
            headers: ["Location": "https://account.adobe.com#access_token=header-token&token_type=bearer"],
            body: Data()
        )
        XCTAssertEqual(AdobeProvider.extractAccessToken(from: response), "header-token")
    }

    func testTokenExtractionFromHTMLMetaTag() {
        let html = #"<meta http-equiv="refresh" content="0;url=https://account.adobe.com#access_token=meta-token&token_type=bearer">"#
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(html.utf8)
        )
        XCTAssertEqual(AdobeProvider.extractAccessToken(from: response), "meta-token")
    }

    func testMissingFireflyPlanRendersInactiveFireflyGraySlot() throws {
        let json = """
        {
          "total": {
            "quota": {"total": 25, "used": 5, "available": 20},
            "availableUntil": "2026-12-01T00:00:00Z"
          }
        }
        """
        let snapshot = try AdobeProvider.map(
            data: Data(json.utf8),
            accessToken: sampleJWT,
            credentialSource: "Edge Default",
            now: Date()
        )
        XCTAssertEqual(snapshot.windows.map(\.kind), [.monthly, .firefly])
        XCTAssertFalse(snapshot.windows[0].isInactive)
        XCTAssertTrue(snapshot.windows[1].isInactive)
        XCTAssertEqual(snapshot.windows[1].inactiveDetail, "No Firefly plan")
        XCTAssertEqual(snapshot.availableMenuBarItems.map(\.metric), [.monthly])
    }

    func testMapsAdditionalCreditPoolsPlanCapAndDetailsOnlyResponse() throws {
        let multiJSON = """
        {
          "total": {
            "quota": {"total": 4000, "used": 1000, "available": 3000},
            "planCap": "SOFT",
            "availableUntil": "2026-12-04T05:12:58.886Z"
          },
          "credits": {
            "firefly_plan_credit": {"quota": {"total": 4000, "used": 0, "available": 4000}},
            "video_bonus_credit": {"quota": {"total": 500, "used": 100, "available": 400}},
            "promo_gift_credit": {"quota": {"available": 150}}
          }
        }
        """
        let multi = try AdobeProvider.map(
            data: Data(multiJSON.utf8),
            accessToken: sampleJWT,
            credentialSource: "Edge Default",
            now: Date()
        )
        XCTAssertEqual(multi.windows.map(\.kind), [
            .monthly,
            .firefly,
            .additional(id: "adobe.video_bonus_credit", title: "Video Bonus Credit")
        ])
        XCTAssertEqual(multi.windows[2].remainingCount, 400)
        XCTAssertEqual(multi.windows[2].limitCount, 500)
        XCTAssertEqual(multi.usageDetails, [
            ProviderUsageDetail(id: "adobe.promo_gift_credit.credits", title: "Promo Gift Credit", value: "150 credits"),
            ProviderUsageDetail(id: "adobe.plan_cap", title: "Credit cap", value: "Soft")
        ])

        let detailsOnlyJSON = """
        {
          "credits": {
            "promo_gift_credit": {"quota": {"available": 25}}
          }
        }
        """
        let detailsOnly = try AdobeProvider.map(
            data: Data(detailsOnlyJSON.utf8),
            accessToken: sampleJWT,
            credentialSource: "Edge Default",
            now: Date()
        )
        XCTAssertTrue(detailsOnly.windows.isEmpty)
        XCTAssertTrue(detailsOnly.hasPanelContent)
        XCTAssertEqual(detailsOnly.usageDetails.first?.value, "25 credits")
    }
}
