// ── State ───────────────────────────────────────────────────────────
const S = {
  apiUrl: localStorage.getItem('robot-api-url') || (location.origin + '/api'),
  token: localStorage.getItem('robot-api-token') || '',
  scopes: [],
  tokenName: '',
  schema: null,
  routes: [],
};

// ── Utility ─────────────────────────────────────────────────────────
function esc(s) {
  if (s == null) return '';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function toArr(v) {
  if (Array.isArray(v)) return v;
  if (typeof v === 'string' && v) return v.split(',').map(s => s.trim());
  return [];
}

// ── API helper ──────────────────────────────────────────────────────
async function api(method, path, body) {
  const opts = {
    method,
    headers: { 'Content-Type': 'application/json' },
  };
  if (S.token) opts.headers['Authorization'] = 'Bearer ' + S.token;
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch(S.apiUrl + path, opts);
  const ct = r.headers.get('content-type') || '';
  const data = ct.includes('json') ? await r.json() : await r.text();
  if (!r.ok) throw new Error(data.error || data || r.statusText);
  return data;
}

// ── Toast ───────────────────────────────────────────────────────────
function toast(msg, ok = true) {
  const el = document.createElement('div');
  el.className = 'toast ' + (ok ? 'ok' : 'err');
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 3000);
}

// ── Theme ───────────────────────────────────────────────────────────
function toggleTheme() {
  const light = document.documentElement.getAttribute('data-theme') === 'light';
  document.documentElement.setAttribute('data-theme', light ? 'dark' : 'light');
  localStorage.setItem('robot-theme', light ? 'dark' : 'light');
  document.getElementById('themeBtn').textContent = light ? '\u263E' : '\u2600';
}

// ── API config toggle (narrow screens) ──────────────────────────────
function toggleApiConfig() {
  document.getElementById('api-url-bar').classList.toggle('open');
}

// ── API Config ──────────────────────────────────────────────────────
function saveApiConfig() {
  const url = document.getElementById('apiUrl').value.replace(/\/+$/, '');
  const tok = document.getElementById('apiToken').value;
  if (url) { S.apiUrl = url; localStorage.setItem('robot-api-url', url); }
  if (tok) { S.token = tok; localStorage.setItem('robot-api-token', tok); }
  toast('Zapisano');
  init();
}

// ── Who am I ────────────────────────────────────────────────────────
async function showWhoami() {
  let name = '', scopes = [], mode = '';
  try {
    const who = await api('GET', '/auth/whoami');
    name = who.name || '';
    scopes = who.scopes || [];
  } catch (e) {
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.onclick = ev => { if (ev.target === overlay) overlay.remove(); };
    overlay.innerHTML = '<div class="modal"><button class="close-btn" onclick="this.closest(\'.modal-overlay\').remove()">\u00D7</button>' +
      '<h3>Kim jestem?</h3><p style="color:var(--red)">' + esc(e.message) + '</p></div>';
    document.body.appendChild(overlay);
    return;
  }
  if (name === '_open') mode = 'Tryb otwarty (brak tokenu)';
  else if (name === '_legacy') mode = 'Token legacy (pojedynczy)';
  else mode = 'Token: ' + name;

  const scopeHtml = scopes.length > 0
    ? '<ul class="scope-list">' + scopes.map(s => '<li><span class="badge blue">' + esc(s) + '</span></li>').join('') + '</ul>'
    : '<p style="color:var(--text2)">Brak zakres\u00F3w</p>';
  const allAccess = scopes.some(s => s === 'admin:all');

  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.onclick = ev => { if (ev.target === overlay) overlay.remove(); };
  overlay.innerHTML = '<div class="modal"><button class="close-btn" onclick="this.closest(\'.modal-overlay\').remove()">\u00D7</button>' +
    '<h3>Kim jestem?</h3>' +
    '<p><strong>' + esc(mode) + '</strong></p>' +
    '<h4 style="margin-top:12px;color:var(--text2)">Zakresy dost\u0119pu:</h4>' + scopeHtml +
    (allAccess ? '<p class="badge green" style="margin-top:8px">Pe\u0142ny dost\u0119p (admin:all)</p>' : '') +
    '</div>';
  document.body.appendChild(overlay);
}
