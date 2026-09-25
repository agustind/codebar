// codebar backend — one menu-bar icon, one dropdown terminal, one pty.
//
// Multiple instances = multiple processes. tinyjs gives each process exactly
// one tray icon, so "New Instance" launches another copy of the app (open -n
// for the packaged .app, a re-exec of the backend under `tinyjs dev`). Each
// copy claims the lowest free slot number via a pid file, and the slot picks
// its hotkey (ctrl+alt+<slot>) and its remembered working directory.

const enc = new TextEncoder();

const WIN_W = 760;
const WIN_H = 480;
const SCROLLBACK_BYTES = 512 * 1024; // replayed to the page after a reload
const MAX_SLOTS = 9;

let app;
let slot = 1;
let slotFile = null;
let pinned = false;
let cwd = tjs.homeDir;
let command = null; // store key "command": run this instead of a plain shell
let busy = false;    // Claude Code in this session is working

// ---- process helpers ----------------------------------------------------

async function run(args) {
  const p = tjs.spawn(args, { stdout: 'pipe', stderr: 'ignore', stdin: 'ignore' });
  const text = await new Response(p.stdout).text().catch(() => '');
  const st = await p.wait();
  return { ok: st.exit_status === 0, text };
}

async function exists(path) {
  try { await tjs.stat(path); return true; } catch { return false; }
}

async function pidAlive(pid) {
  if (!pid || pid === tjs.pid) return pid === tjs.pid;
  return (await run(['/bin/kill', '-0', String(pid)])).ok;
}

// ---- instance slots -----------------------------------------------------

function slotsDir() {
  return app.paths.data + '/instances';
}

async function readSlots() {
  const taken = new Map();
  for (let n = 1; n <= MAX_SLOTS; n++) {
    try {
      const pid = parseInt(new TextDecoder().decode(await tjs.readFile(`${slotsDir()}/${n}.pid`)), 10);
      if (await pidAlive(pid)) taken.set(n, pid);
    } catch {}
  }
  return taken;
}

async function claimSlot() {
  await tjs.makeDir(slotsDir(), { recursive: true }).catch(() => {});
  const taken = await readSlots();
  for (let n = 1; n <= MAX_SLOTS; n++) {
    if (taken.has(n)) continue;
    slot = n;
    slotFile = `${slotsDir()}/${n}.pid`;
    await tjs.writeFile(slotFile, enc.encode(String(tjs.pid)));
    return;
  }
  slot = MAX_SLOTS + 1; // everything taken: run unnumbered, remember nothing
}

async function releaseSlot() {
  if (slotFile) await tjs.remove(slotFile).catch(() => {});
}

