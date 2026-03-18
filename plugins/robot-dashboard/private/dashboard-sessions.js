// ── Sessions browser ────────────────────────────────────────────────
sectionLoaders.sessions = async function() {
  if (sectionLoaded.sessions) return;
  sectionLoaded.sessions = true;
  const sec = document.getElementById('sec-sessions');
  sec.innerHTML = '<div class="card"><h2>Sesje</h2><div class="filter-bar">' +
    '<input type="date" id="sess-min" placeholder="Od">' +
    '<input type="date" id="sess-max" placeholder="Do">' +
    '<button onclick="loadSessions()">Filtruj</button>' +
    '<button onclick="loadSessions(true)">Wczytaj wszystkie</button></div>' +
    '<div id="sess-table" class="loading">Wczytywanie...</div></div>';
  loadSessions(true);
};

async function loadSessions(all) {
  const el = document.getElementById('sess-table');
  el.innerHTML = '<div class="loading">Wczytywanie...</div>';
  try {
    let q = '';
    if (!all) {
      const min = document.getElementById('sess-min').value;
      const max = document.getElementById('sess-max').value;
      if (min) q += '&minDate=' + min;
      if (max) q += '&maxDate=' + max;
    }
    const data = await api('GET', '/sessions?labels=true' + q);
    if (!data.items || data.items.length === 0) {
      el.innerHTML = '<div class="empty">Brak sesji</div>';
      return;
    }
    el.innerHTML = '<div class="scroll-table"><table><thead><tr>' +
      '<th>Data</th><th>Tytu\u0142</th><th>Narrator</th><th>Format</th><th>Lokacje</th>' +
      '</tr></thead><tbody>' +
      data.items.map(s => '<tr>' +
        '<td>' + esc(s.Date || s.date || '') + '</td>' +
        '<td>' + esc(s.Title || s.title || '') + '</td>' +
        '<td>' + esc(s.Narrator || s.narrator || '') + '</td>' +
        '<td><span class="badge blue">' + esc(s.formatLabel || s.Format || s.format || '') + '</span></td>' +
        '<td>' + toArr(s.Locations || s.locations).map(l => '<span class="tag">' + esc(l) + '</span>').join(' ') + '</td>' +
        '</tr>').join('') +
      '</tbody></table></div>' +
      '<div style="margin-top:8px;color:var(--text2)">Razem: ' + data.count + '</div>';
  } catch (e) { el.innerHTML = '<div class="empty">' + esc(e.message) + '</div>'; }
}
