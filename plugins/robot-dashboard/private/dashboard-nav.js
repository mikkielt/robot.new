// ── Section definitions ─────────────────────────────────────────────
const SECTIONS = [
  { id: 'sessions',   label: 'Sesje',        scope: 'session:read' },
  { id: 'newSession', label: 'Nowa Sesja',    scope: 'session:write' },
  { id: 'entities',   label: 'Encje',         scope: 'entity:read' },
  { id: 'players',    label: 'Gracze',        scope: 'player:read' },
  { id: 'reports',    label: 'Raporty',       scope: 'admin:read' },
  { id: 'tokens',     label: 'Tokeny',        scope: 'auth:manage' },
];

function hasScope(s) {
  if (!s) return true;
  return S.scopes.some(sc => sc === s || sc === 'admin:all' ||
    (s.endsWith(':read') && sc === s.replace(':read', ':write')));
}

// ── Navigation ──────────────────────────────────────────────────────
const sectionLoaders = {};
const sectionLoaded = {};
let currentSection = '';

function buildNav() {
  const nav = document.getElementById('nav');
  const main = document.getElementById('main');
  nav.innerHTML = '';
  main.innerHTML = '';

  const visible = SECTIONS.filter(s => hasScope(s.scope));
  visible.forEach(s => {
    const btn = document.createElement('button');
    btn.textContent = s.label;
    btn.onclick = () => showSection(s.id);
    btn.id = 'nav-' + s.id;
    nav.appendChild(btn);

    const div = document.createElement('div');
    div.id = 'sec-' + s.id;
    div.className = 'section';
    main.appendChild(div);
  });

  if (visible.length > 0) showSection(visible[0].id);
}

function showSection(id) {
  currentSection = id;
  document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
  const btn = document.getElementById('nav-' + id);
  const sec = document.getElementById('sec-' + id);
  if (btn) btn.classList.add('active');
  if (sec) sec.classList.add('active');
  // Lazy load section content
  const loader = sectionLoaders[id];
  if (loader) loader();
}
