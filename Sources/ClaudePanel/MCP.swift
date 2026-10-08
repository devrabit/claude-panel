import Foundation

enum McpHealth: String, Codable {
  case connected
  case auth
  case failed
  case pending
  case unknown
}

struct McpServer: Identifiable, Equatable {
  var id: String { name }
  var name: String
  var health: McpHealth
  var detail: String

  var statusLabel: String {
    switch health {
    case .connected: "Conectado"
    case .auth: "Requiere login"
    case .failed: "Falló"
    case .pending: "Pendiente"
    case .unknown: "Desconocido"
    }
  }

  var reason: String? {
    guard health == .failed || health == .unknown else { return nil }
    var text = detail
    let prefixes = [
      "Failed to connect — ",
      "Failed to connect – ",
      "Failed to connect - ",
      "Failed to connect: ",
    ]
    for prefix in prefixes where text.hasPrefix(prefix) {
      text = String(text.dropFirst(prefix.count))
      break
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum McpListParser {
  private static let pattern = #"^(.+?): (.+) - ([✔✓✗✘!⏸])\s*(.*)$"#

  static func parse(_ stdout: String) -> [McpServer] {
    let cleaned = stripANSI(stdout)
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    var servers: [McpServer] = []
    for raw in cleaned.split(whereSeparator: \.isNewline) {
      let text = String(raw).trimmingCharacters(in: .whitespaces)
      let range = NSRange(text.startIndex..., in: text)
      guard let match = regex.firstMatch(in: text, options: [], range: range),
            let nameRange = Range(match.range(at: 1), in: text),
            let markRange = Range(match.range(at: 3), in: text),
            let detailRange = Range(match.range(at: 4), in: text)
      else { continue }
      let health = health(for: String(text[markRange]))
      servers.append(
        McpServer(
          name: String(text[nameRange]),
          health: health,
          detail: String(text[detailRange]).trimmingCharacters(in: .whitespaces)
        )
      )
    }
    return servers.sorted(by: sort)
  }

  static func health(for mark: String) -> McpHealth {
    switch mark {
    case "✔", "✓": .connected
    case "!": .auth
    case "✗", "✘": .failed
    case "⏸": .pending
    default: .unknown
    }
  }

  private static let order: [McpHealth] = [.failed, .auth, .pending, .unknown, .connected]

  private static func sort(_ lhs: McpServer, _ rhs: McpServer) -> Bool {
    let left = order.firstIndex(of: lhs.health) ?? order.count
    let right = order.firstIndex(of: rhs.health) ?? order.count
    if left != right { return left < right }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }

  static func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\u{1B}\[[0-9;]*[A-Za-z]"#,
      with: "",
      options: .regularExpression
    )
  }
}

struct CommandResult {
  var stdout: String
  var stderr: String
  var code: Int32
  var timedOut: Bool
}

enum ClaudeLocator {
  static func binary() -> URL? {
    let base = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
    guard let versions = try? FileManager.default.contentsOfDirectory(
      at: base,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return nil }

    let ranked = versions
      .filter { $0.lastPathComponent.first?.isNumber == true }
      .sorted { compareVersions($0.lastPathComponent, $1.lastPathComponent) }

    var found: [(url: URL, modified: Date)] = []
    for version in ranked {
      guard let hashes = try? FileManager.default.contentsOfDirectory(
        at: version,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ) else { continue }
      for hash in hashes {
        let bin = hash.appendingPathComponent("claude.app/Contents/MacOS/claude")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { continue }
        let modified = (try? bin.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        found.append((bin, modified))
      }
    }
    return found.max { $0.modified < $1.modified }?.url
  }

  static func projects() -> [URL] {
    let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    guard let data = try? Data(contentsOf: config),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let projects = root["projects"] as? [String: Any]
    else { return [] }

    return projects.keys.compactMap { path in
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    .sorted { lhs, rhs in
      mcpStamp(lhs) > mcpStamp(rhs)
    }
  }

  static func loginPath() -> String {
    let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let result = run(
      executable: shell,
      arguments: ["-lic", "printf %s \"$PATH\""],
      cwd: nil,
      environment: nil,
      timeout: 8
    )
    let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.code == 0, path.contains("/"), !path.contains("\n") else { return fallback }
    return path
  }

  static func run(
    executable: String,
    arguments: [String],
    cwd: URL?,
    environment: [String: String]?,
    timeout: TimeInterval
  ) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    if let environment { process.environment = environment }
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    do {
      try process.run()
    } catch {
      return CommandResult(stdout: "", stderr: error.localizedDescription, code: 1, timedOut: false)
    }

    let timedOut = TimedFlag()
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
      if process.isRunning {
        timedOut.value = true
        process.terminate()
      }
    }
    timer.resume()

    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()

    return CommandResult(
      stdout: String(data: stdout, encoding: .utf8) ?? "",
      stderr: String(data: stderr, encoding: .utf8) ?? "",
      code: process.terminationStatus,
      timedOut: timedOut.value
    )
  }

  private static func mcpStamp(_ url: URL) -> Date {
    let mcp = url.appendingPathComponent(".mcp.json")
    let values = try? mcp.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate ?? .distantPast
  }

  private static func compareVersions(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(left.count, right.count)
    for index in 0..<count {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l != r { return l < r }
    }
    return lhs < rhs
  }
}

private final class TimedFlag: @unchecked Sendable {
  var value = false
}
