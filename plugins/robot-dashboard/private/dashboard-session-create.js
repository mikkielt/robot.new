// ── Session creation ────────────────────────────────────────────────
let nsFileList = [];  // cached .md paths for fuzzy autocomplete
let lastPreviewMarkdown = '';

sectionLoaders.newSession = async function() {
  if (sectionLoaded.newSession) return;
  sectionLoaded.newSession = true;

  // Pre-fetch file list for path autocomplete
  try {
    const r = await api('GET', '/files');
    nsFileList = r.files || [];
  } catch (e) { nsFileList = []; }

  const sec = document.getElementById('sec-newSession');
  sec.innerHTML = `
  <div class="session-layout">
    <div class="session-form">
      <div class="card">
        <h2>Nowa Sesja</h2>
        <div class="form-row"><label>Log sesji (wklej tekst)</label>
          <textarea id="ns-log" rows="8" placeholder="Wklej log sesji..."></textarea>
          <button onclick="parseLog()" style="margin-top:6px">Analizuj log</button>
        </div>
        <div id="ns-log-result"></div>
        <hr style="border-color:var(--border);margin:12px 0">
        <div class="form-row"><label>Tytu\u0142 *</label><input id="ns-title" type="text"></div>
        <div class="form-row"><label>Data *</label><input id="ns-date" type="date"></div>
        <div class="form-row"><label>Data ko\u0144cowa (opcjonalnie)</label><input id="ns-dateEnd" type="date"></div>
        <div class="form-row"><label>Narrator *</label><input id="ns-narrator" type="text"></div>
        <div class="form-row"><label>Narratorzy (metadata) <button onclick="addMultiRow('ns-narrator-list','Narrator')" style="font-size:12px;padding:2px 8px">+</button></label>
          <div id="ns-narrator-list"></div></div>
        <div class="form-row"><label>Lokacje <button onclick="addMultiRow('ns-location-list','Lokacja')" style="font-size:12px;padding:2px 8px">+</button></label>
          <div id="ns-location-list"></div></div>
        <div class="form-row"><label>Logi URL (po przecinku)</label><input id="ns-logs" type="text"></div>
        <div class="form-row"><label>Tre\u015B\u0107 (tekst)</label><textarea id="ns-content" rows="3"></textarea></div>
        <div class="form-row"><label>PU <button onclick="addPuRow()" style="font-size:12px;padding:2px 8px">+</button></label>
          <div id="ns-pu-list"></div></div>
        <div class="form-row"><label>Intel <button onclick="addIntelRow()" style="font-size:12px;padding:2px 8px">+</button></label>
          <div id="ns-intel-list"></div></div>
        <div class="form-row"><label>\u015Acie\u017Cki plik\u00F3w * <button onclick="addPathRow()" style="font-size:12px;padding:2px 8px">+</button></label>
          <div id="ns-path-list"></div></div>
        <div class="form-actions">
          <button onclick="previewSession()" class="primary">Podgl\u0105d</button>
          <button onclick="submitSession()">Utw\u00F3rz sesj\u0119</button>
          <button onclick="copyMarkdown()">Kopiuj Markdown</button>
        </div>
      </div>
    </div>
    <div class="session-preview">
      <div class="card">
        <h2>Podgl\u0105d</h2>
        <div id="ns-warnings"></div>
        <textarea id="ns-preview" class="preview-box" style="min-height:200px;width:100%;font-family:monospace;font-size:13px" placeholder="Kliknij Podgl\u0105d aby wygenerowa\u0107, potem edytuj tutaj..."></textarea>
      </div>
    </div>
  </div>`;

  // Seed with one path row by default
  addPathRow();
};

// ── Generic multi-row helper ─────────────────────────────────────
function addMultiRow(listId, placeholder) {
  const list = document.getElementById(listId);
  const row = document.createElement('div');
  row.className = 'multi-row';
  row.style.cssText = 'display:flex;gap:8px;align-items:center;margin-bottom:6px';
  row.innerHTML = '<input type="text" placeholder="' + placeholder + '" style="flex:1">' +
    '<button class="remove-btn" onclick="this.parentElement.remove()">\u00D7</button>';
  list.appendChild(row);
}

