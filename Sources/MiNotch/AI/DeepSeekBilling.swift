import Foundation

struct DeepSeekBalance: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let currency: String
        let total_balance: String
        let granted_balance: String
        let topped_up_balance: String

        var formattedTotal: String {
            guard let amount = Decimal(string: total_balance, locale: Locale(identifier: "en_US_POSIX")) else {
                return "\(total_balance) \(currency)"
            }
            return BillingFormat.money(amount, currency: currency)
        }
    }

    let is_available: Bool
    let balance_infos: [Entry]

    var summary: String {
        balance_infos.map(\.formattedTotal).joined(separator: " · ")
    }
}

struct DeepSeekUsage: Decodable, Sendable {
    struct PromptDetails: Decodable, Sendable {
        let cached_tokens: Int?
    }

    let prompt_tokens: Int
    let completion_tokens: Int
    let prompt_cache_hit_tokens: Int?
    let prompt_cache_miss_tokens: Int?
    let prompt_tokens_details: PromptDetails?

    var cachedTokens: Int? {
        prompt_cache_hit_tokens ?? prompt_tokens_details?.cached_tokens
    }

    /// Precios USD por millón de tokens, verificados el 19/10/2026:
    /// https://api-docs.deepseek.com/quick_start/pricing/
    /// Estimación: el calendario local no contempla feriados públicos chinos.
    func estimatedCost(model: String, date: Date) -> Decimal? {
        guard let cached = cachedTokens, cached >= 0, cached <= prompt_tokens,
              completion_tokens >= 0 else { return nil }
        let missed = prompt_cache_miss_tokens ?? (prompt_tokens - cached)
        guard missed >= 0, cached + missed == prompt_tokens else { return nil }
        let rates: (Decimal, Decimal, Decimal)
        switch model {
        case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            rates = (Decimal(string: "0.006")!, Decimal(string: "0.3")!, Decimal(string: "1.2")!)
        case "deepseek-v4-pro":
            rates = (Decimal(string: "0.044")!, Decimal(string: "1.32")!, Decimal(string: "3.96")!)
        default:
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        let peak = (2...6).contains(weekday) && ((1..<4).contains(hour) || (6..<10).contains(hour))
        let total = Decimal(cached) * rates.0 + Decimal(missed) * rates.1 + Decimal(completion_tokens) * rates.2
        return total / 1_000_000 / (peak ? 1 : 2)
    }
}

struct ConsultationUsage: Sendable {
    let tokens: DeepSeekUsage
    let model: String
    let date: Date

    var costText: String {
        guard let cost = tokens.estimatedCost(model: model, date: date) else { return "Costo no disponible" }
        return "≈ \(BillingFormat.money(cost, currency: "USD"))"
    }

    var details: String {
        "\(model) · \(tokens.prompt_tokens) tokens de entrada (incluye historial), \(tokens.completion_tokens) de salida (incluye razonamiento). Costo estimado con tarifas del 19/10/2026; puede variar por feriados chinos o cambios de precios."
    }
}

enum BillingFormat {
    static func money(_ value: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "es_CR")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        let number = formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
        return "\(number) \(currency)"
    }
}
