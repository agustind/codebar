// codebar backend — one menu-bar icon, one dropdown terminal, one pty.
//
// Multiple instances = multiple processes. tinyjs gives each process exactly
// one tray icon, so "New Instance" launches another copy of the app (open -n
// for the packaged .app, a re-exec of the backend under `tinyjs dev`). Each
// copy claims the lowest free slot number via a pid file, and the slot picks
// its hotkey (<modifiers>+<slot>, ctrl+alt by default) and its remembered
// working directory.

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
// Claude Code in this session: 'idle', 'busy' (working) or 'waiting' (on a
// permission prompt or a question for you).
let activity = 'idle';
let unseen = false;  // it finished while you weren't looking
let focused = false; // the terminal window has focus
let notifyOn = true; // store key "notify": post a notification when Claude needs you

// Hotkey modifiers, shared by all instances (each adds its slot digit).
const MODIFIERS = [
  { id: 'ctrl+alt', symbols: '⌃⌥' },
  { id: 'cmd+alt', symbols: '⌘⌥' },
  { id: 'ctrl+shift', symbols: '⌃⇧' },
  { id: 'ctrl+cmd', symbols: '⌃⌘' },
];
let modifiers = MODIFIERS[0];

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
// the prefix alternates ◐/◑ while it works and is ✳ otherwise. ✳ can mean it
// finished or that it's waiting on you, so that's settled from its session
// file (see claudeStatus).
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
  if (title !== null) onTitle(title);
  const open = text.lastIndexOf('\x1b]');
  return open >= end && text.length - open < 1024 ? text.slice(open) : '';
}

