import AppKit
import SwiftTerm
import UserNotifications

/// One menu-bar icon, its dropdown window and its shell session.
@MainActor
final class Instance: NSObject {
  static let windowSize = NSSize(width: 760, height: 480)
  static let minSize = NSSize(width: 420, height: 200)
  static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  /// Stable for the instance: remembered folder, hotkey registration,
  /// notifications.
  let slot: Int
  /// Shown on the icon and used for the hotkey: its place from the left.
  private(set) var num: Int

  let statusItem: NSStatusItem
  let window: DropdownWindow
  let ui: InstanceView

  private var cwd: String
  /// What you sized it to; it shrinks to fit a smaller screen but comes back.
  private var size: NSSize
  /// Where you dragged it (its top-left corner); nil while it hangs under
  /// its icon.
  private var topLeft: NSPoint?
  private var pinned = false
  private var fontSize = Theme.defaultFontSize

  private var term: LocalProcessTerminalView?
  private var sessionID = 0
  private var exited = false
  private var tty: dev_t?
  private var dirTimer: Timer?

  /// Claude Code in this session.
  enum Activity { case idle, busy, waiting }
  private(set) var activity = Activity.idle
  private var unseen = false // it finished while you weren't looking
  private var open = false   // the window is showing (its icon fills in)
  private var spinFrame = 0
  private var spinTimer: Timer?
  private var waitTimer: Timer?

  private var hidePending = false
  private var holdOpen = false // a folder picker is up
  private var lastBlurHide = Date.distantPast

  private var app: AppDelegate { AppDelegate.shared }

  init(slot: Int) {
    self.slot = slot
    num = slot
    let saved = slot <= AppDelegate.maxSlots ? Store.shared.string("cwd.\(slot)") : nil
    var isDir: ObjCBool = false
    cwd = saved.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil } ?? homeDir
    size = (slot <= AppDelegate.maxSlots ? Store.shared.string("size.\(slot)") : nil).flatMap { s in
      let wh = s.split(separator: "x").compactMap { Double($0) }
      return wh.count == 2 ? NSSize(width: wh[0], height: wh[1]) : nil
    } ?? Self.windowSize
    topLeft = (slot <= AppDelegate.maxSlots ? Store.shared.string("pos.\(slot)") : nil).flatMap { s in
      let xy = s.split(separator: ",").compactMap { Double($0) }
      return xy.count == 2 ? NSPoint(x: xy[0], y: xy[1]) : nil
    }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    window = DropdownWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
    ui = InstanceView(frame: NSRect(origin: .zero, size: size))
    super.init()

    window.contentView = ui
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.level = .floating // above normal windows, like a popover
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // drop down on whatever Space is active
    window.delegate = self
    ui.docked = topLeft == nil
    ui.layoutSubtreeIfNeeded()

    if let b = statusItem.button {
      b.target = self
      b.action = #selector(statusClicked)
      b.sendAction(on: [.leftMouseUp, .rightMouseUp])
      b.imagePosition = .imageLeft
      b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    wireUI()
    refresh()
    startSession()
  }

  // ---- UI -----------------------------------------------------------------

  private func wireUI() {
    ui.folder.onClick = { [weak self] in self?.chooseFolder() }
    ui.pin.onClick = { [weak self] in self?.togglePinned() }
    ui.add.onClick = { [weak self] in self?.app.newInstance() }
    ui.restart.onClick = { [weak self] in self?.startSession() }
    ui.aboutClose.onClick = { [weak self] in self?.showAbout(false) }
    ui.about.onDismiss = { [weak self] in self?.showAbout(false) }
    ui.quitOk.onClick = { [weak self] in self?.quit(force: true) }
    ui.quitCancel.onClick = { [weak self] in self?.showQuitConfirm(nil) }
    ui.quit.onDismiss = { [weak self] in self?.showQuitConfirm(nil) }
    ui.onOpenURL = { NSWorkspace.shared.open($0) }
    ui.onDrop = { [weak self] in self?.dropped($0) }
    ui.onResize = { [weak self] in self?.resize($0, done: $1) }
    ui.onMove = { [weak self] in self?.move($0, done: $1) }
    ui.onDock = { [weak self] in self?.dock() }
    ui.aboutVersion.stringValue = "Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
  }

