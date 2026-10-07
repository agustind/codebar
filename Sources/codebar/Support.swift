import AppKit
import Carbon.HIToolbox

// ---- theme ----------------------------------------------------------------

extension NSColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
      green: CGFloat((hex >> 8) & 0xff) / 255,
      blue: CGFloat(hex & 0xff) / 255,
      alpha: alpha)
  }
}

enum Theme {
  static let bg = NSColor(hex: 0x16181d)
  static let bar = NSColor(hex: 0x1e2128)
  /// The header of the window you're typing in.
  static let barActive = NSColor(hex: 0x292d35)
  static let line = NSColor(hex: 0x2c313b)
  static let text = NSColor(hex: 0xd8dce4)
  static let muted = NSColor(hex: 0x7d8595)
  static let accent = NSColor(hex: 0xd97757)
  static let selection = NSColor(hex: 0x3a4150)
  static let hover = NSColor(white: 1, alpha: 0.06)

  // black, red, green, yellow, blue, magenta, cyan, white, then the brights.
  static let ansi: [UInt32] = [
    0x1e2128, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xd8dce4,
    0x5c6370, 0xff7b86, 0xb5e890, 0xffd88f, 0x7cc4ff, 0xdc90f0, 0x6fd3e0, 0xffffff,
  ]

  static let defaultFontSize: CGFloat = 12.5

  // Nerd Fonts first so prompt glyphs (starship, p10k…) render.
  static func terminalFont(size: CGFloat) -> NSFont {
    for family in ["JetBrainsMono Nerd Font Mono", "FiraCode Nerd Font Mono", "MesloLGS NF", "Symbols Nerd Font Mono"] {
      if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return f }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  }
}

// ---- small helpers --------------------------------------------------------

func after(_ seconds: Double, _ f: @escaping @MainActor () -> Void) {
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { f() } }
}

let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

/// The folder's name as the menu bar and notifications show it.
func folderName(_ path: String) -> String {
  if path == homeDir { return "~" }
  return path.split(separator: "/").last.map(String.init) ?? path
}

final class ActionItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
    state = checked ? .on : .off
  }

  required init(coder: NSCoder) { fatalError() }

  @objc private func run() { handler() }
}

// ---- settings -------------------------------------------------------------

/// Settings stay where earlier versions kept them, so they carry over:
/// store.json (each slot's folder as `cwd.<n>`, its size and place as
/// `size.<n>` and `pos.<n>`, `command`, `notify`) and the hotkey-modifiers
/// file.
@MainActor
final class Store {
  static let shared = Store()

  let dir: URL
  private var values: [String: Any] = [:]
  private var url: URL { dir.appendingPathComponent("store.json") }
  private var modifiersURL: URL { dir.appendingPathComponent("hotkey-modifiers") }

  private init() {
    dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("app.codebar")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      values = obj
    }
  }

  func string(_ key: String) -> String? {
    values[key] as? String
  }

  func bool(_ key: String) -> Bool? {
    if let b = values[key] as? Bool { return b }
    if let s = values[key] as? String { return s == "true" ? true : s == "false" ? false : nil }
    return nil
  }

  func set(_ key: String, _ value: Any) {
    values[key] = value
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: url, options: .atomic)
  }

  var modifiers: String? {
    get { (try? String(contentsOf: modifiersURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    set { try? newValue?.write(to: modifiersURL, atomically: true, encoding: .utf8) }
  }
}

// ---- hotkeys --------------------------------------------------------------

/// The hotkey is <modifiers>+<number>, shared by every instance; each adds the
/// number of its icon.
struct Modifiers: Equatable {
  let id: String
  let symbols: String
  let carbon: UInt32

  static let all = [
    Modifiers(id: "ctrl+alt", symbols: "⌃⌥", carbon: UInt32(controlKey | optionKey)),
    Modifiers(id: "cmd+alt", symbols: "⌘⌥", carbon: UInt32(cmdKey | optionKey)),
    Modifiers(id: "ctrl+shift", symbols: "⌃⇧", carbon: UInt32(controlKey | shiftKey)),
    Modifiers(id: "ctrl+cmd", symbols: "⌃⌘", carbon: UInt32(controlKey | cmdKey)),
  ]
}

@MainActor
final class HotKeys {
  static let shared = HotKeys()

  var onPress: ((UInt32) -> Void)?
  private var refs: [UInt32: EventHotKeyRef] = [:]
  private var registered: [UInt32: (Int, UInt32)] = [:]

  private static let digitKeys: [Int: Int] = [
    0: kVK_ANSI_0, 1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5,
    6: kVK_ANSI_6, 7: kVK_ANSI_7, 8: kVK_ANSI_8, 9: kVK_ANSI_9,
  ]

  private init() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hk = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
      let id = hk.id
      MainActor.assumeIsolated { HotKeys.shared.onPress?(id) }
      return noErr
    }, 1, &spec, nil, nil)
  }

  /// Registers exactly these (id → number) with the given modifiers, touching
  /// only what changed.
  func set(_ wanted: [UInt32: Int], modifiers: UInt32) {
    for (id, cur) in registered where wanted[id] != cur.0 || cur.1 != modifiers {
      if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
      registered[id] = nil
    }
    for (id, n) in wanted where registered[id] == nil {
      guard let key = Self.digitKeys[n] else { continue }
      var ref: EventHotKeyRef?
      let hkID = EventHotKeyID(signature: OSType(0x63646272), id: id) // 'cdbr'
      if RegisterEventHotKey(UInt32(key), modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
        refs[id] = ref
        registered[id] = (n, modifiers)
      }
    }
  }
}
