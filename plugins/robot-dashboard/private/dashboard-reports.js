// ── Reports ─────────────────────────────────────────────────────────
sectionLoaders.reports = async function() {
  if (sectionLoaded.reports) return;
  sectionLoaded.reports = true;
  const sec = document.getElementById('sec-reports');
  sec.innerHTML = `<div class="card"><h2>Raporty i walidacja</h2>
    <div class="tab-bar">
      <button class="active" onclick="showReportTab('validate',this)">Walidacja</button>
      <button onclick="showReportTab('economy',this)">Ekonomia</button>
      <button onclick="showReportTab('graph',this)">Sesje</button>
    </div>
    <div id="report-validate" class="report-tab">
      <div class="grid">
        <div class="card"><h3>PU</h3><button onclick="runReport('/validate/pu','rpt-pu')">Sprawd\u017A</button><div id="rpt-pu"></div></div>
        <div class="card"><h3>Waluty</h3><button onclick="runReport('/validate/currency','rpt-cur')">Sprawd\u017A</button><div id="rpt-cur"></div></div>
        <div class="card"><h3>Sesje</h3><button onclick="runReport('/validate/sessions','rpt-sess')">Sprawd\u017A</button><div id="rpt-sess"></div></div>
        <div class="card"><h3>Graf sesji</h3><button onclick="runReport('/validate/graph','rpt-graph')">Sprawd\u017A</button><div id="rpt-graph"></div></div>
      </div>
    </div>
    <div id="report-economy" class="report-tab" style="display:none">
      <button onclick="runReport('/economy/snapshot','rpt-eco')">Za\u0142aduj snapshot</button>
      <div id="rpt-eco" style="margin-top:12px"></div>
    </div>
    <div id="report-graph" class="report-tab" style="display:none">
      <div class="filter-bar">
        <input id="lb-type" type="text" placeholder="Typ encji">
        <input id="lb-top" type="number" placeholder="Top N" value="10">
        <button onclick="loadLeaderboard()">Leaderboard</button>
      </div>
      <div id="rpt-lb" style="margin-top:12px"></div>
    </div>
  </div>`;
};

function showReportTab(id, btn) {
  document.querySelectorAll('.report-tab').forEach(t => t.style.display = 'none');
  document.querySelectorAll('.tab-bar button').forEach(b => b.classList.remove('active'));
  document.getElementById('report-' + id).style.display = 'block';
  if (btn) btn.classList.add('active');
}

async function runReport(endpoint, targetId) {
  const el = document.getElementById(targetId);
  el.innerHTML = '<div class="loading">Sprawdzanie...</div>';
  try {
    const data = await api('GET', endpoint);
    const items = data.items || [];
    if (items.length === 0) {
      el.innerHTML = '<span class="badge green">OK - brak problem\u00F3w</span>';
    } else {
      el.innerHTML = '<span class="badge yellow">' + items.length + ' wynik\u00F3w</span>' +
        '<pre style="margin-top:8px;font-size:12px;max-height:300px;overflow:auto">' +
        esc(JSON.stringify(items, null, 2)) + '</pre>';
    }
  } catch (e) { el.innerHTML = '<span class="badge red">' + esc(e.message) + '</span>'; }
}

async function loadLeaderboard() {
  const el = document.getElementById('rpt-lb');
  el.innerHTML = '<div class="loading">Wczytywanie...</div>';
  try {
    let q = '?';
    const t = document.getElementById('lb-type').value.trim();
    const n = document.getElementById('lb-top').value;
    if (t) q += 'type=' + encodeURIComponent(t) + '&';
    if (n) q += 'top=' + n;
    const data = await api('GET', '/session-graph/leaderboard' + q);
    if (!data.items || data.items.length === 0) {
      el.innerHTML = '<div class="empty">Brak danych</div>'; return;
    }
    el.innerHTML = '<div class="scroll-table"><table><thead><tr><th>#</th><th>Encja</th><th>Sesje</th></tr></thead><tbody>' +
      data.items.map((e, i) => '<tr><td>' + (i + 1) + '</td><td>' +
        esc(e.EntityName || e.entityName || e.Name || '') + '</td><td><strong>' +
        (e.SessionCount || e.sessionCount || 0) + '</strong></td></tr>').join('') +
      '</tbody></table></div>';
  } catch (e) { el.innerHTML = '<div class="empty">' + esc(e.message) + '</div>'; }
}