function collectMultiRows(listId) {
  return Array.from(document.querySelectorAll('#' + listId + ' .multi-row input'))
    .map(i => i.value.trim()).filter(Boolean);
}

// ── Path rows with fuzzy autocomplete ────────────────────────────
function addPathRow() {
  const list = document.getElementById('ns-path-list');
  const row = document.createElement('div');
  row.className = 'multi-row';
  row.style.cssText = 'display:flex;gap:8px;align-items:center;margin-bottom:6px;position:relative';
  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = 'np. sesje/2026-03.md';
  input.style.flex = '1';
  input.addEventListener('input', function() { showPathSuggestions(this); });
  input.addEventListener('blur', function() { setTimeout(() => { const dd = this.parentElement.querySelector('.path-dropdown'); if (dd) dd.remove(); }, 150); });
  row.appendChild(input);
  const btn = document.createElement('button');
  btn.className = 'remove-btn';
  btn.textContent = '\u00D7';
  btn.onclick = function() { row.remove(); };
  row.appendChild(btn);
  list.appendChild(row);
}

function showPathSuggestions(input) {
  const row = input.parentElement;
  let dd = row.querySelector('.path-dropdown');
  if (dd) dd.remove();
  const q = input.value.trim().toLowerCase();
  if (!q) return;
  const matches = fuzzyFilter(nsFileList, q, 8);
  if (matches.length === 0) return;
  dd = document.createElement('div');
  dd.className = 'path-dropdown';
  dd.style.cssText = 'position:absolute;top:100%;left:0;right:40px;background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);z-index:100;max-height:180px;overflow-y:auto';
  matches.forEach(m => {
    const opt = document.createElement('div');
    opt.textContent = m;
    opt.style.cssText = 'padding:4px 8px;cursor:pointer;font-size:13px';
    opt.onmouseenter = function() { this.style.background = 'var(--bg3)'; };
    opt.onmouseleave = function() { this.style.background = 'transparent'; };
    opt.onmousedown = function(e) { e.preventDefault(); input.value = m; dd.remove(); };
    dd.appendChild(opt);
  });
  row.appendChild(dd);
}

function fuzzyFilter(list, query, limit) {
  const parts = query.split(/[\s\/]+/).filter(Boolean);
  const scored = [];
  for (const item of list) {
    const lower = item.toLowerCase();
    let ok = true;
    let score = 0;
    for (const p of parts) {
      const idx = lower.indexOf(p);
      if (idx === -1) { ok = false; break; }
      score += (idx === 0 ? 2 : 1) + (p.length / lower.length);
    }
    if (ok) scored.push({ item, score });
  }
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, limit).map(s => s.item);
}

// ── Row helpers ──────────────────────────────────────────────────
async function parseLog() {
  const content = document.getElementById('ns-log').value;
  if (!content.trim()) return;
  const el = document.getElementById('ns-log-result');
  el.innerHTML = '<div class="loading">Analiza...</div>';
  try {
    const r = await api('POST', '/parse/log', { content });
    const info = [];
    if (r.Format || r.format) info.push('Format: ' + (r.Format || r.format));
    if (r.Lines || r.lines) info.push('Linii: ' + (r.Lines || r.lines).length);
    if (r.LocationSegments || r.locationSegments) {
      const segs = r.LocationSegments || r.locationSegments;
      info.push('Lokacje: ' + segs.map(s => s.Raw || s.raw || '').join(', '));
      // Populate location rows
      const list = document.getElementById('ns-location-list');
      list.innerHTML = '';
      segs.forEach(s => {
        addMultiRow('ns-location-list', 'Lokacja');
        const rows = list.querySelectorAll('.multi-row');
        rows[rows.length - 1].querySelector('input').value = s.Raw || s.raw || '';
      });
    }
    el.innerHTML = '<div class="badge green" style="margin-top:8px">' + info.join(' | ') + '</div>';
  } catch (e) {
    el.innerHTML = '<div class="badge red">' + esc(e.message) + '</div>';
  }
}

function addPuRow() {
  const list = document.getElementById('ns-pu-list');
  const row = document.createElement('div');
  row.className = 'pu-row';
  row.innerHTML = '<input type="text" placeholder="Posta\u0107"><input type="number" step="0.5" placeholder="Warto\u015B\u0107" style="max-width:100px"><button class="remove-btn" onclick="this.parentElement.remove()">\u00D7</button>';
  list.appendChild(row);
}

