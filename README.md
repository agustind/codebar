# codebar

A macOS menu-bar terminal for running Claude Code.

- **Click** the menu-bar icon, or press **⌃⌥1**, to drop a terminal down under the icon. It opens a plain login shell; `cd` to your project and run `claude` yourself.
- **Run several projects side by side.** Right-click the icon, then **New Instance**, to add another icon with its own terminal and session. Instance *n* is labelled `n` and toggles with **⌃⌥n**, so you can keep one Claude Code per project in the menu bar.
- **See which ones are busy.** While Claude Code is working in an instance, a spinner turns next to its number in the menu bar (`1 ⠹`). It stops when Claude is done and waiting for you.
- The window hides when it loses focus. Pin it (📌 in the header, or from the right-click menu) to keep it open.
- The header shows the folder the terminal is in and follows `cd`. **⌘O** (or click the path) restarts the session in a new directory. Each instance slot remembers its own folder.

Keys inside the terminal: ⇧↩ newline · ⌘C copy selection · ⌘V paste · ⌘K clear · ⌘N new instance · ⌘W hide · ⌘+/⌘−/⌘0 zoom.

## Develop

```sh
./build-helper.sh   # only after editing native/pty-helper.c
tinyjs dev
tinyjs build        # dist/codebar.app
```

## How it works

- `native/pty-helper.c`: txiki.js can only spawn processes over pipes, so this small helper `forkpty`s the shell and relays its output on stdout. Keystrokes and resize events arrive as framed messages on a FIFO, because txiki's spawn stdin stalls after its first write.
- `src/main.js`: the backend. It owns the tray icon, the hotkey, window placement (`tray.position()`), and the pty session. It keeps 512 KB of scrollback that gets replayed if the page reloads.
- `src/frontend/`: xterm.js (vendored in `vendor/`).
- Current folder: while output is quiet, the helper reports the foreground process's working directory as an OSC 7 sequence, which the page shows in the header.
- Activity: Claude Code sets the terminal title to `◐`/`◑ <title>` while it works and `✳ <title>` when idle. The backend watches for that and animates the tray title. It won't show if `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is set.
- Multiple instances: tinyjs allows one tray icon per process, so each instance is its own process. The packaged app uses `open -n`; `tinyjs dev` re-runs the backend. Each process claims a slot (`~/Library/Application Support/app.codebar/instances/<n>.pid`).
- Custom startup command: set the `store.json` key `command` (for example `claude`). By default there isn't one, so you get a plain shell.
