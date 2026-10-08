import Foundation

struct PeriodAdoption: Sendable {
  var sessions: Int
  var activitySeconds: Int
  var accepts: Int
  var decisions: Int
  var activeDays: Int

  var acceptancePercent: Int? {
    guard decisions > 0 else { return nil }
    return Int((Double(accepts) / Double(decisions) * 100).rounded())
  }

  static let empty = PeriodAdoption(sessions: 0, activitySeconds: 0, accepts: 0, decisions: 0, activeDays: 0)
}

struct AdoptionSnapshot: Sendable {
  var week: PeriodAdoption
  var month: PeriodAdoption
  var checkedAt: Date

  static let empty = AdoptionSnapshot(week: .empty, month: .empty, checkedAt: .distantPast)
}

enum AdoptionLog {
  private static let idleGap: TimeInterval = 5 * 60

  static func load(now: Date = Date()) -> AdoptionSnapshot {
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
    let start7 = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    let start30 = calendar.date(byAdding: .day, value: -30, to: now) ?? now

    var stamps7: [String: [Date]] = [:]
    var stamps30: [String: [Date]] = [:]
    var sessions7 = Set<String>()
    var sessions30 = Set<String>()
    var days7 = Set<Date>()
    var days30 = Set<Date>()
    var accepts7 = 0
    var decisions7 = 0
    var accepts30 = 0
    var decisions30 = 0

    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in text.split(whereSeparator: \.isNewline) {
        let isUser = line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")
        let isAssistant = line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"")
        guard isUser || isAssistant else { continue }
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp),
              let sessionId = object["sessionId"] as? String
        else { continue }

        if date >= start30 {
          stamps30[sessionId, default: []].append(date)
        }
        if date >= start7 {
          stamps7[sessionId, default: []].append(date)
        }

        if isUser, object["promptId"] != nil, object["isSidechain"] as? Bool != true {
          if date >= start30 {
            sessions30.insert(sessionId)
            days30.insert(calendar.startOfDay(for: date))
          }
          if date >= start7 {
            sessions7.insert(sessionId)
            days7.insert(calendar.startOfDay(for: date))
          }
        }

        if let decision = (object["permissionDecision"] as? [String: Any])?["decision"] as? String {
          if date >= start30 {
            decisions30 += 1
            if decision == "accept" { accepts30 += 1 }
          }
          if date >= start7 {
            decisions7 += 1
            if decision == "accept" { accepts7 += 1 }
          }
        }
      }
    }

    return AdoptionSnapshot(
      week: PeriodAdoption(
        sessions: sessions7.count,
        activitySeconds: activitySeconds(stamps7),
        accepts: accepts7,
        decisions: decisions7,
        activeDays: days7.count
      ),
      month: PeriodAdoption(
        sessions: sessions30.count,
        activitySeconds: activitySeconds(stamps30),
        accepts: accepts30,
        decisions: decisions30,
        activeDays: days30.count
      ),
      checkedAt: now
    )
  }

  private static func activitySeconds(_ stamps: [String: [Date]]) -> Int {
    var total: TimeInterval = 0
    for dates in stamps.values {
      let sorted = dates.sorted()
      for pair in zip(sorted, sorted.dropFirst()) {
        let gap = pair.1.timeIntervalSince(pair.0)
        if gap > 0, gap <= idleGap {
          total += gap
        }
      }
    }
    return Int(total.rounded())
  }
}

enum ActivityFormat {
  static func duration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let rest = minutes % 60
    if rest == 0 { return "\(hours) h" }
    return "\(hours) h \(rest) min"
  }
}
