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

  let header = NSView()
  let badge = label("1", size: 11, weight: .semibold, color: .white)
  let badgeBG = NSView()
  let folder = FlatButton(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
  let hint = label("", size: 11, color: Theme.muted)
  let pin = FlatButton(symbol: "pin.fill")
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

  var onDrop: (([String]) -> Void)?
  var onOpenURL: ((URL) -> Void)?

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
    let rule = NSView(frame: NSRect(x: 0, y: 0, width: 10000, height: 1))
    rule.wantsLayer = true
    rule.layer?.backgroundColor = Theme.line.cgColor
    header.addSubview(rule)
    badgeBG.wantsLayer = true
    badgeBG.layer?.backgroundColor = Theme.accent.cgColor
    badgeBG.layer?.cornerRadius = 9
    badge.alignment = .center
    badgeBG.addSubview(badge)
    pin.toolTip = "Keep open when unfocused"
    pin.tint = Theme.muted
    add.toolTip = "New instance (⌘N)"
    add.tint = Theme.muted
    for v in [badgeBG, folder, hint, pin, add] { header.addSubview(v) }
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

  func setBadge(_ n: Int) {
    badge.stringValue = String(n)
    needsLayout = true
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

  func setPinned(_ on: Bool) {
    pin.tint = on ? Theme.accent : Theme.muted
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

    // Header, left to right: badge, folder … hint, pin, add.
    badge.sizeToFit()
    let bw = max(18, badge.frame.width + 10)
    badgeBG.frame = NSRect(x: 8, y: (hh - 18) / 2, width: bw, height: 18)
    badge.frame = NSRect(x: 0, y: (18 - badge.frame.height) / 2, width: bw, height: badge.frame.height)
    var right = w - 8
    add.frame = NSRect(x: right - 24, y: (hh - 22) / 2, width: 24, height: 22)
    right -= 24 + 6
    pin.frame = NSRect(x: right - 24, y: (hh - 22) / 2, width: 24, height: 22)
    right -= 24 + 6
    hint.sizeToFit()
    hint.frame.origin = NSPoint(x: right - hint.frame.width, y: ((hh - hint.frame.height) / 2).rounded())
    let fx = badgeBG.frame.maxX + 6
    let fs = folder.fit(padX: 8, height: 22)
    folder.frame = NSRect(x: fx, y: (hh - 22) / 2, width: min(fs.width, w * 0.5), height: 22)

    termBox.frame = NSRect(x: 10, y: 4, width: w - 14, height: h - hh - 10)

    exitedLabel.sizeToFit()
    let rs = restart.fit(padX: 10, height: 22)
    let ew = 12 + exitedLabel.frame.width + 10 + rs.width + 6
    exited.frame = NSRect(x: ((w - ew) / 2).rounded(), y: 14, width: ew, height: 34)
    exitedLabel.frame.origin = NSPoint(x: 12, y: ((34 - exitedLabel.frame.height) / 2).rounded())
    restart.frame = NSRect(x: ew - 6 - rs.width, y: 6, width: rs.width, height: 22)

    about.frame = bounds
    quit.frame = bounds
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
