// ── Init ────────────────────────────────────────────────────────────
async function init() {
  // Restore theme
  const theme = localStorage.getItem('robot-theme') ||
    (matchMedia('(prefers-color-scheme:light)').matches ? 'light' : 'dark');
  document.documentElement.setAttribute('data-theme', theme);
  document.getElementById('themeBtn').textContent = theme === 'light' ? '\u2600' : '\u263E';
  document.getElementById('apiUrl').value = S.apiUrl;
  document.getElementById('apiToken').value = S.token;

  // Check for token in URL hash (one-time setup convenience)
  if (location.hash.startsWith('#token=')) {
    S.token = location.hash.substring(7);
    localStorage.setItem('robot-api-token', S.token);
    document.getElementById('apiToken').value = S.token;
    history.replaceState(null, '', location.pathname);
  }

  // Get identity
  try {
    const who = await api('GET', '/auth/whoami');
    S.tokenName = who.name;
    S.scopes = who.scopes || [];
    document.getElementById('whoami').textContent = who.name + ' (' + S.scopes.length + ' zakres\u00F3w)';
  } catch (e) {
    S.scopes = [];
    document.getElementById('whoami').textContent = 'brak autoryzacji';
    document.getElementById('whoami').className = 'badge red';
  }

  // Load schema
  try { S.schema = await api('GET', '/schema'); } catch (e) {}

  // Load routes
  try {
    const r = await api('GET', '/routes');
    S.routes = r.routes || [];
  } catch (e) {}

  // Reset loaded sections so they reload with new data
  Object.keys(sectionLoaded).forEach(k => sectionLoaded[k] = false);

  buildNav();
}

init();
