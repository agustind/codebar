const $ = (id) => document.getElementById(id);

const term = new Terminal({
  // Nerd Fonts first so prompt glyphs (starship, p10k…) render.
  fontFamily: '"JetBrainsMono Nerd Font Mono", "FiraCode Nerd Font Mono", "MesloLGS NF", "Symbols Nerd Font Mono", "SF Mono", Menlo, monospace',
  fontSize: 12.5,
  lineHeight: 1.15,
  cursorBlink: true,
  macOptionIsMeta: true,
  macOptionClickForcesSelection: true,
  allowProposedApi: true,
  scrollback: 10000,
  theme: {
    background: '#16181d',
    foreground: '#d8dce4',
    cursor: '#d97757',
    selectionBackground: '#3a4150',
    black: '#1e2128', brightBlack: '#5c6370',
    red: '#e06c75', brightRed: '#ff7b86',
    green: '#98c379', brightGreen: '#b5e890',
    yellow: '#e5c07b', brightYellow: '#ffd88f',
    blue: '#61afef', brightBlue: '#7cc4ff',
    magenta: '#c678dd', brightMagenta: '#dc90f0',
    cyan: '#56b6c2', brightCyan: '#6fd3e0',
    white: '#d8dce4', brightWhite: '#ffffff',
  },
});

const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.loadAddon(new WebLinksAddon.WebLinksAddon((_e, url) => tiny.api.call('openUrl', { url })));
term.open($('term'));

// OSC 7 (file://host/path): the current directory, reported by the pty
// helper (and by shells configured to emit it).
term.parser.registerOscHandler(7, (data) => {
  try {
    const path = decodeURIComponent(new URL(data).pathname);
    if (path) showFolder(path);
  } catch {}
  return true;
});

let session = 0;
let exited = false;

const call = (m, p) => tiny.api.call(m, p).catch((e) => console.error(m, e));
const size = () => ({ rows: term.rows, cols: term.cols });

// ---- output -------------------------------------------------------------

tiny.api.on('pty-data', ({ session: id, data }) => {
  if (id === session) term.write(data);
});

tiny.api.on('pty-exit', ({ session: id, code, signal }) => {
  if (id !== session) return;
  exited = true;
  $('exitMsg').textContent = signal ? `Session ended (${signal})` : `Session ended (exit ${code})`;
  $('exited').hidden = false;
});

tiny.api.on('session-reset', ({ cwd }) => {
  showFolder(cwd);
  term.reset();
  exited = false;
  $('exited').hidden = true;
  // The backend bumped its session id; pick it up without replaying.
  call('attach', size()).then((r) => { if (r) session = r.session; });
});

tiny.api.on('focus-terminal', () => requestAnimationFrame(() => {
  fit.fit();
  if ($('about').hidden) term.focus();
  else $('aboutClose').focus();
}));

tiny.api.on('pinned', ({ value }) => $('pin').classList.toggle('on', value));

tiny.api.on('about', () => showAbout(true));

tiny.api.on('hotkey', ({ label }) => { $('hotkey').textContent = label || ''; });

// ---- input --------------------------------------------------------------

term.onData((data) => {
  if (exited) {
    if (data === '\r') restart();
    return;
  }
  call('input', { data });
});

term.onResize(({ rows, cols }) => call('resize', { rows, cols }));

term.attachCustomKeyEventHandler((e) => {
  if (e.type !== 'keydown') return true;
  if (e.key === 'Escape' && !$('about').hidden) {
    showAbout(false);
    return false;
  }
  // Shift+Enter = newline in Claude Code (what /terminal-setup configures
  // elsewhere): send ESC+CR, the same as Option+Enter.
  if (e.key === 'Enter' && e.shiftKey && !e.metaKey && !e.ctrlKey) {
    call('input', { data: '\x1b\r' });
    return false;
  }
  if (!e.metaKey) return true;
  switch (e.key.toLowerCase()) {
    case 'c':
      if (term.hasSelection()) {
        tiny.clipboard.write({ text: term.getSelection() });
        return false;
      }
      return true;
    case 'k': term.clear(); return false;
    case 'n': call('newInstance'); return false;
    case 'o': chooseFolder(); return false;
    case 'w': call('hide'); return false;
    case '=': case '+': zoom(1); return false;
    case '-': zoom(-1); return false;
    case '0': zoom(0); return false;
  }
  return true; // ⌘V etc. go to the Edit menu → xterm's paste handler
});

function zoom(dir) {
  term.options.fontSize = dir === 0 ? 12.5 : Math.max(8, Math.min(24, term.options.fontSize + dir));
  fit.fit();
}

// ---- header -------------------------------------------------------------

function showFolder(cwd) {
  const home = cwd.match(/^\/Users\/[^/]+/)?.[0];
  $('folder').textContent = home && cwd.startsWith(home) ? '~' + cwd.slice(home.length) : cwd;
  $('folder').title = cwd + ' — change folder (⌘O)';
}

async function chooseFolder() {
  const dir = await tiny.dialog.pickFolder();
  if (dir) call('setFolder', { dir });
  term.focus();
}

async function restart() {
  exited = false;
  $('exited').hidden = true;
  term.reset();
  const r = await call('restart', size());
  if (r) session = r.session;
  term.focus();
}

function showAbout(show) {
  $('about').hidden = !show;
  if (show) $('aboutClose').focus();
  else term.focus();
}

$('aboutClose').onclick = () => showAbout(false);
$('about').onclick = (e) => { if (e.target === $('about')) showAbout(false); };
$('about').onkeydown = (e) => { if (e.key === 'Escape') showAbout(false); };
document.querySelectorAll('[data-url]').forEach((a) => {
  a.onclick = (e) => {
    e.preventDefault();
    call('openUrl', { url: a.dataset.url });
  };
});

$('folder').onclick = chooseFolder;
$('restart').onclick = restart;
$('add').onclick = () => call('newInstance');
$('pin').onclick = async () => {
  const on = !$('pin').classList.contains('on');
  $('pin').classList.toggle('on', on);
  await call('setPinned', { value: on });
  term.focus();
};

// ---- boot ---------------------------------------------------------------

new ResizeObserver(() => fit.fit()).observe($('term'));

(async () => {
  fit.fit();
  const r = await call('attach', size());
  if (!r) return;
  session = r.session;
  $('slot').textContent = r.slot;
  $('pin').classList.toggle('on', r.pinned);
  $('hotkey').textContent = r.hotkey || '';
  showFolder(r.cwd);
  $('aboutVersion').textContent = 'Version ' + r.version;
  document.title = `codebar ${r.slot}`;
  if (r.replay) term.write(r.replay);
  if (r.exited) {
    exited = true;
    $('exited').hidden = false;
  }
  // Session may have started at a stale size (e.g. after a reload).
  call('resize', size());
  term.focus();
})();
