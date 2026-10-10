import AppKit

/// Borderless, so it needs telling that it can take the keyboard.
final class DropdownWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// A flat button that shows a background on hover, or a filled one.
final class FlatButton: NSButton {
  var onClick: (() -> Void)?
  var fill: NSColor? { didSet { refresh() } }
  var tint: NSColor = Theme.text { didSet { refresh() } }
  var text = "" { didSet { refresh() } }
  /// Shown dimmed after the text, like a key hint.
  var hint: String? { didSet { refresh() } }
  var underline = false { didSet { refresh() } }
  private var hovering = false

  init(title: String = "", symbol: String? = nil, font: NSFont = .systemFont(ofSize: 12)) {
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .regularSquare
    refusesFirstResponder = true
    focusRingType = .none
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    self.font = font
    self.title = ""
    text = title
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
      imagePosition = .imageOnly
    }
    target = self
    action = #selector(clicked)
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func refresh() {
    layer?.backgroundColor = (fill ?? (hovering ? Theme.hover : .clear)).cgColor
    layer?.borderColor = (hovering && fill == nil ? Theme.line : .clear).cgColor
    contentTintColor = tint
    guard !text.isEmpty, let font else { return }
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byTruncatingTail
    p.alignment = .center
    var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: tint, .font: font, .paragraphStyle: p]
    if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    let s = NSMutableAttributedString(string: text, attributes: attrs)
    if let hint {
      attrs[.foregroundColor] = tint.withAlphaComponent(0.6)
      s.append(NSAttributedString(string: " " + hint, attributes: attrs))
    }
    attributedTitle = s
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
  override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  @objc private func clicked() { onClick?() }

  /// Padded size for the title.
  func fit(padX: CGFloat, height: CGFloat) -> NSSize {
    NSSize(width: ceil(attributedTitle.size().width) + padX * 2, height: height)
  }
}

func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
  let l = NSTextField(labelWithString: text)
  l.font = .systemFont(ofSize: size, weight: weight)
  l.textColor = color
  return l
}

/// The little pixel bug at the start of the header, after Claude's logo.
final class PixelBug: NSView {
  /// `#` is filled; the eyes are holes, so the header shows through them.
  static let rows = [
    ".##########.",
    ".##.####.##.",
    ".##.####.##.",
    "############",
    "############",
    "..#.#..#.#..",
    "..#.#..#.#..",
  ]
  static let pixel: CGFloat = 2
  static let size = NSSize(width: CGFloat(rows[0].count) * pixel, height: CGFloat(rows.count) * pixel)

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    Theme.accent.setFill()
    let p = Self.pixel
    for (y, row) in Self.rows.enumerated() {
      for (x, c) in row.enumerated() where c == "#" {
        NSRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p).fill()
      }
    }
  }
}

/// Dims the window and shows a box in the middle; a click outside it
/// dismisses.
final class Overlay: NSView {
  let box = NSView()
  let stack = NSStackView()
  var onDismiss: (() -> Void)?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.withAlphaComponent(0.8).cgColor
    box.wantsLayer = true
    box.layer?.backgroundColor = Theme.bar.cgColor
    box.layer?.borderColor = Theme.line.cgColor
    box.layer?.borderWidth = 1
    box.layer?.cornerRadius = 12
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 18, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
      stack.topAnchor.constraint(equalTo: box.topAnchor),
      stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
      stack.widthAnchor.constraint(equalToConstant: 280),
    ])
    addSubview(box)
  }

  required init?(coder: NSCoder) { fatalError() }

  func paragraph(_ text: String, color: NSColor = Theme.text) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = .systemFont(ofSize: 12)
    l.textColor = color
    l.alignment = .center
    l.preferredMaxLayoutWidth = 240
    return l
  }

  override func layout() {
    super.layout()
    for v in stack.arrangedSubviews { v.setContentCompressionResistancePriority(.required, for: .vertical) }
    let size = stack.fittingSize
    box.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                       y: ((bounds.height - size.height) / 2).rounded(),
                       width: size.width, height: size.height)
  }

  override func mouseDown(with event: NSEvent) {
    if !box.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
  }

  override func scrollWheel(with event: NSEvent) {}
}

