// ── Entities browser ────────────────────────────────────────────────
sectionLoaders.entities = async function() {
  if (sectionLoaded.entities) return;
  sectionLoaded.entities = true;
  const sec = document.getElementById('sec-entities');
  sec.innerHTML = '<div class="card"><h2>Encje</h2><div class="filter-bar">' +
    '<input id="ent-filter" type="text" placeholder="Filtr RSQL (np. type==Posta\u0107)">' +
    '<input id="ent-sort" type="text" placeholder="Sortowanie (np. -name)">' +
    '<input id="ent-fields" type="text" placeholder="Pola (np. name,type,status)">' +
    '<select id="ent-labels"><option value="false">Bez etykiet</option><option value="true">Z etykietami</option></select>' +
    '<button onclick="loadEntities()">Szukaj</button></div>' +
    '<div id="ent-table" class="loading">Wczytywanie...</div></div>';
  loadEntities();
};

async function loadEntities() {
  const el = document.getElementById('ent-table');
  el.innerHTML = '<div class="loading">Wczytywanie...</div>';
  try {
    let q = '?pageSize=100';
    const f = document.getElementById('ent-filter').value.trim();
    const s = document.getElementById('ent-sort').value.trim();
    const fl = document.getElementById('ent-fields').value.trim();
    const lb = document.getElementById('ent-labels').value;
    if (f) q += '&filter=' + encodeURIComponent(f);
    if (s) q += '&sort=' + encodeURIComponent(s);
    if (fl) q += '&fields=' + encodeURIComponent(fl);
    if (lb === 'true') q += '&labels=true';
    const data = await api('GET', '/entities' + q);
    if (!data.items || data.items.length === 0) {
      el.innerHTML = '<div class="empty">Brak encji</div>'; return;
    }
    const cols = fl ? fl.split(',').map(c => c.trim()) : ['name','type','status','location','owner'];
    el.innerHTML = '<div class="scroll-table"><table><thead><tr>' +
      cols.map(c => '<th>' + esc(c) + '</th>').join('') +
      '</tr></thead><tbody>' +
      data.items.map(e => '<tr>' + cols.map(c => {
        let v = e[c] || e[c.charAt(0).toUpperCase() + c.slice(1)] || '';
        if (Array.isArray(v)) v = v.join(', ');
        return '<td>' + esc(String(v)) + '</td>';
      }).join('') + '</tr>').join('') +
      '</tbody></table></div>' +
      '<div style="margin-top:8px;color:var(--text2)">Pokazano: ' + data.items.length + ' / ' + data.count +
      (data.hasMore ? ' (wi\u0119cej dost\u0119pnych)' : '') + '</div>';
  } catch (e) { el.innerHTML = '<div class="empty">' + esc(e.message) + '</div>'; }
}
