import Foundation

// Harness independiente: las Command Line Tools no incluyen XCTest.
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    precondition(actual == expected, "Esperado: \(expected); recibido: \(actual)")
}
private func XCTAssertTrue(_ value: Bool) { precondition(value) }
private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
private func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }

// El cliente usa únicamente estos campos del mensaje al construir la solicitud.
struct ChatMessage: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let text: String
}

@main
struct DeepSeekBillingTests {
    static func main() throws {
        let tests = Self()
        try tests.testCacheAndOutputPricesForBothModelsAndSchedules()
        try tests.testUnknownModelAndMissingOrInvalidUsageDoNotInventCosts()
        try tests.testStreamDecodesFinalUsageWithAndWithoutChoices()
        try tests.testBalancesKeepTheirCurrencyAndSmallAmountsRemainVisible()
        print("4 pruebas de facturación y consumo completadas correctamente.")
    }
    private func usage(_ json: String) throws -> DeepSeekUsage {
        try JSONDecoder().decode(DeepSeekUsage.self, from: Data(json.utf8))
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testCacheAndOutputPricesForBothModelsAndSchedules() throws {
        let tokens = try usage(#"{"prompt_tokens":1000000,"completion_tokens":1000000,"prompt_cache_hit_tokens":250000,"prompt_cache_miss_tokens":750000}"#)
        let peak = date("2026-10-19T01:00:00Z")
        let offPeak = date("2026-10-19T04:00:00Z")
        XCTAssertEqual(tokens.estimatedCost(model: "deepseek-flash", date: peak), Decimal(string: "1.4265"))
        XCTAssertEqual(tokens.estimatedCost(model: "deepseek-flash", date: offPeak), Decimal(string: "0.71325"))
        XCTAssertEqual(tokens.estimatedCost(model: "deepseek-v4-pro", date: peak), Decimal(string: "4.961"))
        XCTAssertEqual(tokens.estimatedCost(model: "deepseek-v4-pro", date: date("2026-10-18T02:00:00Z")), Decimal(string: "2.4805"))
        XCTAssertEqual(tokens.estimatedCost(model: "deepseek-flash", date: date("2026-10-19T06:00:00Z")), tokens.estimatedCost(model: "deepseek-flash", date: peak))
        XCTAssertEqual(tokens.estimatedCost(model: "deepseek-flash", date: date("2026-10-19T10:00:00Z")), tokens.estimatedCost(model: "deepseek-flash", date: offPeak))
    }

    func testUnknownModelAndMissingOrInvalidUsageDoNotInventCosts() throws {
        let missing = try usage(#"{"prompt_tokens":100,"completion_tokens":10}"#)
        XCTAssertNil(missing.estimatedCost(model: "deepseek-flash", date: Date()))
        let invalid = try usage(#"{"prompt_tokens":100,"completion_tokens":10,"prompt_cache_hit_tokens":150}"#)
        XCTAssertNil(invalid.estimatedCost(model: "deepseek-flash", date: Date()))
        let valid = try usage(#"{"prompt_tokens":100,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":20}}"#)
        XCTAssertNotNil(valid.estimatedCost(model: "deepseek-flash", date: Date()))
        XCTAssertNil(valid.estimatedCost(model: "future-model", date: Date()))
    }

    func testStreamDecodesFinalUsageWithAndWithoutChoices() throws {
        for choices in [#"[{"delta":{"content":"Hola"}}]"#, "[]"] {
            let data = Data("{\"choices\":\(choices),\"model\":\"deepseek-flash\",\"created\":1792371600,\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"prompt_cache_hit_tokens\":0,\"prompt_cache_miss_tokens\":100}}".utf8)
            let chunk = try JSONDecoder().decode(StreamChunk.self, from: data)
            XCTAssertEqual(chunk.usage?.completion_tokens, 20)
            XCTAssertEqual(chunk.usage?.cachedTokens, 0)
        }
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(#"{"choices":[{"delta":{"content":"Hola"}}],"usage":null}"#.utf8))
        XCTAssertNil(chunk.usage)
        XCTAssertEqual(chunk.choices.first?.delta.content, "Hola")
    }

    func testBalancesKeepTheirCurrencyAndSmallAmountsRemainVisible() throws {
        let data = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"4.12345678","granted_balance":"0","topped_up_balance":"4.12345678"},{"currency":"CNY","total_balance":"10","granted_balance":"2","topped_up_balance":"8"}]}"#.utf8)
        let balance = try JSONDecoder().decode(DeepSeekBalance.self, from: data)
        XCTAssertTrue(balance.summary.contains("USD"))
        XCTAssertTrue(balance.summary.contains("CNY"))
        XCTAssertTrue(balance.summary.contains("12345678"))
        XCTAssertTrue(BillingFormat.money(Decimal(string: "0.00000123")!, currency: "USD").contains("00000123"))
    }
}