/// The window's contents: header, terminal, and the bars and boxes that go
/// over it.
final class InstanceView: NSView {
  static let headerHeight: CGFloat = 30
  /// How close to an edge a drag resizes the window; the terminal stays
  /// clear of it so its I-beam doesn't cover the resize cursor.
  static let grip: CGFloat = 6

  /// The edges that resize the window.
  struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1)
    static let right = Edges(rawValue: 2)
    static let bottom = Edges(rawValue: 4)
    static let top = Edges(rawValue: 8)
  }

  let header = NSView()
  /// The line under the header; orange on the window you're typing in.
  let rule = NSView()
  let bug = PixelBug()
  let folder = FlatButton(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
  let hint = label("", size: 11, color: Theme.muted)
  /// Claude's activity, after the folder: the spinner, ? or ✓.
  let status = label("", color: Theme.muted)
  let add = FlatButton(symbol: "plus")
  let termBox = NSView()
  let exited = NSView()
  let exitedLabel = label("Session ended")
  let restart = FlatButton(title: "Restart ↵")
  let about = Overlay()
  let aboutVersion = label("", color: Theme.muted)
  let aboutClose = FlatButton(title: "Close")
  let quit = Overlay()
  let quitMessage: NSTextField
  let quitCancel = FlatButton()
  let quitOk = FlatButton()
  /// A pill at the top, e.g. "Press ⌘Q again to quit".
  let toast = NSView()
  let toastLabel = label("", weight: .medium)

  var onDrop: (([String]) -> Void)?
  var onOpenURL: ((URL) -> Void)?
  /// The frame a resize drag asks for; `done` on release.
  var onResize: ((_ frame: NSRect, _ done: Bool) -> Void)?
  /// Where dragging the header puts the window's origin; `done` on release.
  var onMove: ((_ origin: NSPoint, _ done: Bool) -> Void)?
  /// Double-clicking the header.
  var onDock: (() -> Void)?
  /// Hanging from its icon: the top edge doesn't resize and the sides move
  /// together, so it stays centered.
  var docked = true {
    didSet { window?.invalidateCursorRects(for: self) }
  }

  private(set) weak var terminal: NSView?

  override init(frame: NSRect) {
    quitMessage = quit.paragraph("", color: Theme.muted)
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.cgColor
    layer?.cornerRadius = 10
    layer?.borderColor = Theme.line.cgColor
    layer?.borderWidth = 1
    layer?.masksToBounds = true

    header.wantsLayer = true
    header.layer?.backgroundColor = Theme.bar.cgColor
    rule.wantsLayer = true
    header.addSubview(rule)
    add.toolTip = "New instance (⌘N)"
    add.tint = Theme.muted
    status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    for v in [bug, folder, status, hint, add] { header.addSubview(v) }
    addSubview(termBox)
    addSubview(header)

    exited.wantsLayer = true
    exited.layer?.backgroundColor = Theme.bar.cgColor
    exited.layer?.borderColor = Theme.line.cgColor
    exited.layer?.borderWidth = 1
    exited.layer?.cornerRadius = 8
    exited.shadow = NSShadow()
    exited.layer?.shadowColor = NSColor.black.cgColor
    exited.layer?.shadowOpacity = 0.4
    exited.layer?.shadowRadius = 10
    exited.layer?.shadowOffset = NSSize(width: 0, height: -6)
    restart.fill = Theme.accent
    restart.tint = .white
    exited.addSubview(exitedLabel)
    exited.addSubview(restart)
    exited.isHidden = true
    addSubview(exited)

    let logo = NSImageView(image: NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)!
      .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))!)
    logo.contentTintColor = Theme.accent
    let title = label("codebar", size: 15, weight: .bold)
    let blurb = about.paragraph("A menu-bar terminal for running Claude Code, one instance per project.")
    let madeBy = NSStackView(views: [label("Made by"), link("dondo.dev", "https://dondo.dev")])
    madeBy.spacing = 3
    aboutClose.fill = Theme.accent
    aboutClose.tint = .white
    for v in [logo, title, aboutVersion, blurb, madeBy, aboutClose] { about.stack.addArrangedSubview(v) }
    about.stack.setCustomSpacing(2, after: title)
    about.isHidden = true
    addSubview(about)

    quitCancel.fill = Theme.line
    quitCancel.text = "Cancel"
    quitCancel.hint = "esc"
    quitOk.fill = Theme.accent
    quitOk.tint = .white
    quitOk.text = "Quit"
    quitOk.hint = "↵"
    let buttons = NSStackView(views: [quitCancel, quitOk])
    buttons.spacing = 8
    for b in [quitCancel, quitOk, aboutClose] {
      b.translatesAutoresizingMaskIntoConstraints = false
      let size = b.fit(padX: 14, height: 24)
      b.widthAnchor.constraint(equalToConstant: size.width).isActive = true
      b.heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }
    for v in [label("Quit this instance?", size: 15, weight: .bold), quitMessage, buttons] {
      quit.stack.addArrangedSubview(v)
    }
    quit.isHidden = true
    addSubview(quit)

    toast.wantsLayer = true
    toast.layer?.backgroundColor = Theme.barActive.cgColor
    toast.layer?.borderColor = Theme.line.cgColor
    toast.layer?.borderWidth = 1
    toast.layer?.cornerRadius = 14
    toast.addSubview(toastLabel)
    toast.isHidden = true
    addSubview(toast)

    setActive(false)

    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError() }

  private func link(_ text: String, _ url: String) -> NSButton {
    let b = FlatButton(title: text)
    b.tint = Theme.accent
    b.underline = true
    b.layer?.borderWidth = 0
    b.onClick = { [weak self] in if let u = URL(string: url) { self?.onOpenURL?(u) } }
    return b
  }

  func setTerminal(_ view: NSView) {
    terminal?.removeFromSuperview()
    terminal = view
    view.frame = termBox.bounds
    view.autoresizingMask = [.width, .height]
    termBox.addSubview(view)
  }

  func setHint(_ text: String) {
    hint.stringValue = text
    needsLayout = true
  }

  /// Just the folder's name, in capitals so you can tell instances apart at a
  /// glance; the full path is in the tooltip.
  func setFolder(_ path: String) {
    let isHome = path.range(of: #"^/Users/[^/]+/?$"#, options: .regularExpression) != nil
    let name = isHome ? "~" : (path.split(separator: "/").last.map(String.init) ?? "/")
    folder.text = name.uppercased()
    folder.toolTip = "\(path) — change folder (⌘O)"
    needsLayout = true
  }

  /// A lighter header with an orange line under it on the window you're
  /// typing in; the others' are dimmed.
  func setActive(_ active: Bool) {
    header.layer?.backgroundColor = (active ? Theme.barActive : Theme.bar).cgColor
    rule.layer?.backgroundColor = (active ? Theme.accent : Theme.line).cgColor
    rule.frame.size.height = active ? 2 : 1
    folder.tint = active ? Theme.text : Theme.muted
    bug.alphaValue = active ? 1 : 0.5
  }

  /// Shows `text` at the top for `seconds`, then fades it out.
  func showToast(_ text: String, for seconds: Double) {
    toastLabel.stringValue = text
    needsLayout = true
    toast.isHidden = false
    toast.alphaValue = 1
    let shown = Date()
    toastShown = shown
    after(seconds) { [weak self] in
      guard let self, toastShown == shown else { return }
      NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.toast.animator().alphaValue = 0 }) {
        if self.toastShown == shown { self.toast.isHidden = true }
      }
    }
  }

  private var toastShown: Date?

  func setStatus(_ mark: String?) {
    status.stringValue = mark ?? ""
    status.textColor = mark == "?" ? Theme.accent : mark == "✓" ? NSColor(hex: Theme.ansi[2]) : Theme.muted
    needsLayout = true
  }

  func showExited(_ message: String?) {
    exited.isHidden = message == nil
    if let message { exitedLabel.stringValue = message }
    needsLayout = true
  }

  override var isFlipped: Bool { false }

  override func layout() {
    super.layout()
    let w = bounds.width, h = bounds.height, hh = Self.headerHeight
    header.frame = NSRect(x: 0, y: h - hh, width: w, height: hh)
    rule.frame = NSRect(x: 0, y: 0, width: w, height: rule.frame.height)

    // Header, left to right: bug, folder, status … hint, add.
    let bs = PixelBug.size
    bug.frame = NSRect(origin: NSPoint(x: 10, y: ((hh - bs.height) / 2).rounded()), size: bs)
    var right = w - 8
    add.frame = NSRect(x: right - 24, y: (hh - 22) / 2, width: 24, height: 22)
    right -= 24 + 6
    hint.sizeToFit()
    hint.frame.origin = NSPoint(x: right - hint.frame.width, y: ((hh - hint.frame.height) / 2).rounded())
    let fx = bug.frame.maxX + 4
    let fs = folder.fit(padX: 8, height: 22)
    folder.frame = NSRect(x: fx, y: (hh - 22) / 2, width: min(fs.width, w * 0.5), height: 22)
    status.sizeToFit()
    status.frame.origin = NSPoint(x: folder.frame.maxX - 4, y: ((hh - status.frame.height) / 2).rounded())

    let g = Self.grip
    termBox.frame = NSRect(x: 10, y: g, width: w - 10 - g, height: h - hh - 6 - g)

    exitedLabel.sizeToFit()
    let rs = restart.fit(padX: 10, height: 22)
    let ew = 12 + exitedLabel.frame.width + 10 + rs.width + 6
    exited.frame = NSRect(x: ((w - ew) / 2).rounded(), y: 14, width: ew, height: 34)
    exitedLabel.frame.origin = NSPoint(x: 12, y: ((34 - exitedLabel.frame.height) / 2).rounded())
    restart.frame = NSRect(x: ew - 6 - rs.width, y: 6, width: rs.width, height: 22)

    toastLabel.sizeToFit()
    let tw = toastLabel.frame.width + 28
    toast.frame = NSRect(x: ((w - tw) / 2).rounded(), y: h - hh - 14 - 28, width: tw, height: 28)
    toastLabel.frame.origin = NSPoint(x: 14, y: ((28 - toastLabel.frame.height) / 2).rounded())

    about.frame = bounds
    quit.frame = bounds
  }

  // ---- resizing -----------------------------------------------------------

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
    window?.invalidateCursorRects(for: self)
  }

  /// Which edges a point is on; near a corner it's both.
  private func edges(at p: NSPoint) -> Edges {
    let g = Self.grip, c = 3 * g, w = bounds.width, h = bounds.height
    var e: Edges = []
    if p.x < g { e.insert(.left) }
    if p.x > w - g { e.insert(.right) }
    if p.y < g { e.insert(.bottom) }
    if !docked && p.y > h - g { e.insert(.top) }
    // The corners reach further along the edges than the edges are thick.
    if !e.isDisjoint(with: [.left, .right]) {
      if p.y < c { e.insert(.bottom) } else if !docked && p.y > h - c { e.insert(.top) }
    }
    if !e.isDisjoint(with: [.bottom, .top]) {
      if p.x < c { e.insert(.left) } else if p.x > w - c { e.insert(.right) }
    }
    return e
  }

  /// The edges resize, and the header's background and labels move the
  /// window; its buttons stay buttons.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    let p = convert(point, from: superview)
    if !edges(at: p).isEmpty { return self }
    let hit = super.hitTest(point)
    if p.y > bounds.height - Self.headerHeight, !(hit is NSButton), about.isHidden, quit.isHidden { return self }
    return hit
  }

  override func resetCursorRects() {
    let g = Self.grip, c = 3 * g, w = bounds.width, h = bounds.height
    let sideTop = docked ? h : h - c
    var rects: [(NSRect, Edges)] = [
      (NSRect(x: 0, y: c, width: g, height: sideTop - c), .left),
      (NSRect(x: w - g, y: c, width: g, height: sideTop - c), .right),
      (NSRect(x: c, y: 0, width: w - 2 * c, height: g), .bottom),
      (NSRect(x: 0, y: 0, width: c, height: g), [.bottom, .left]),
      (NSRect(x: 0, y: 0, width: g, height: c), [.bottom, .left]),
      (NSRect(x: w - c, y: 0, width: c, height: g), [.bottom, .right]),
      (NSRect(x: w - g, y: 0, width: g, height: c), [.bottom, .right]),
    ]
    if !docked {
      let tl: Edges = [.top, .left], tr: Edges = [.top, .right]
      rects.append((NSRect(x: c, y: h - g, width: w - 2 * c, height: g), .top))
      rects.append((NSRect(x: 0, y: h - g, width: c, height: g), tl))
      rects.append((NSRect(x: 0, y: h - c, width: g, height: c), tl))
      rects.append((NSRect(x: w - c, y: h - g, width: c, height: g), tr))
      rects.append((NSRect(x: w - g, y: h - c, width: g, height: c), tr))
    }
    for (r, e) in rects { addCursorRect(r, cursor: Self.cursor(e)) }
  }

  private static func cursor(_ e: Edges) -> NSCursor {
    if #available(macOS 15, *) {
      let pos: NSCursor.FrameResizePosition = switch e {
      case .left: .left
      case .right: .right
      case .bottom: .bottom
      case .top: .top
      case [.top, .left]: .topLeft
      case [.top, .right]: .topRight
      case [.bottom, .left]: .bottomLeft
      default: .bottomRight
      }
      return .frameResize(position: pos, directions: .all)
    }
    return e == .bottom || e == .top ? .resizeUpDown : .resizeLeftRight
  }

  /// Grabbing an edge or the header works even when the window isn't focused.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// An edge resizes (docked, dragging a side moves both sides, so it stays
  /// centered); the header moves the window, and double-clicked docks it.
  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let e = edges(at: p)
    guard let window, !e.isEmpty || p.y > bounds.height - Self.headerHeight else { return super.mouseDown(with: event) }
    let start = window.frame
    if e.isEmpty {
      if event.clickCount == 2 {
        onDock?()
        return
      }
      var moved = false // a click that doesn't go anywhere leaves it be
      drag(window) { dx, dy, done in
        moved = moved || abs(dx) + abs(dy) > 3
        if moved { onMove?(NSPoint(x: start.minX + dx, y: start.minY + dy), done) }
      }
      return
    }
    let min = Instance.minSize
    drag(window) { dx, dy, done in
      var f = start
      if e.contains(.left) { f.size.width -= docked ? 2 * dx : dx }
      if e.contains(.right) { f.size.width += docked ? 2 * dx : dx }
      if e.contains(.bottom) { f.size.height -= dy }
      if e.contains(.top) { f.size.height += dy }
      f.size = NSSize(width: max(f.width, min.width), height: max(f.height, min.height))
      // Whichever edge isn't being dragged stays put.
      if e.contains(.left) { f.origin.x = start.maxX - f.width }
      if !e.contains(.top) { f.origin.y = start.maxY - f.height }
      onResize?(f, done)
    }
  }

  /// Follows the mouse until it's released: how far it went, and whether
  /// that's the release.
  private func drag(_ window: NSWindow, _ step: (_ dx: CGFloat, _ dy: CGFloat, _ done: Bool) -> Void) {
    let start = NSEvent.mouseLocation
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      let p = NSEvent.mouseLocation
      let done = next.type == .leftMouseUp
      step(p.x - start.x, p.y - start.y, done)
      if done { break }
    }
  }

  // ---- dropping files -----------------------------------------------------

  private func paths(_ info: NSDraggingInfo) -> [String] {
    let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    return urls?.map(\.path) ?? []
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    paths(sender).isEmpty ? [] : .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    paths(sender).isEmpty ? [] : .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let p = paths(sender)
    guard !p.isEmpty else { return false }
    onDrop?(p)
    return true
  }
}