async function spawnInstance() {
  const bundle = tjs.exePath.match(/^(.*\.app)\/Contents\/MacOS\//)?.[1];
  if (bundle) {
    // -n: a fresh copy even though one is running (LaunchServices would
    // otherwise just re-activate us).
    tjs.spawn(['/usr/bin/open', '-n', bundle], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
    return;
  }
  // `tinyjs dev` / bare binary: the backend spawns its own launcher when
  // TINYJS_SOCKET is absent, so re-running ourselves is a whole new app.
  const env = { ...tjs.env };
  delete env.TINYJS_SOCKET;
  tjs.spawn([tjs.exePath, ...tjs.args.slice(1)], {
    env, cwd: tjs.cwd, stdin: 'ignore', stdout: 'inherit', stderr: 'inherit',
  });
}

async function quitAll() {
  for (const [n, pid] of await readSlots()) {
    if (pid !== tjs.pid) await run(['/bin/kill', '-TERM', String(pid)]);
  }
  await quit();
}

async function quit() {
  session?.kill();
  await releaseSlot();
  app.quit();
}

// ---- pty session --------------------------------------------------------

// The C helper ships inside src/bin, but copies there lose the exec bit (and
// a signed bundle must not be modified), so run it from the cache dir.
async function helperPath() {
  const src = decodeURIComponent(new URL('./bin/pty-helper', import.meta.url).pathname);
  const dst = app.paths.cache + '/pty-helper';
  // Always install a fresh file and rename it into place. Overwriting a binary
  // that has already run keeps its inode, and macOS then SIGKILLs it on exec
  // because its cached code signature no longer matches; a copy left in that
  // state looks byte-identical, so comparing contents can't detect it.
  await tjs.makeDir(app.paths.cache, { recursive: true }).catch(() => {});
  const tmp = dst + '.' + tjs.pid;
  await tjs.writeFile(tmp, await tjs.readFile(src));
  await run(['/bin/chmod', '755', tmp]);
  await run(['/bin/mv', '-f', tmp, dst]);
  return dst;
}

function frame(type, payload) {
  const f = new Uint8Array(5 + payload.length);
  f[0] = type.charCodeAt(0);
  new DataView(f.buffer).setUint32(1, payload.length);
  f.set(payload, 5);
  return f;
}

let session = null;
let sessionSeq = 0;

// Claude Code sets the terminal title (OSC 0) to "<prefix> <title>", where
// the prefix alternates ◐/◑ while it works and is ✳ when it's idle.
const TITLE_RE = /\x1b\][02];([^\x07\x1b]*)(?:\x07|\x1b\\)/g;

// Scans output for title changes; returns the unterminated tail to prepend
// to the next chunk, so a sequence split across reads isn't missed.
function watchTitle(text) {
  let title = null;
  let end = 0;
  for (const m of text.matchAll(TITLE_RE)) {
    title = m[1];
    end = m.index + m[0].length;
  }
  if (title !== null) setBusy(/^[\u25D0\u25D1]/.test(title));
  const open = text.lastIndexOf('\x1b]');
  return open >= end && text.length - open < 1024 ? text.slice(open) : '';
}

function startSession(rows, cols) {
  session?.kill();
  setBusy(false);
  const id = ++sessionSeq;
  const shell = tjs.env.SHELL || '/bin/zsh';
  // A plain login shell (interactive: it's on a tty). A custom command runs
  // through the shell so PATH from .zprofile/.zshrc applies.
  const argv = command ? [shell, '-l', '-i', '-c', command] : [shell, '-l'];

  const s = {
    id,
    scrollback: [],
    scrollbackBytes: 0,
    rows, cols,
    exited: false,
    proc: null,
    input: null,
    queue: Promise.resolve(),
    // Serialized so frames never interleave.
    send(bytes) {
      this.queue = this.queue.then(() => this.input?.write(bytes)).catch(() => {});
    },
    kill() {
      if (this.exited) return;
      this.queue.then(() => this.input?.close()).catch(() => {});
      try { this.proc?.kill('SIGHUP'); } catch {}
    },
  };
  session = s;

  (async () => {
    const helper = await helperPath();
    // Input goes through a FIFO: a spawned process's stdin stream in txiki
    // never resolves its first write, which stalls every write after it.
    const dir = await tjs.makeTempDir(tjs.tmpDir + '/codebar-XXXXXX');
    const fifo = dir + '/input';
    if (!(await run(['/usr/bin/mkfifo', '-m', '600', fifo])).ok) throw new Error('mkfifo failed');
    s.proc = tjs.spawn([helper, String(rows), String(cols), cwd, fifo, ...argv], {
      stdin: 'ignore', stdout: 'pipe', stderr: 'inherit',
      env: { ...tjs.env, CODEBAR_INSTANCE: String(slot) },
    });
    const exited = s.proc.wait();
    // Opening the write end completes once the helper opened the read end,
    // so the path can go right away. If the helper dies before that, the open
    // would block forever (and keep the whole process from quitting), so
    // release it by opening the read end ourselves.
    let opened = false;
    exited.then(async () => {
      if (opened) return;
      const r = await tjs.open(fifo, 'r').catch(() => null);
      await r?.close();
    });
    s.input = await tjs.open(fifo, 'w');
    opened = true;
    await tjs.remove(dir, { recursive: true }).catch(() => {});

    let titleTail = '';
    const dec = new TextDecoder();
    const reader = s.proc.stdout.getReader();
    // Coalesce bursts into one bridge message per ~8ms.
    let pending = '';
    let flushTimer = null;
    const flush = () => {
      flushTimer = null;
      if (!pending) return;
      app.push('pty-data', { session: id, data: pending });
      pending = '';
    };
    for (;;) {
      const { value, done } = await reader.read().catch(() => ({ done: true }));
      if (done) break;
      const text = dec.decode(value, { stream: true });
      if (!text) continue;
      titleTail = watchTitle(titleTail + text);
      s.scrollback.push(text);
      s.scrollbackBytes += text.length;
      while (s.scrollbackBytes > SCROLLBACK_BYTES && s.scrollback.length > 1) {
        s.scrollbackBytes -= s.scrollback.shift().length;
      }
      pending += text;
      flushTimer ??= setTimeout(flush, 8);
    }
    clearTimeout(flushTimer);
    flush();
    const st = await exited;
    s.exited = true;
    if (session === s) setBusy(false);
    if (session === s) app.push('pty-exit', { session: id, code: st.exit_status, signal: st.term_signal });
  })().catch((e) => {
    s.exited = true;
    app.push('pty-data', { session: id, data: `\r\n\x1b[31mcodebar: ${e}\x1b[0m\r\n` });
    app.push('pty-exit', { session: id, code: -1 });
  });
  return s;
}

// ---- window placement ---------------------------------------------------

const win = () => app.window('main');

async function visible() {
  try { return !!(await win().getState())?.visible; } catch { return false; }
}

async function placeUnderTray() {
  const t = await app.tray.position().catch(() => null);
  if (!t) { win().center(); return; }
  let w = WIN_W;
  try { w = (await win().getState())?.outer?.width || WIN_W; } catch {}
  let x = Math.round(t.x + t.width / 2 - w / 2);
  const y = Math.round(t.y + t.height + 4);
  try {
    const screens = (await app.screens()) || [];
    const s = screens.find((s) => t.x >= s.x && t.x < s.x + s.width) || screens[0];
    if (s) x = Math.max(s.x + 8, Math.min(x, s.x + s.width - w - 8));
  } catch {}
  win().setPosition(x, y);
}

async function showWindow() {
  await placeUnderTray();
  win().show();
  app.push('focus-terminal', {});
}

async function toggleWindow() {
  if (await visible()) win().hide();
  else await showWindow();
}

// ---- tray ---------------------------------------------------------------

function hotkeyCombo() {
  return slot <= MAX_SLOTS ? `ctrl+alt+${slot}` : null;
}

function trayMenu() {
  const hk = hotkeyCombo();
  return [
    { id: 'toggle', label: `Show / Hide${hk ? '   (⌃⌥' + slot + ')' : ''}` },
    { id: 'new', label: 'New Instance' },
    { separator: true },
    { id: 'restart', label: 'Restart Session' },
    { id: 'pin', label: 'Keep Open When Unfocused', checked: pinned },
    { separator: true },
    { id: 'quit', label: slot > 1 ? `Quit Instance ${slot}` : 'Quit Instance' },
    { id: 'quitAll', label: 'Quit All Instances' },
  ];
}

function folderName(p) {
  if (p === tjs.homeDir) return '~';
  return p.split('/').filter(Boolean).pop() || p;
}

const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
let spinFrame = 0;
let spinTimer = null;

function setBusy(value) {
  if (value === busy) return;
  busy = value;
  clearInterval(spinTimer);
  spinTimer = null;
  if (busy) {
    spinTimer = setInterval(() => {
      spinFrame = (spinFrame + 1) % SPINNER.length;
      refreshTray();
    }, 150);
  }
  refreshTray();
}

function refreshTray() {
  app.tray.set({
    icon: 'sf:apple.terminal',
    title: busy ? `${slot} ${SPINNER[spinFrame]}` : String(slot),
    tooltip: `codebar ${slot} — ${folderName(cwd)}`,
    menu: trayMenu(),
    primaryAction: true,
  });
}

async function changeFolder(dir) {
  if (!dir) return;
  cwd = dir;
  await app.store.set(`cwd.${slot}`, dir);
  refreshTray();
  app.push('session-reset', { cwd, slot });
  startSession(session?.rows || 24, session?.cols || 80);
}

// ---- page API -----------------------------------------------------------

export const api = {
  // The page calls this on boot (and after every reload): starts the session
  // the first time, otherwise replays the scrollback so nothing is lost.
  async attach({ rows, cols }) {
    // An exited session is kept so its last output stays readable; the page
    // offers the restart.
    if (!session) startSession(rows, cols);
    return {
      session: session.id,
      replay: session.scrollback.join(''),
      exited: session.exited,
      slot, cwd, pinned,
      folder: folderName(cwd),
      hotkey: hotkeyCombo(),
    };
  },

  async restart({ rows, cols }) {
    const s = startSession(rows, cols);
    return { session: s.id };
  },

  async input({ data }) {
    if (!session?.input || session.exited) return false;
    session.send(frame('d', enc.encode(data)));
    return true;
  },

  async resize({ rows, cols }) {
    if (!session) return false;
    session.rows = rows;
    session.cols = cols;
    if (!session.input || session.exited) return false;
    const p = new Uint8Array(4);
    new DataView(p.buffer).setUint16(0, rows);
    new DataView(p.buffer).setUint16(2, cols);
    session.send(frame('r', p));
    return true;
  },

  async setFolder({ dir }) {
    await changeFolder(dir);
    return true;
  },

  async setPinned({ value }) {
    pinned = !!value;
    refreshTray();
    return pinned;
  },

  async hide() {
    win().hide();
    return true;
  },

  async newInstance() {
    await spawnInstance();
    return true;
  },

  openUrl: async ({ url }) => {
    if (/^https?:\/\//.test(url)) await run(['/usr/bin/open', url]);
    return true;
  },
};

// ---- lifecycle ----------------------------------------------------------

export async function init(a) {
  app = a;
  await claimSlot();
  cwd = (await app.store.get(`cwd.${slot}`)) || tjs.homeDir;
  if (!(await exists(cwd))) cwd = tjs.homeDir;
  command = await app.store.get('command');

  const w = win();
  app.setHideOnClose(true);
  w.setAllSpaces(true);   // drop down on whatever Space is active
  w.setLevel('floating'); // above normal windows, like a popover
  refreshTray();

  const hk = hotkeyCombo();
  if (hk) app.hotkey.register('toggle', hk);

  for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
    try { tjs.addSignalListener(sig, () => quit()); } catch {}
  }
}

export function onTray(id, a) {
  if (id === null || id === undefined || id === 'toggle') return toggleWindow();
  if (id === 'new') return spawnInstance();
  if (id === 'restart') {
    app.push('session-reset', { cwd, slot });
    return startSession(session?.rows || 24, session?.cols || 80);
  }
  if (id === 'pin') {
    pinned = !pinned;
    app.push('pinned', { value: pinned });
    return refreshTray();
  }
  if (id === 'quit') return quit();
  if (id === 'quitAll') return quitAll();
}

export function onHotkey(id) {
  if (id === 'toggle') toggleWindow();
}

export function onWindowState(info) {
  // Popover behaviour: clicking elsewhere puts the terminal away.
  if (info.win === 'main' && info.focused === false && !pinned) win().hide();
}
