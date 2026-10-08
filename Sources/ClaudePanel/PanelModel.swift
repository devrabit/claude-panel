import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PanelModel {
  var servers: [McpServer] = []
  var isChecking = false
  var checkedAt: Date?
  var error: String?
  var projects: [URL] = []
  var projectURL: URL
  var isOpen = false
  var showBubble = false
  var tab: PanelTab = .mcp
  var tokenSnapshot: TokenSnapshot?
  var isLoadingTokens = false
  var adoptionSnapshot: AdoptionSnapshot?
  var isLoadingAdoption = false
  var important: Set<String>

  private var userPath: String?
  private var refreshTask: Task<Void, Never>?

  init() {
    let stored = UserDefaults.standard.string(forKey: Keys.project)
    let found = ClaudeLocator.projects()
    projects = found
    if let stored, found.contains(where: { $0.path == stored }) {
      projectURL = URL(fileURLWithPath: stored, isDirectory: true)
    } else if let first = found.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".mcp.json").path) }) ?? found.first {
      projectURL = first
    } else {
      projectURL = FileManager.default.homeDirectoryForCurrentUser
    }
    important = Set(UserDefaults.standard.stringArray(forKey: Keys.important) ?? [])
  }

  var projectTitle: String {
    projectURL.lastPathComponent
  }

  var summary: String {
    let connected = count(.connected)
    let auth = count(.auth)
    let failed = count(.failed)
    let pending = count(.pending)
    var parts = ["\(connected) conectados", "\(auth) login", "\(failed) fallaron"]
    if pending > 0 { parts.append("\(pending) pendientes") }
    return parts.joined(separator: " · ")
  }

  var checkedLabel: String {
    guard let checkedAt else { return "Sin revisar todavía" }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return "Última revisión \(formatter.string(from: checkedAt))"
  }

  var contentHeight: CGFloat {
    if tab == .tokens { return 640 }
    if tab == .adoption { return 620 }
    let rows = servers.reduce(CGFloat(0)) { total, server in
      total + (server.reason == nil ? 46 : 68)
    }
    let sections: CGFloat = attention.isEmpty || connected.isEmpty ? 0 : 28
    let body = min(480, max(72, rows + sections + 12))
    let banner: CGFloat = error == nil ? 0 : 36
    return 168 + body + banner
  }

  var attention: [McpServer] {
    servers.filter { $0.health != .connected }
  }

  var connected: [McpServer] {
    servers.filter { $0.health == .connected }
  }

  func select(project: URL) {
    projectURL = project
    UserDefaults.standard.set(project.path, forKey: Keys.project)
    refresh()
  }

  var badge: McpHealth? {
    if servers.contains(where: { $0.health == .failed }) { return .failed }
    if servers.contains(where: { $0.health == .auth || $0.health == .pending }) { return .auth }
    if servers.contains(where: { $0.health == .connected }) { return .connected }
    return nil
  }

  func selectTab(_ next: PanelTab) {
    tab = next
    if next == .tokens, tokenSnapshot == nil {
      loadTokens()
    }
    if next == .adoption, adoptionSnapshot == nil {
      loadAdoption()
    }
  }

  func loadTokens() {
    guard !isLoadingTokens else { return }
    isLoadingTokens = true
    Task {
      let snapshot = await Task.detached(priority: .utility) {
        TokenLog.load()
      }.value
      tokenSnapshot = snapshot
      isLoadingTokens = false
    }
  }

  func loadAdoption() {
    guard !isLoadingAdoption else { return }
    isLoadingAdoption = true
    Task {
      let snapshot = await Task.detached(priority: .utility) {
        AdoptionLog.load()
      }.value
      adoptionSnapshot = snapshot
      isLoadingAdoption = false
    }
  }

  var localUserName: String {
    let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    if !full.isEmpty { return full }
    return NSUserName()
  }

  func isImportant(_ name: String) -> Bool {
    important.contains(name)
  }

  func toggleImportant(_ name: String) {
    if important.contains(name) {
      important.remove(name)
    } else {
      important.insert(name)
    }
    UserDefaults.standard.set(important.sorted(), forKey: Keys.important)
  }

  func dismissBubble() {
    showBubble = false
  }

  func refresh() {
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      await self?.performRefresh()
      self?.refreshTask = nil
    }
  }

  private func count(_ health: McpHealth) -> Int {
    servers.filter { $0.health == health }.count
  }

  private func performRefresh() async {
    isChecking = true
    error = nil
    defer { isChecking = false }

    guard let binary = ClaudeLocator.binary() else {
      error = "No encontré Claude Code en esta Mac."
      return
    }

    if userPath == nil {
      userPath = await Task.detached(priority: .utility) {
        ClaudeLocator.loginPath()
      }.value
    }

    let cwd = projectURL
    let executable = binary.path
    let path = userPath

    let result = await Task.detached(priority: .userInitiated) {
      var env = ProcessInfo.processInfo.environment
      if let path { env["PATH"] = path }
      return ClaudeLocator.run(
        executable: executable,
        arguments: ["mcp", "list"],
        cwd: cwd,
        environment: env,
        timeout: 90
      )
    }.value

    if result.timedOut {
      error = "La revisión superó 90 segundos."
      return
    }

    let parsed = McpListParser.parse(result.stdout)
    if parsed.isEmpty {
      let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      error = message.isEmpty ? "claude mcp list no devolvió servidores (código \(result.code))." : message
      return
    }

    servers = parsed
    checkedAt = Date()
    showBubble = hasInactiveImportant()
  }

  private func hasInactiveImportant() -> Bool {
    important.contains { name in
      guard let server = servers.first(where: { $0.name == name }) else { return true }
      return server.health != .connected
    }
  }
}

enum PanelTab {
  case mcp
  case tokens
  case adoption
}

private enum Keys {
  static let project = "claude-panel.project"
  static let frame = "claude-panel.frame"
  static let important = "claude-panel.important"
}

enum PanelFrameStore {
  static func saved() -> NSRect? {
    guard let raw = UserDefaults.standard.string(forKey: "claude-panel.frame") else { return nil }
    let rect = NSRectFromString(raw)
    guard rect.width > 40, rect.height > 40 else { return nil }
    let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    return visible ? rect : nil
  }

  static func save(_ rect: NSRect) {
    UserDefaults.standard.set(NSStringFromRect(rect), forKey: "claude-panel.frame")
  }
}
