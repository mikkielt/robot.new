// ── Token management ────────────────────────────────────────────────
sectionLoaders.tokens = async function() {
  if (sectionLoaded.tokens) return;
  sectionLoaded.tokens = true;
  const sec = document.getElementById('sec-tokens');
  sec.innerHTML = `<div class="card"><h2>Tokeny API</h2>
    <div id="token-list" class="loading">Wczytywanie...</div>
    <hr style="border-color:var(--border);margin:16px 0">
    <h3>Nowy token</h3>
    <div class="form-row"><label>Nazwa</label><input id="tk-name" type="text"></div>
    <div class="form-row"><label>Zakresy (po przecinku)</label><input id="tk-scopes" type="text" placeholder="session:read,session:write"></div>
    <div class="form-actions"><button onclick="createToken()" class="primary">Utw\u00F3rz</button></div>
    <div id="tk-result"></div>
  </div>`;
  loadTokens();
};

async function loadTokens() {
  const el = document.getElementById('token-list');
  try {
    const data = await api('GET', '/auth/status');
    if (!data.tokens || data.tokens.length === 0) {
      el.innerHTML = '<div class="empty">Brak token\u00F3w</div>'; return;
    }
    el.innerHTML = '<div class="scroll-table"><table><thead><tr><th>Nazwa</th><th>Zakresy</th><th>Utworzony</th><th></th></tr></thead><tbody>' +
      data.tokens.map(t => '<tr><td><strong>' + esc(t.name) + '</strong></td>' +
        '<td>' + (t.scopes || []).map(s => '<span class="badge blue">' + esc(s) + '</span> ').join('') + '</td>' +
        '<td>' + esc(t.createdAt || '') + '</td>' +
        '<td><button class="remove-btn" onclick="deleteToken(\'' + esc(t.name) + '\')">\u00D7</button></td></tr>').join('') +
      '</tbody></table></div>';
  } catch (e) { el.innerHTML = '<div class="empty">' + esc(e.message) + '</div>'; }
}

async function createToken() {
  const name = document.getElementById('tk-name').value.trim();
  const scopes = document.getElementById('tk-scopes').value.split(',').map(s => s.trim()).filter(Boolean);
  if (!name || scopes.length === 0) { toast('Podaj nazw\u0119 i zakresy', false); return; }
  try {
    const r = await api('POST', '/auth/token', { name, scopes });
    document.getElementById('tk-result').innerHTML =
      '<div class="card" style="margin-top:12px;border-color:var(--green)">' +
      '<strong>Token (skopiuj teraz!):</strong><br><code style="word-break:break-all">' +
      esc(r.token) + '</code></div>';
    document.getElementById('tk-name').value = '';
    document.getElementById('tk-scopes').value = '';
    loadTokens();
  } catch (e) { toast(e.message, false); }
}

async function deleteToken(name) {
  if (!confirm('Usun\u0105\u0107 token "' + name + '"?')) return;
  try {
    await api('DELETE', '/auth/token/' + encodeURIComponent(name));
    toast('Token usuni\u0119ty');
    loadTokens();
  } catch (e) { toast(e.message, false); }
}
