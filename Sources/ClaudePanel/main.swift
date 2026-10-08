import AppKit
import SwiftUI

@main
struct ClaudePanelMain {
  static func main() {
    if CommandLine.arguments.contains("--adoption-test") {
      let snapshot = AdoptionLog.load()
      print("7 sessions \(snapshot.week.sessions) time \(snapshot.week.activitySeconds) accept \(snapshot.week.accepts)/\(snapshot.week.decisions) days \(snapshot.week.activeDays)")
      print("30 sessions \(snapshot.month.sessions) time \(snapshot.month.activitySeconds) accept \(snapshot.month.accepts)/\(snapshot.month.decisions) days \(snapshot.month.activeDays)")
      return
    }

    if CommandLine.arguments.contains("--tokens-test") {
      let snapshot = TokenLog.load()
      print("out \(snapshot.output) in \(snapshot.input) turns \(snapshot.turns) sessions \(snapshot.sessionCount) days \(snapshot.days.count)")
      return
    }

    if CommandLine.arguments.contains("--self-test") {
      runSelfTest()
      return
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}

final class FloatPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let model = PanelModel()
  private var panel: NSPanel?
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var timer: Timer?
  private var isDragging = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    let panel = FloatPanel(
      contentRect: initialFrame(),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.delegate = self

    let host = NSHostingView(rootView: WidgetView(
      model: model,
      onOpen: { [weak self] in self?.setOpen(true) },
      onClose: { [weak self] in self?.setOpen(false) },
      onDragging: { [weak self] dragging in
        self?.isDragging = dragging
        if !dragging, let panel = self?.panel {
          PanelFrameStore.save(panel.frame)
        }
      }
    ))
    host.wantsLayer = true
    panel.contentView = host
    self.panel = panel
    applySize(animated: false)
    panel.orderFrontRegardless()

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let image = MascotImage.statusBar() {
      item.button?.image = image
    } else {
      item.button?.title = "MCP"
    }
    item.button?.target = self
    item.button?.action = #selector(statusClick)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    let menu = NSMenu()
    let showItem = NSMenuItem(title: "Mostrar", action: #selector(show), keyEquivalent: "")
    let refreshItem = NSMenuItem(title: "Actualizar", action: #selector(refreshFromMenu), keyEquivalent: "r")
    let quitItem = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
    for item in [showItem, refreshItem, quitItem] {
      item.target = self
      menu.addItem(item)
    }
    menu.insertItem(.separator(), at: 2)
    statusMenu = menu
    statusItem = item

    model.refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.model.refresh()
      }
    }

    watchSize()
  }

  func windowDidMove(_ notification: Notification) {
    guard let panel, !isDragging else { return }
    PanelFrameStore.save(panel.frame)
  }

  @objc private func statusClick() {
    if NSApp.currentEvent?.type == .rightMouseUp, let menu = statusMenu, let button = statusItem?.button {
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
      return
    }
    setOpen(!model.isOpen)
  }

  @objc private func show() {
    setOpen(true)
  }

  @objc private func refreshFromMenu() {
    model.refresh()
    setOpen(true)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func setOpen(_ open: Bool) {
    model.isOpen = open
    applySize(animated: true)
  }

  private func watchSize() {
    withObservationTracking {
      _ = model.contentHeight
      _ = model.isOpen
      _ = model.showBubble
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.applySize(animated: false)
        self?.watchSize()
      }
    }
  }

  private func applySize(animated: Bool) {
    guard let panel, !isDragging else { return }
    let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let open = model.isOpen
    let bubble = !open && model.showBubble
    panel.isMovableByWindowBackground = false
    let width = open ? WidgetMetrics.panelWidth : (bubble ? WidgetMetrics.alertWidth : WidgetMetrics.iconWindow)
    let height = open ? min(model.contentHeight, visible.height - 24) : (bubble ? WidgetMetrics.alertHeight : WidgetMetrics.iconWindow)

    var frame = panel.frame
    let anchorX = frame.maxX
    let anchorY = frame.maxY
    frame.size = NSSize(width: width, height: height)
    frame.origin.x = anchorX - width
    frame.origin.y = anchorY - height
    if frame.minX < visible.minX { frame.origin.x = visible.minX + 8 }
    if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width - 8 }
    if frame.minY < visible.minY { frame.origin.y = visible.minY + 8 }
    if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height - 8 }

    panel.hasShadow = open || bubble
    panel.contentView?.layer?.cornerRadius = open ? 18 : 0
    panel.contentView?.layer?.masksToBounds = open
    panel.setFrame(frame, display: true, animate: animated)
    PanelFrameStore.save(frame)
  }

  private func initialFrame() -> NSRect {
    let side = WidgetMetrics.iconWindow
    if let saved = PanelFrameStore.saved() {
      return NSRect(x: saved.maxX - side, y: saved.maxY - side, width: side, height: side)
    }
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSRect(x: screen.maxX - side - 18, y: screen.maxY - side - 18, width: side, height: side)
  }
}

private func runSelfTest() {
  let sample = """
  Checking MCP server health…

  claude.ai Claude Docs: https://example.com/mcp - ✔ Connected
  factoria: https://example.com/mcp (HTTP) - ! Needs authentication
  k6: docker run --rm -i grafana/mcp-k6:latest - ✘ Failed to connect — ENOENT: Executable not found in $PATH: "docker"
  ado: npx -y @azure-devops/mcp@next sistecredito -d core - ✔ Connected
  local: stdio - ⏸ Pending approval
  """
  let servers = McpListParser.parse(sample)
  precondition(servers.count == 5, "expected 5 servers, got \(servers.count)")
  precondition(servers[0].name == "k6" && servers[0].health == .failed)
  precondition(servers[0].reason == "ENOENT: Executable not found in $PATH: \"docker\"")
  precondition(servers.contains { $0.name == "factoria" && $0.health == .auth && $0.reason == nil })
  precondition(servers.contains { $0.name == "local" && $0.health == .pending })
  precondition(servers.filter { $0.health == .connected }.map(\.name) == ["ado", "claude.ai Claude Docs"])
  print("ok")
}
