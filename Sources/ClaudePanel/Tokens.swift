import Foundation

struct DayUsage: Identifiable, Sendable {
  var id: Date { day }
  var day: Date
  var input: Int
  var output: Int
  var turns: Int

  var total: Int { input + output }
}

struct ModelUsage: Identifiable, Sendable {
  var id: String { name }
  var name: String
  var tokens: Int
}

struct TokenSnapshot: Sendable {
  var days: [DayUsage]
  var models: [ModelUsage]
  var input: Int
  var output: Int
  var cacheWrite: Int
  var cacheRead: Int
  var turns: Int
  var sessionCount: Int
  var checkedAt: Date

  var total: Int { input + output }

  static let empty = TokenSnapshot(
    days: [],
    models: [],
    input: 0,
    output: 0,
    cacheWrite: 0,
    cacheRead: 0,
    turns: 0,
    sessionCount: 0,
    checkedAt: .distantPast
  )

  func range(daysBack: Int, now: Date = Date()) -> [DayUsage] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    return (0..<daysBack).reversed().map { offset in
      let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
      return days.first { calendar.isDate($0.day, inSameDayAs: day) }
        ?? DayUsage(day: day, input: 0, output: 0, turns: 0)
    }
  }

  func total(in days: [DayUsage]) -> Int {
    days.reduce(0) { $0 + $1.total }
  }

  func turns(in days: [DayUsage]) -> Int {
    days.reduce(0) { $0 + $1.turns }
  }
}

enum TokenFormat {
  static func compact(_ value: Int) -> String {
    let number = Double(value)
    if value >= 1_000_000 {
      return String(format: "%.1f M", number / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }
    if value >= 1_000 {
      return String(format: "%.0f mil", number / 1_000)
    }
    return "\(value)"
  }
}

enum TokenLog {
  static func load(now: Date = Date()) -> TokenSnapshot {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return .empty }

    let calendar = Calendar.current
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]

    var byDay: [Date: (input: Int, output: Int, turns: Int)] = [:]
    var byModel: [String: Int] = [:]
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var turns = 0
    var sessions = 0

    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      sessions += 1
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in text.split(whereSeparator: \.isNewline) {
        let isAssistant = line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"")
        let isUser = line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")
        guard isAssistant || isUser else { continue }
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        let timestamp = object["timestamp"] as? String ?? ""
        let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) ?? now
        let day = calendar.startOfDay(for: date)

        if object["type"] as? String == "user",
           object["promptId"] != nil,
           object["isSidechain"] as? Bool != true {
          turns += 1
          var bucket = byDay[day] ?? (0, 0, 0)
          bucket.turns += 1
          byDay[day] = bucket
        }

        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { continue }

        let inTokens = integer(usage["input_tokens"])
        let outTokens = integer(usage["output_tokens"])
        let created = integer(usage["cache_creation_input_tokens"])
        let read = integer(usage["cache_read_input_tokens"])
        input += inTokens
        output += outTokens
        cacheWrite += created
        cacheRead += read

        let model = shortModel(message["model"] as? String ?? "otro")
        byModel[model, default: 0] += inTokens + outTokens

        var bucket = byDay[day] ?? (0, 0, 0)
        bucket.input += inTokens
        bucket.output += outTokens
        byDay[day] = bucket
      }
    }

    let days = byDay.map { DayUsage(day: $0.key, input: $0.value.input, output: $0.value.output, turns: $0.value.turns) }
      .sorted { $0.day < $1.day }
    let models = byModel.map { ModelUsage(name: $0.key, tokens: $0.value) }
      .sorted { $0.tokens > $1.tokens }

    return TokenSnapshot(
      days: days,
      models: models,
      input: input,
      output: output,
      cacheWrite: cacheWrite,
      cacheRead: cacheRead,
      turns: turns,
      sessionCount: sessions,
      checkedAt: now
    )
  }

  private static func integer(_ value: Any?) -> Int {
    switch value {
    case let number as Int: number
    case let number as NSNumber: number.intValue
    case let number as Double: Int(number)
    default: 0
    }
  }

  private static func shortModel(_ name: String) -> String {
    var text = name.hasPrefix("claude-") ? String(name.dropFirst(7)) : name
    if let range = text.range(of: #"-\d{8}$"#, options: .regularExpression) {
      text.removeSubrange(range)
    }
    return text
  }
}