  /// Everything that shows the number, the hotkey, the state or the folder.
  func refresh() {
    ui.setBadge(num)
    ui.setHint(hotkeyLabel ?? "")
    ui.setPinned(pinned)
    window.title = "codebar \(num)"
    refreshTray()
  }

  var hotkeyLabel: String? {
    num <= AppDelegate.maxSlots ? app.modifiers.symbols + String(num) : nil
  }

  func setNumber(_ n: Int) {
    guard n != num else { return }
    num = n
    refresh()
  }

  private func refreshTray() {
    guard let b = statusItem.button else { return }
    let image = NSImage(systemSymbolName: open ? "apple.terminal.fill" : "apple.terminal", accessibilityDescription: "codebar")
    image?.isTemplate = true
    b.image = image
    b.title = " " + trayTitle
    b.toolTip = "codebar \(num) — \(folderName(cwd))"
  }

  private var trayTitle: String {
    switch activity {
    case .busy: return "\(num) \(Self.spinner[spinFrame])"
    case .waiting: return "\(num) ?"
    case .idle: return unseen ? "\(num) ✓" : String(num)
    }
  }

  @objc private func statusClicked() {
    let e = NSApp.currentEvent
    if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
      statusItem.menu = menu()
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
    } else {
      toggle()
    }
  }

  private func menu() -> NSMenu {
    let m = NSMenu()
    m.autoenablesItems = false
    let hk = hotkeyLabel.map { "   (\($0))" } ?? ""
    m.addItem(ActionItem("Show / Hide" + hk) { [weak self] in self?.toggle() })
    m.addItem(ActionItem("New Instance") { [weak self] in self?.app.newInstance() })
    m.addItem(.separator())
    m.addItem(ActionItem("Restart Session") { [weak self] in self?.startSession() })
    m.addItem(ActionItem("Keep Open When Unfocused", checked: pinned) { [weak self] in self?.togglePinned() })
    if topLeft != nil {
      m.addItem(ActionItem("Move Back Under Icon") { [weak self] in self?.dock() })
    }
    m.addItem(ActionItem("Notify When Claude Needs You", checked: app.notifyOn) { [weak self] in
      self?.app.setNotify(!(self?.app.notifyOn ?? true))
    })
    let hotkey = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
    hotkey.submenu = NSMenu()
    for mods in Modifiers.all {
      hotkey.submenu?.addItem(ActionItem("\(mods.symbols)1 … \(mods.symbols)9", checked: mods == app.modifiers) { [weak self] in
        self?.app.setModifiers(mods)
      })
    }
    m.addItem(hotkey)
    m.addItem(.separator())
    m.addItem(ActionItem("About codebar") { [weak self] in
      self?.showAbout(true)
      self?.show()
    })
    m.addItem(ActionItem(num > 1 ? "Quit Instance \(num)" : "Quit Instance") { [weak self] in
      if let self { self.app.remove(self) }
    })
    m.addItem(ActionItem("Quit All Instances") { NSApp.terminate(nil) })
    return m
  }

  private func togglePinned() {
    pinned.toggle()
    refresh()
    focusTerminal()
  }

  private func showAbout(_ show: Bool) {
    ui.about.isHidden = !show
    ui.needsLayout = true
    if !show { focusTerminal() }
  }

  /// While Claude is working or waiting on you, quitting asks first.
  private func quit(force: Bool) {
    if !force && activity != .idle {
      showQuitConfirm(activity)
    } else {
      app.remove(self)
    }
  }

  private func showQuitConfirm(_ activity: Activity?) {
    ui.quit.isHidden = activity == nil
    guard let activity else { return focusTerminal() }
    ui.quitMessage.stringValue = activity == .waiting
      ? "Claude is waiting for you in this session. Quitting ends it."
      : "Claude is still working in this session. Quitting stops it."
    ui.needsLayout = true
  }

  // ---- window -------------------------------------------------------------

  var looking: Bool { window.isVisible && window.isKeyWindow }

  func toggle() {
    if window.isVisible {
      hide()
    } else if Date().timeIntervalSince(lastBlurHide) > 0.3 {
      // (A click on the icon that just took the focus away already hid it.)
      show()
    }
  }

  func show() {
    setUnseen(false)
    place()
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.invalidateShadow()
    setOpen(true)
    focusTerminal()
  }

  func hide() {
    window.orderOut(nil)
    setOpen(false)
    // Hand the focus back to whatever had it, unless another of ours is up.
    if NSApp.isActive, !app.instances.contains(where: { $0.window.isVisible }) { NSApp.hide(nil) }
  }

  private func focusTerminal() {
    guard ui.about.isHidden, ui.quit.isHidden, let term else { return }
    window.makeFirstResponder(term)
  }

  private func setOpen(_ value: Bool) {
    guard open != value else { return }
    open = value
    refreshTray()
  }

  /// Centered under the icon, or where you dragged it; kept on its screen.
  private func place() {
    var size = NSSize(width: max(size.width, Self.minSize.width).rounded(),
                      height: max(size.height, Self.minSize.height).rounded())
    if let topLeft {
      return setFrame(onScreen(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)))
    }
    guard let item = statusItem.button?.window else {
      window.setContentSize(size)
      return window.center()
    }
    let f = item.frame
    let screen = item.screen ?? NSScreen.main
    if let s = screen {
      size.width = min(size.width, s.frame.width - 16)
      size.height = min(size.height, f.minY - 4 - s.visibleFrame.minY - 8)
    }
    var x = (f.midX - size.width / 2).rounded()
    if let s = screen {
      x = max(s.frame.minX + 8, min(x, s.frame.maxX - size.width - 8))
    }
    setFrame(NSRect(x: x, y: f.minY - 4 - size.height, width: size.width, height: size.height))
  }

  private func setFrame(_ f: NSRect) {
    window.setFrame(f, display: true)
    ui.layoutSubtreeIfNeeded()
    window.invalidateShadow()
  }

  /// Fits it inside the screen it's mostly on, below the menu bar.
  private func onScreen(_ f: NSRect) -> NSRect {
    func overlap(_ s: NSScreen) -> CGFloat {
      let i = s.visibleFrame.intersection(f)
      return i.isNull ? 0 : i.width * i.height
    }
    guard let s = (NSScreen.screens.max { overlap($0) < overlap($1) } ?? NSScreen.main)?.visibleFrame else { return f }
    var f = f
    f.size = NSSize(width: min(f.width, s.width), height: min(f.height, s.height))
    f.origin.x = max(s.minX, min(f.minX, s.maxX - f.width))
    f.origin.y = max(s.minY, min(f.maxY, s.maxY) - f.height)
    return f
  }

  /// Dragging an edge. On release it keeps the size it ended up at, for this
  /// slot, next time too.
  private func resize(_ frame: NSRect, done: Bool) {
    size = frame.size
    if topLeft == nil {
      place()
    } else {
      topLeft = NSPoint(x: frame.minX, y: frame.maxY)
      if done { place() } else { setFrame(frame) }
    }
    if done { saveFrame() }
  }

  /// Dragging the header takes it off its icon, to stay where you drop it
  /// (for this slot, next time too).
  private func move(_ origin: NSPoint, done: Bool) {
    topLeft = NSPoint(x: origin.x, y: origin.y + window.frame.height)
    ui.docked = false
    if done {
      place()
      saveFrame()
    } else {
      window.setFrameOrigin(origin)
    }
  }

  /// Back under its icon.
  private func dock() {
    guard topLeft != nil else { return }
    topLeft = nil
    ui.docked = true
    place()
    saveFrame()
  }

  private func saveFrame() {
    size = window.frame.size
    if topLeft != nil { topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY) }
    guard slot <= AppDelegate.maxSlots else { return }
    Store.shared.set("size.\(slot)", "\(Int(size.width))x\(Int(size.height))")
    Store.shared.set("pos.\(slot)", topLeft.map { "\(Int($0.x)),\(Int($0.y))" } ?? "")
  }

  var iconX: CGFloat { statusItem.button?.window?.frame.minX ?? 0 }

  // Popover behaviour: clicking elsewhere puts the terminal away. But dragging
  // a file out of Finder takes focus the moment the drag starts, so while the
  // mouse button is held we stay up as a drop target and decide on release.
  private func hideOnBlur() {
    guard !hidePending else { return }
    hidePending = true
    func check() {
      if !window.isKeyWindow && NSEvent.pressedMouseButtons & 1 != 0 {
        return after(0.1, check)
      }
      // A drop lands just after the release and refocuses us.
      after(0.15) { [self] in
        hidePending = false
        if !window.isKeyWindow && !pinned && !holdOpen && window.isVisible {
          lastBlurHide = Date()
          hide()
        }
      }
    }
    check()
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: cwd)
    panel.prompt = "Open"
    panel.message = "Restart this session in a folder"
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    holdOpen = true
    NSApp.activate(ignoringOtherApps: true)
    let result = panel.runModal()
    holdOpen = false
    show()
    if result == .OK, let url = panel.url { changeFolder(url.path) }
  }

  private func changeFolder(_ dir: String) {
    cwd = dir
    if slot <= AppDelegate.maxSlots { Store.shared.set("cwd.\(slot)", dir) }
    refreshTray()
    startSession()
  }

  /// Dropped files paste their paths, escaped the way Terminal.app does it.
  private func dropped(_ paths: [String]) {
    guard let term, !exited else { return }
    let text = paths.map {
      $0.replacingOccurrences(of: ##"[\s!"#$&'()*;<>?\[\\\]^`{|}~]"##, with: #"\\$0"#, options: .regularExpression)
    }.joined(separator: " ") + " "
    let bracketed = term.getTerminal().bracketedPasteMode
    term.send(txt: bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text)
    show()
  }

  // ---- keys ---------------------------------------------------------------

  /// Keys for the whole window; true when handled here.
  func handleKey(_ e: NSEvent) -> Bool {
    let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
    let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
    let enter = e.keyCode == 36 || e.keyCode == 76
    let esc = e.keyCode == 53

    if !ui.quit.isHidden {
      if enter { quit(force: true) } else if esc { showQuitConfirm(nil) }
      return true
    }
    // ⌘W quits this instance wherever the focus is.
    if mods == .command && key == "w" {
      quit(force: false)
      return true
    }
    if !ui.about.isHidden {
      if enter || esc { showAbout(false) }
      return true
    }
    if exited && !mods.contains(.command) {
      if enter { startSession() }
      return true
    }
    // Shift+Enter = newline in Claude Code (what /terminal-setup configures
    // elsewhere): send ESC+CR, the same as Option+Enter.
    if enter && mods == .shift {
      term?.send(txt: "\u{1b}\r")
      return true
    }
    guard mods.subtracting(.shift) == .command, let term else { return false }
    switch key {
    case "c": if term.selectionActive { term.copy(self) }
    case "v": term.paste(self)
    case "k": clear()
    case "n": app.newInstance()
    case "o": chooseFolder()
    case "=", "+": zoom(1)
    case "-": zoom(-1)
    case "0": zoom(0)
    default: return false
    }
    return true
  }

  private func zoom(_ dir: CGFloat) {
    fontSize = dir == 0 ? Theme.defaultFontSize : max(8, min(24, fontSize + dir))
    term?.font = Theme.terminalFont(size: fontSize)
  }

  /// Like xterm's clear(): the cursor's line moves to the top and everything
  /// above it, scrollback included, goes.
  private func clear() {
    guard let term else { return }
    let y = term.getTerminal().getCursorLocation().y
    if y > 0 { term.feed(text: "\u{1b}[\(y)S\u{1b}[\(y)A") }
    term.getTerminal().clearScrollback()
    term.needsDisplay = true
  }

  // ---- session ------------------------------------------------------------

  func startSession() {
    killSession()
    sessionID += 1
    exited = false
    tty = nil
    ui.showExited(nil)
    setActivity(.idle)

    let t = LocalProcessTerminalView(frame: ui.termBox.bounds, font: Theme.terminalFont(size: fontSize),
                                     options: TerminalOptions(scrollback: 10000))
    t.nativeBackgroundColor = Theme.bg
    t.nativeForegroundColor = Theme.text
    t.caretColor = Theme.accent
    t.selectedTextBackgroundColor = Theme.selection
    t.installColors(Theme.ansi.map {
      Color(red: UInt16(($0 >> 16) & 0xff) * 257, green: UInt16(($0 >> 8) & 0xff) * 257, blue: UInt16($0 & 0xff) * 257)
    })
    t.optionAsMetaKey = true
    t.processDelegate = self
    ui.setTerminal(t)
    term = t

    // A plain login shell. A custom command runs through the shell so PATH
    // from .zprofile/.zshrc applies.
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let args = app.command.map { ["-l", "-i", "-c", $0] } ?? ["-l"]
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "codebar"
    env["CODEBAR_INSTANCE"] = String(slot)
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    t.startProcess(executable: shell, args: args, environment: env.map { "\($0.key)=\($0.value)" },
                   currentDirectory: cwd)

    ui.setFolder(cwd)
    if window.isKeyWindow { focusTerminal() }
    dirTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
      MainActor.assumeIsolated { [weak self] in self?.followDirectory() }
    }
  }

  func killSession() {
    dirTimer?.invalidate()
    guard let t = term else { return }
    t.processDelegate = nil
    let pid = t.process.shellPid
    if t.process.running {
      kill(pid, SIGHUP)
      t.terminate()
      // Reap it once it's gone.
      DispatchQueue.global().async {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
      }
    }
  }

  /// The header follows `cd` (the remembered folder only changes with ⌘O).
  private func followDirectory() {
    guard let term, !exited, term.process.running,
          let dir = Pty.foregroundDirectory(master: term.process.childfd, fallback: term.process.shellPid)
    else { return }
    ui.setFolder(dir)
  }

  private func claudeStatus() -> ClaudeStatus? {
    guard let term, !exited, term.process.running else { return nil }
    if tty == nil { tty = Pty.device(master: term.process.childfd) }
    return tty.flatMap(Claude.status(tty:))
  }

  // ---- activity -----------------------------------------------------------

  private func onTitle(_ title: String) {
    if title.hasPrefix("\u{25D0}") || title.hasPrefix("\u{25D1}") { return setActivity(.busy) }
    // Any other title (Claude exited, the shell took over) clears the state.
    guard title.hasPrefix("\u{2733}") else { return setActivity(.idle) }
    // ✳ after ◐/◑: Claude stopped working, either done or waiting on you.
    if activity == .busy {
      settle(String(title.dropFirst()).trimmingCharacters(in: .whitespaces))
    }
  }

  /// The title changes on render and the session file is written just after,
  /// so give it a moment to catch up.
  private func settle(_ summary: String) {
    let session = sessionID
    setActivity(.idle)
    var delays = [0.1, 0.4, 1.0]
    func step() {
      after(delays.removeFirst()) { [self] in
        guard session == sessionID, activity == .idle else { return } // working again
        let st = claudeStatus()
        if st?.status == "busy" && !delays.isEmpty { return step() }
        if let st, st.isWaiting {
          setActivity(.waiting)
          needsYou(st.waitingFor)
        } else {
          finished(summary)
        }
      }
    }
    step()
  }

  private func setActivity(_ value: Activity) {
    guard value != activity else { return }
    activity = value
    spinTimer?.invalidate()
    spinTimer = nil
    waitTimer?.invalidate()
    waitTimer = nil
    if activity == .busy {
      spinTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
        MainActor.assumeIsolated { [weak self] in
          guard let self else { return }
          spinFrame = (spinFrame + 1) % Self.spinner.count
          refreshTray()
        }
      }
    }
    // While waiting, the title stays ✳ even if you dismiss the prompt, so
    // watch the file for Claude to move on.
    if activity == .waiting {
      waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        MainActor.assumeIsolated { [weak self] in
          guard let self, activity == .waiting else { return }
          let st = claudeStatus()
          if st?.isWaiting != true { setActivity(st?.status == "busy" ? .busy : .idle) }
        }
      }
    }
    refreshTray()
  }

  private func setUnseen(_ value: Bool) {
    guard value != unseen else { return }
    unseen = value
    refreshTray()
  }

  /// Claude finished a turn. If you weren't looking, mark the icon and post
  /// a notification.
  private func finished(_ summary: String) {
    guard !looking else { return }
    setUnseen(true)
    notify(summary.isEmpty ? "Claude finished and is waiting for you" : "Claude finished: \(summary)")
  }

  /// Claude stopped on a permission prompt or a question. The icon shows ?
  /// for as long as that lasts; the notification only goes out if you
  /// weren't looking.
  private func needsYou(_ waitingFor: String?) {
    guard !looking else { return }
    notify(waitingFor == "permission prompt" ? "Claude needs your permission"
      : waitingFor == "input needed" ? "Claude has a question for you"
      : "Claude is waiting for you")
  }

  /// Clicking the notification opens this instance.
  private func notify(_ body: String) {
    guard app.notifyOn else { return }
    let c = UNMutableNotificationContent()
    c.title = "codebar \(num) · \(folderName(cwd))"
    c.body = body
    c.sound = .default
    c.userInfo = ["slot": slot]
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "done:\(slot)", content: c, trigger: nil))
  }

  // ---- teardown -----------------------------------------------------------

  func teardown() {
    killSession()
    spinTimer?.invalidate()
    waitTimer?.invalidate()
    window.orderOut(nil)
    NSStatusBar.system.removeStatusItem(statusItem)
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["done:\(slot)"])
  }
}

extension Instance: NSWindowDelegate {
  func windowDidBecomeKey(_ notification: Notification) {
    setUnseen(false)
  }

  func windowDidResignKey(_ notification: Notification) {
    if !pinned && !holdOpen { hideOnBlur() }
  }
}

extension Instance: @preconcurrency LocalProcessTerminalViewDelegate {
  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    guard source === term else { return }
    onTitle(title)
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    guard source === term, let directory else { return }
    let path = directory.hasPrefix("file://") ? URL(string: directory)?.path : directory
    if let path, !path.isEmpty { ui.setFolder(path) }
  }

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    guard source === term, !exited else { return }
    exited = true
    dirTimer?.invalidate()
    setActivity(.idle)
    // A raw wait status: the low 7 bits are the signal, if any.
    var message = "Session ended"
    if let status = exitCode {
      let sig = status & 0x7f
      message += sig == 0 ? " (exit \((status >> 8) & 0xff))" : " (\(signalName(sig)))"
    }
    ui.showExited(message)
  }

  private func signalName(_ sig: Int32) -> String {
    let names: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 6: "SIGABRT", 9: "SIGKILL", 15: "SIGTERM"]
    return names[sig] ?? "signal \(sig)"
  }
}
