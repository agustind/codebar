import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static let maxSlots = 9
  /// <modifiers>+0 arranges them all; slots start at 1, so 0 is free.
  static let gridHotkey: UInt32 = 0
  static var shared: AppDelegate!

  private(set) var instances: [Instance] = []
  private(set) var modifiers = Modifiers.all[0]
  private(set) var notifyOn = true
  /// store.json key "command": run this instead of a plain shell.
  private(set) var command: String?

  private var renumberPending = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppDelegate.shared = self
    let store = Store.shared
    modifiers = Modifiers.all.first { $0.id == store.modifiers } ?? Modifiers.all[0]
    notifyOn = store.bool("notify") ?? true
    command = store.string("command").flatMap { $0.isEmpty ? nil : $0 }

    UNUserNotificationCenter.current().delegate = self
    if notifyOn { requestNotifications() }

    HotKeys.shared.onPress = { [weak self] id in
      guard let self else { return }
      if id == Self.gridHotkey {
        arrange()
      } else {
        instances.first { UInt32($0.slot) == id }?.toggle()
      }
    }
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
      let handled = MainActor.assumeIsolated {
        AppDelegate.shared.instances.first { $0.window === e.window }?.handleKey(e) ?? false
      }
      return handled ? nil : e
    }

    newInstance()
  }

  /// Opening the app again while it runs brings up the first terminal, if
  /// none is open.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard !instances.contains(where: { $0.window.isVisible }) else { return false }
    instances.min { $0.num < $1.num }?.show()
    return false
  }

  func applicationDidResignActive(_ notification: Notification) {
    updatePolicy()
  }

  func applicationWillTerminate(_ notification: Notification) {
    for inst in instances { inst.killSession() }
  }

  // ---- instances ----------------------------------------------------------

  /// A new icon (macOS puts it on the left) with its own terminal, which
  /// drops down once the icon has taken its place. It claims the lowest free
  /// slot, which picks its remembered folder.
  func newInstance() {
    let used = Set(instances.map(\.slot))
    let slot = (1...).first { !used.contains($0) }!
    let inst = Instance(slot: slot)
    instances.append(inst)
    NotificationCenter.default.addObserver(self, selector: #selector(iconMoved),
                                           name: NSWindow.didMoveNotification, object: inst.statusItem.button?.window)
    renumber()
    after(0.25) { [weak self, weak inst] in
      self?.renumber()
      inst?.show()
    }
  }

  func remove(_ inst: Instance) {
    NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: inst.statusItem.button?.window)
    inst.teardown()
    instances.removeAll { $0 === inst }
    if instances.isEmpty { return NSApp.terminate(nil) }
    renumber()
    updatePolicy()
  }

  // ---- ⌘Tab ---------------------------------------------------------------

  /// In ⌘Tab and the Dock while a terminal is open, so you can come back to
  /// it. It only changes while codebar is in the background, since dropping
  /// out of them also takes the focus away.
  func updatePolicy() {
    guard !NSApp.isActive else { return }
    NSApp.setActivationPolicy(instances.contains { $0.window.isVisible } ? .regular : .accessory)
  }

  func show(slot: Int) {
    instances.first { $0.slot == slot }?.show()
  }

  /// Opens the instance `step` places along from `inst` by number, wrapping
  /// around. `inst` stays open behind it.
  func cycle(from inst: Instance, by step: Int) {
    let ordered = instances.sorted { $0.num < $1.num }
    guard ordered.count > 1, let i = ordered.firstIndex(where: { $0 === inst }) else { return }
    ordered[(i + step + ordered.count) % ordered.count].show()
  }

  /// Every instance, in a grid on the screen the mouse is on, in icon order.
  /// The one you were in (or else the first) gets the focus.
  func arrange() {
    let ordered = instances.sorted { $0.num < $1.num }
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
          let focus = ordered.first(where: { $0.window.isKeyWindow }) ?? ordered.first
    else { return }
    let gap: CGFloat = 8
    let area = screen.visibleFrame.insetBy(dx: gap, dy: gap)
    let cols = Int(Double(ordered.count).squareRoot().rounded(.up))
    let rows = (ordered.count + cols - 1) / cols
    let w = ((area.width - gap * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down)
    let h = ((area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)).rounded(.down)
    for (i, inst) in ordered.enumerated() {
      let col = CGFloat(i % cols), row = CGFloat(i / cols)
      inst.tile(NSRect(x: area.minX + col * (w + gap), y: area.maxY - h - row * (h + gap), width: w, height: h))
    }
    focus.show()
  }

  // The icons are numbered left to right (by where they actually sit, so
  // dragging one with ⌘ renumbers too), and each hotkey follows its number.
  @objc private func iconMoved() {
    guard !renumberPending else { return }
    renumberPending = true
    after(0.2) { [weak self] in
      self?.renumberPending = false
      self?.renumber()
    }
  }

  func renumber() {
    for (i, inst) in instances.sorted(by: { $0.iconX < $1.iconX }).enumerated() {
      inst.setNumber(i + 1)
    }
    registerHotkeys()
  }

  private func registerHotkeys() {
    var wanted: [UInt32: Int] = [:]
    for inst in instances where inst.num <= Self.maxSlots { wanted[UInt32(inst.slot)] = inst.num }
    wanted[Self.gridHotkey] = 0
    HotKeys.shared.set(wanted, modifiers: modifiers.carbon)
  }

  // ---- quitting -----------------------------------------------------------

  /// How long after the first ⌘Q a second one quits.
  static let quitWindow = 2.0
  private var quitPressed = Date.distantPast

  /// Like Chrome: the first ⌘Q only warns, in `inst`; another one soon after
  /// quits.
  func requestQuit(from inst: Instance) {
    if Date().timeIntervalSince(quitPressed) < Self.quitWindow { return NSApp.terminate(nil) }
    quitPressed = Date()
    inst.ui.showToast("Press ⌘Q again to quit", for: Self.quitWindow)
  }

  // ---- settings -----------------------------------------------------------

  func setModifiers(_ m: Modifiers) {
    modifiers = m
    Store.shared.modifiers = m.id
    registerHotkeys()
    for inst in instances { inst.refresh() }
  }

  func setNotify(_ on: Bool) {
    notifyOn = on
    Store.shared.set("notify", on)
    if on { requestNotifications() }
  }

  private func requestNotifications() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
  }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
  // codebar is often the active app while you're in another instance, so
  // show them anyway.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                          withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
  }

  /// Clicking a notification opens the instance that posted it.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                          withCompletionHandler completionHandler: @escaping () -> Void) {
    let slot = response.notification.request.content.userInfo["slot"] as? Int
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        if let slot { AppDelegate.shared.show(slot: slot) }
      }
    }
    completionHandler()
  }
}