function onTitle(title) {
  if (/^[\u25D0\u25D1]/.test(title)) return setActivity('busy');
  // Any other title (Claude exited, the shell took over) clears the state.
  if (!title.startsWith('\u2733')) return setActivity('idle');
  // ✳ after ◐/◑: Claude stopped working, either done or waiting on you.
  if (activity === 'busy') settle(title.slice(1).trim());
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function settle(summary) {
  const s = session;
  setActivity('idle');
  // The title changes on render and the session file is written just after,
  // so give it a moment to catch up.
  let st = null;
  for (const ms of [100, 400, 1000]) {
    await sleep(ms);
    if (session !== s || activity !== 'idle') return; // working again
    st = await claudeStatus();
    if (st?.status !== 'busy') break;
  }
  if (session !== s || activity !== 'idle') return;
  if (isWaiting(st)) {
    setActivity('waiting');
    needsYou(st.waitingFor);
  } else {
    finished(summary);
  }
}

// Claude Code keeps <config>/sessions/<pid>.json current with its status
// ('busy', 'idle' or 'waiting') and, when waiting, what for ('permission
// prompt', 'input needed', ...). Finds the one running on this session's
// terminal; null when there's none.
function claudeSessionsDir() {
  return (tjs.env.CLAUDE_CONFIG_DIR || tjs.homeDir + '/.claude') + '/sessions';
}

async function sessionTty(s) {
  if (s.tty) return s.tty;
  const helper = s.proc?.pid;
  if (!helper) return null;
  // The helper's child (the shell) has the pty as its controlling terminal.
  const { text } = await run(['/bin/ps', '-A', '-o', 'ppid=,tty=']);
  for (const line of text.split('\n')) {
    const [ppid, tty] = line.trim().split(/\s+/);
    if (Number(ppid) === helper && tty && tty !== '??') return (s.tty = tty);
  }
  return null;
}

async function claudeStatus() {
  const s = session;
  const tty = s && !s.exited && (await sessionTty(s));
  if (!tty) return null;
  const { text } = await run(['/bin/ps', '-t', tty, '-o', 'pid=']);
  let found = null;
  for (const pid of text.split(/\s+/).filter(Boolean)) {
    try {
      const st = JSON.parse(new TextDecoder().decode(await tjs.readFile(`${claudeSessionsDir()}/${pid}.json`)));
      if (!found || (st.updatedAt || 0) > (found.updatedAt || 0)) found = st;
    } catch {}
  }
  return found;
}

// 'dialog open' is a dialog you opened yourself (/config and the like).
function isWaiting(st) {
  return st?.status === 'waiting' && st.waitingFor !== 'dialog open';
}

// While waiting, the title stays ✳ even if you dismiss the prompt, so watch
// the file for Claude to move on.
let waitTimer = null;
async function checkWaiting() {
  const st = await claudeStatus();
  if (activity !== 'waiting') return;
  if (isWaiting(st)) waitTimer = setTimeout(checkWaiting, 1000);
  else setActivity(st?.status === 'busy' ? 'busy' : 'idle');
}

function startSession(rows, cols) {
  session?.kill();
  setActivity('idle');
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
    if (session === s) setActivity('idle');
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
  setUnseen(false);
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
  return slot <= MAX_SLOTS ? `${modifiers.id}+${slot}` : null;
}

function hotkeyLabel() {
  return slot <= MAX_SLOTS ? modifiers.symbols + slot : null;
}

// The choice lives in its own file rather than the store so other instances
// can re-read it when signalled.
function modifiersFile() {
  return app.paths.data + '/hotkey-modifiers';
}

async function loadModifiers() {
  try {
    const id = new TextDecoder().decode(await tjs.readFile(modifiersFile())).trim();
    return MODIFIERS.find((m) => m.id === id) || MODIFIERS[0];
  } catch {
    return MODIFIERS[0];
  }
}

async function applyModifiers(m) {
  if (m === modifiers) return;
  app.hotkey.unregister('toggle');
  modifiers = m;
  const hk = hotkeyCombo();
  if (hk) app.hotkey.register('toggle', hk);
  refreshTray();
  app.push('hotkey', { label: hotkeyLabel() });
}

async function setModifiers(id) {
  const m = MODIFIERS.find((m) => m.id === id);
  if (!m) return;
  await tjs.writeFile(modifiersFile(), enc.encode(m.id));
  await applyModifiers(m);
  // Tell the other instances to pick up the new file.
  for (const [n, pid] of await readSlots()) {
    if (pid !== tjs.pid) await run(['/bin/kill', '-USR1', String(pid)]);
  }
}

function trayMenu() {
  const hk = hotkeyLabel();
  return [
    { id: 'toggle', label: `Show / Hide${hk ? '   (' + hk + ')' : ''}` },
    { id: 'new', label: 'New Instance' },
    { separator: true },
    { id: 'restart', label: 'Restart Session' },
    { id: 'pin', label: 'Keep Open When Unfocused', checked: pinned },
    { id: 'notify', label: 'Notify When Claude Needs You', checked: notifyOn },
    {
      label: 'Hotkey',
      submenu: MODIFIERS.map((m) => ({
        id: 'mods:' + m.id,
        label: `${m.symbols}1 … ${m.symbols}9`,
        checked: m === modifiers,
      })),
    },
    { separator: true },
    { id: 'about', label: 'About codebar' },
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

function setActivity(value) {
  if (value === activity) return;
  activity = value;
  clearInterval(spinTimer);
  spinTimer = null;
  clearTimeout(waitTimer);
  waitTimer = null;
  if (activity === 'busy') {
    spinTimer = setInterval(() => {
      spinFrame = (spinFrame + 1) % SPINNER.length;
      refreshTray();
    }, 150);
  }
  if (activity === 'waiting') waitTimer = setTimeout(checkWaiting, 1000);
  refreshTray();
}

function setUnseen(value) {
  if (value === unseen) return;
  unseen = value;
  refreshTray();
}

function notificationId(n) {
  return `done:${n}`;
}

async function looking() {
  return focused && (await visible());
}

// Clicking the notification opens this instance.
function notify(body) {
  if (!notifyOn) return;
  app.notify({
    id: notificationId(slot),
    title: `codebar ${slot} · ${folderName(cwd)}`,
    body,
    sound: true,
  });
}

// Claude finished a turn. If you weren't looking, mark the tray icon and
// post a notification.
async function finished(summary) {
  if (await looking()) return;
  setUnseen(true);
  notify(summary ? `Claude finished: ${summary}` : 'Claude finished and is waiting for you');
}

// Claude stopped on a permission prompt or a question. The tray shows ? for
// as long as that lasts; the notification only goes out if you weren't looking.
async function needsYou(waitingFor) {
  if (await looking()) return;
  notify(
    waitingFor === 'permission prompt' ? 'Claude needs your permission'
      : waitingFor === 'input needed' ? 'Claude has a question for you'
        : 'Claude is waiting for you',
  );
}

function trayTitle() {
  if (activity === 'busy') return `${slot} ${SPINNER[spinFrame]}`;
  if (activity === 'waiting') return `${slot} ?`;
  if (unseen) return `${slot} \u2713`;
  return String(slot);
}

function refreshTray() {
  app.tray.set({
    icon: 'sf:apple.terminal',
    title: trayTitle(),
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
      hotkey: hotkeyLabel(),
      version: app.info.version,
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
  notifyOn = (await app.store.get('notify')) !== false;
  if (notifyOn && (await app.permissions.check('notifications').catch(() => null)) === 'undetermined') {
    app.permissions.request('notifications').catch(() => {});
  }
  modifiers = await loadModifiers();

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
  try { tjs.addSignalListener('SIGUSR1', async () => applyModifiers(await loadModifiers())); } catch {}
  // Another instance received the click on our notification.
  try { tjs.addSignalListener('SIGUSR2', () => showWindow()); } catch {}
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
  if (id === 'about') {
    app.push('about', null);
    return showWindow();
  }
  if (id === 'notify') {
    notifyOn = !notifyOn;
    app.store.set('notify', notifyOn);
    return refreshTray();
  }
  if (id?.startsWith('mods:')) return setModifiers(id.slice(5));
  if (id === 'quit') return quit();
  if (id === 'quitAll') return quitAll();
}

export function onHotkey(id) {
  if (id === 'toggle') toggleWindow();
}

export async function onNotificationClick(id) {
  const n = parseInt(String(id).split(':')[1], 10);
  if (!n || n === slot) return showWindow();
  // Every instance shares the bundle id, so macOS may hand the click to any
  // of them: pass it on to the one that posted it.
  const pid = (await readSlots()).get(n);
  if (pid) await run(['/bin/kill', '-USR2', String(pid)]);
}

export function onWindowState(info) {
  if (info.win === 'main' && typeof info.focused === 'boolean') {
    focused = info.focused;
    if (focused) setUnseen(false);
  }
  // Popover behaviour: clicking elsewhere puts the terminal away.
  if (info.win === 'main' && info.focused === false && !pinned) win().hide();
}