function addIntelRow() {
  const list = document.getElementById('ns-intel-list');
  const row = document.createElement('div');
  row.className = 'intel-row';
  row.innerHTML = '<input type="text" placeholder="Cel"><input type="text" placeholder="Wiadomo\u015B\u0107"><button class="remove-btn" onclick="this.parentElement.remove()">\u00D7</button>';
  list.appendChild(row);
}

function collectSessionData() {
  const data = {
    title: document.getElementById('ns-title').value,
    date: document.getElementById('ns-date').value,
    narrator: document.getElementById('ns-narrator').value,
  };
  const dateEnd = document.getElementById('ns-dateEnd').value;
  if (dateEnd) data.dateEnd = dateEnd;
  const narrators = collectMultiRows('ns-narrator-list');
  if (narrators.length > 0) data.metadataNarrators = narrators;
  const locs = collectMultiRows('ns-location-list');
  if (locs.length > 0) data.locations = locs;
  const logs = document.getElementById('ns-logs').value.trim();
  if (logs) data.logs = logs.split(',').map(s => s.trim()).filter(Boolean);
  const content = document.getElementById('ns-content').value.trim();
  if (content) data.content = content;

  // PU
  const puRows = document.querySelectorAll('#ns-pu-list .pu-row');
  if (puRows.length > 0) {
    data.pu = [];
    puRows.forEach(r => {
      const inputs = r.querySelectorAll('input');
      if (inputs[0].value && inputs[1].value) {
        data.pu.push({ character: inputs[0].value, value: parseFloat(inputs[1].value) });
      }
    });
    if (data.pu.length === 0) delete data.pu;
  }

  // Intel
  const intelRows = document.querySelectorAll('#ns-intel-list .intel-row');
  if (intelRows.length > 0) {
    data.intel = [];
    intelRows.forEach(r => {
      const inputs = r.querySelectorAll('input');
      if (inputs[0].value) {
        data.intel.push({ rawTarget: inputs[0].value, message: inputs[1].value || '' });
      }
    });
    if (data.intel.length === 0) delete data.intel;
  }

  return data;
}

async function previewSession() {
  const data = collectSessionData();
  if (!data.title || !data.date || !data.narrator) {
    toast('Uzupe\u0142nij tytu\u0142, dat\u0119 i narratora', false); return;
  }
  const el = document.getElementById('ns-preview');
  const warn = document.getElementById('ns-warnings');
  el.value = 'Generowanie...';
  warn.innerHTML = '';
  try {
    const r = await api('POST', '/parse/session-preview', data);
    lastPreviewMarkdown = r.markdown || '';
    el.value = lastPreviewMarkdown;
    if (r.warnings && r.warnings.length > 0) {
      warn.innerHTML = '<ul class="warn-list">' + r.warnings.map(w => '<li>' + esc(w) + '</li>').join('') + '</ul>';
    }
  } catch (e) {
    el.value = '';
    toast(e.message, false);
  }
}

async function submitSession() {
  const data = collectSessionData();
  const paths = collectMultiRows('ns-path-list');
  if (!data.title || !data.date || !data.narrator || paths.length === 0) {
    toast('Uzupe\u0142nij wymagane pola (tytu\u0142, data, narrator, \u015Bcie\u017Cka)', false); return;
  }
  data.path = paths;
  if (!confirm('Utworzy\u0107 sesj\u0119 "' + data.title + '"?')) return;
  try {
    const r = await api('POST', '/sessions', data);
    toast('Sesja utworzona! Nag\u0142\u00F3wki: ' + (r.headers || []).join(', '));
    sectionLoaded.sessions = false;
  } catch (e) { toast(e.message, false); }
}

function copyMarkdown() {
  const md = document.getElementById('ns-preview').value || lastPreviewMarkdown;
  if (!md) { toast('Najpierw wygeneruj podgl\u0105d', false); return; }
  navigator.clipboard.writeText(md).then(
    () => toast('Skopiowano do schowka'),
    () => toast('Nie uda\u0142o si\u0119 skopiowa\u0107', false)
  );
}
