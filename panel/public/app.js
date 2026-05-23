// ── XMR Control Panel — Dashboard Frontend ──

const API = window.location.origin;
const $ = (s) => document.getElementById(s);

const els = {
  cfgWallet:       $("cfgWallet"),
  cfgPool:         $("cfgPool"),
  cfgPoolBak:      $("cfgPoolBak"),
  cfgIdleCpu:      $("cfgIdleCpu"),
  cfgActiveCpu:    $("cfgActiveCpu"),
  cfgIdleThreshold:$("cfgIdleThreshold"),
  cfgTls:          $("cfgTls"),
  cfgKill:         $("cfgKill"),
  cfgPaused:       $("cfgPaused"),
  idleCpuVal:      $("idleCpuVal"),
  activeCpuVal:    $("activeCpuVal"),
  pushStatus:      $("pushStatus"),
  btnSave:         $("btnSave"),
  btnKillAll:      $("btnKillAll"),
  btnResume:       $("btnResume"),
  btnSync:         $("btnSync"),
  btnCopy:         $("btnCopy"),
  toast:           $("toast"),
  statIdle:        $("statIdle"),
  statActive:      $("statActive"),
  statThreshold:   $("statThreshold"),
  statStatus:      $("statStatus"),
};

function toast(msg, type = "success") {
  els.toast.textContent = msg;
  els.toast.className = `toast ${type} show`;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => els.toast.classList.remove("show"), 4000);
}

function updateSlider(el) {
  const pct = ((el.value - el.min) / (el.max - el.min)) * 100;
  el.style.background = `linear-gradient(to right, rgba(139,92,246,0.5) ${pct}%, rgba(255,255,255,0.06) ${pct}%)`;
}

function updateStats() {
  els.statIdle.textContent = `${els.cfgIdleCpu.value}%`;
  els.statActive.textContent = `${els.cfgActiveCpu.value}%`;
  els.statThreshold.textContent = `${els.cfgIdleThreshold.value}s`;
  const killed = els.cfgKill.checked, paused = els.cfgPaused.checked;
  els.statStatus.textContent = killed ? "Killed" : paused ? "Paused" : "Active";
  els.statStatus.style.color = killed ? "var(--red)" : paused ? "var(--amber)" : "var(--green)";
}

async function loadConfig() {
  try {
    const c = await (await fetch(`${API}/api/config`)).json();
    els.cfgWallet.value = c.wallet || "";
    els.cfgPool.value = c.pool || "";
    els.cfgPoolBak.value = c.poolBackup || "";
    els.cfgIdleCpu.value = c.idleCpu || 100;
    els.cfgActiveCpu.value = c.activeCpu || 10;
    els.cfgIdleThreshold.value = c.idleThreshold || 120;
    els.cfgTls.checked = c.tls !== false;
    els.cfgKill.checked = !!c.killSwitch;
    els.cfgPaused.checked = !!c.paused;
    els.idleCpuVal.textContent = `${els.cfgIdleCpu.value}%`;
    els.activeCpuVal.textContent = `${els.cfgActiveCpu.value}%`;
    updateSlider(els.cfgIdleCpu);
    updateSlider(els.cfgActiveCpu);
    updateStats();
  } catch { toast("Failed to load config", "error"); }
}

async function saveConfig() {
  const btn = els.btnSave, orig = btn.textContent;
  btn.textContent = "Pushing..."; btn.disabled = true;
  els.pushStatus.textContent = "Pushing"; els.pushStatus.className = "push-pill";
  try {
    const data = await (await fetch(`${API}/api/config`, {
      method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        wallet: els.cfgWallet.value.trim(), pool: els.cfgPool.value.trim(),
        poolBackup: els.cfgPoolBak.value.trim(),
        idleCpu: parseInt(els.cfgIdleCpu.value), activeCpu: parseInt(els.cfgActiveCpu.value),
        idleThreshold: parseInt(els.cfgIdleThreshold.value),
        tls: els.cfgTls.checked, killSwitch: els.cfgKill.checked, paused: els.cfgPaused.checked,
      }),
    })).json();
    if (data.pushed) {
      toast("Config saved & pushed ✓");
      els.pushStatus.textContent = "Pushed"; els.pushStatus.className = "push-pill pushed";
    } else {
      toast("Saved locally — push failed", "error");
      els.pushStatus.textContent = "Failed"; els.pushStatus.className = "push-pill error";
    }
  } catch { toast("Connection error", "error"); els.pushStatus.textContent = "Error"; els.pushStatus.className = "push-pill error"; }
  btn.textContent = orig; btn.disabled = false; updateStats();
  setTimeout(() => { els.pushStatus.textContent = "Ready"; els.pushStatus.className = "push-pill"; }, 5000);
}

async function killAll() {
  try { const d = await (await fetch(`${API}/api/kill`,{method:"POST"})).json(); els.cfgKill.checked=true; updateStats(); toast(d.pushed?"Kill pushed ✓":"Kill saved locally",d.pushed?"success":"error"); } catch { toast("Failed","error"); }
}
async function resumeAll() {
  try { const d = await (await fetch(`${API}/api/resume`,{method:"POST"})).json(); els.cfgKill.checked=false; updateStats(); toast(d.pushed?"Resume pushed ✓":"Resume saved locally",d.pushed?"success":"error"); } catch { toast("Failed","error"); }
}
async function syncGH() {
  try { const d = await (await fetch(`${API}/api/sync`,{method:"POST"})).json(); if(d.config){await loadConfig();toast("Synced ✓")}else{toast(d.status||"Failed","error")} } catch { toast("Sync failed","error"); }
}
function copyDeploy() {
  navigator.clipboard.writeText($("deployCmd").textContent).then(()=>{
    toast("Copied ✓"); els.btnCopy.textContent="Copied!"; setTimeout(()=>els.btnCopy.textContent="Copy",2000);
  }).catch(()=>toast("Copy failed","error"));
}

els.cfgIdleCpu.addEventListener("input",()=>{ els.idleCpuVal.textContent=`${els.cfgIdleCpu.value}%`; updateSlider(els.cfgIdleCpu); updateStats(); });
els.cfgActiveCpu.addEventListener("input",()=>{ els.activeCpuVal.textContent=`${els.cfgActiveCpu.value}%`; updateSlider(els.cfgActiveCpu); updateStats(); });
els.cfgKill.addEventListener("change", updateStats);
els.cfgPaused.addEventListener("change", updateStats);
els.btnSave.addEventListener("click", saveConfig);
els.btnKillAll.addEventListener("click", killAll);
els.btnResume.addEventListener("click", resumeAll);
els.btnSync.addEventListener("click", syncGH);
els.btnCopy.addEventListener("click", copyDeploy);

loadConfig();
