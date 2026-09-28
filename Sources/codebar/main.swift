import AppKit

// codebar — a menu-bar terminal for running Claude Code. Each instance is a
// menu-bar icon with its own dropdown window and shell session; they all live
// in this one process.

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
