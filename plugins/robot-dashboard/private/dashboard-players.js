// ── Players ─────────────────────────────────────────────────────────
sectionLoaders.players = async function() {
  if (sectionLoaded.players) return;
  sectionLoaded.players = true;
  const sec = document.getElementById('sec-players');
  sec.innerHTML = '<div class="card"><h2>Gracze</h2><div id="player-table" class="loading">Wczytywanie...</div></div>';
  try {
    const data = await api('GET', '/players');
    const el = document.getElementById('player-table');
    if (!data.items || data.items.length === 0) {
      el.innerHTML = '<div class="empty">Brak graczy</div>'; return;
    }
    el.innerHTML = '<div class="scroll-table"><table><thead><tr>' +
      '<th>Gracz</th><th>Postacie</th><th>PU Start</th></tr></thead><tbody>' +
      data.items.map(p => '<tr>' +
        '<td><strong>' + esc(p.Name || p.name || '') + '</strong></td>' +
        '<td>' + (p.Characters || p.characters || []).map(c =>
          '<span class="tag">' + esc(c.Name || c.name || c) + '</span>').join(' ') + '</td>' +
        '<td>' + esc(String(p.PUStart || p.puStart || '')) + '</td>' +
        '</tr>').join('') +
      '</tbody></table></div>' +
      '<div style="margin-top:8px;color:var(--text2)">Razem: ' + data.count + '</div>';
  } catch (e) {
    document.getElementById('player-table').innerHTML = '<div class="empty">' + esc(e.message) + '</div>';
  }
};
