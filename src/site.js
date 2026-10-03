import { establishPrimitive } from "./webkit.js";
import { installWindowP } from "./utils/mem.js";

const output = document.getElementById("console");
let isExploitRunning = false;
let isJailbroken = false;
let clientIp = "";
let allPayloads = [];

// Logger with visual indicators
function writeLog(message, type = "log", replace = false) {
  if (!output) return;
  let line = replace ? output.lastElementChild : null;
  if (!line) {
    line = document.createElement("div");
    line.className = "log-line";
    output.appendChild(line);
  }

  let tag = "*";
  let tagClass = "tag-log";
  if (type === "error") {
    tag = "-";
    tagClass = "tag-error";
  } else if (type === "info" || type === "success") {
    tag = "+";
    tagClass = "tag-success";
  }

  line.innerHTML = `<span class="log-tag ${tagClass}">[${tag}]</span> <span class="log-msg ${type}">${escapeHtml(message)}</span>`;
  output.scrollTop = output.scrollHeight;
}

function escapeHtml(str) {
  return String(str).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function writeEvent(name, detail, type) {
  writeLog(detail == null || detail === "" ? name : `${name}: ${detail}`,
    type || (name === "Failed" ? "error" : "log"));
}

window.writeLog = writeLog;
window.jb = { mark: writeEvent };

async function getPrimitive() {
  writeLog("Starting WebKit exploit", "log");
  const primitive = installWindowP(await establishPrimitive(writeEvent));
  if (!primitive || typeof primitive.read8 !== "function")
    throw new Error("Memory primitive unavailable");

  writeLog("ARW ready", "success");
  return primitive;
}

function getWebKitBase() {
  const ctor = globalThis.__ps5NativeCtor;
  if (typeof ctor !== "number" || typeof OFFSET_wk_host_constructor_candidates === "undefined")
    throw new Error("WebKit base inputs are unavailable");

  for (const offset of OFFSET_wk_host_constructor_candidates) {
    const base = ctor - offset;
    if (base >= 0x800000000 && base < 0x900000000 && base % 0x4000 === 0)
      return base;
  }

  throw new Error("WebKit base not found");
}

export async function runExploit() {
  if (isExploitRunning) return;
  if (isJailbroken) {
    showToast("System already jailbroken! Use the Payloads tab.", "info");
    switchTab("tab-payloads");
    return;
  }

  isExploitRunning = true;
  updateStatus("Running Exploit...", "running");
  const runBtn = document.getElementById("btn-run-jailbreak");
  if (runBtn) {
    runBtn.disabled = true;
    runBtn.innerHTML = '<span class="spinner"></span> Running Exploit...';
  }

  try {
    const rejection = window.firmware.rejection();
    if (rejection)
      throw new Error(rejection);

    writeLog("Credits: Sonic_Iso, Jordy, ntfargo, ufm42, Dr. Yenyen, TheFlow, SlidyBat, Flatz, cow, nhk, bollarz, Sleirsgoevy, EchoStretch, EarthOnion", "info");
    writeLog(`Agent: ${navigator.userAgent}`, "info");
    writeLog(`Firmware: ${window.fw_str}`, "info");

    const primitive = await getPrimitive();
    writeLog(`WebKit base: 0x${getWebKitBase().toString(16)}`, "info");

    await import("./relapse_exploit.js");
    const result = await main(primitive);

    isJailbroken = true;
    updateStatus("Jailbroken (ELF Loader 9021 Active)", "success");
    writeLog("ELF Loader is actively listening on port 9021!", "success");
    showToast("Jailbreak successful! ELF Loader listening on port 9021.", "success");

    // Unlock and switch to Payloads tab
    const payloadTabBtn = document.querySelector('[data-tab="tab-payloads"]');
    if (payloadTabBtn) {
      payloadTabBtn.classList.add("unlocked");
    }
    setTimeout(() => {
      switchTab("tab-payloads");
    }, 1200);

  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    writeLog(msg, "error");
    updateStatus("Exploit Failed: " + msg, "error");
    showToast("Exploit error: " + msg, "error");
  } finally {
    isExploitRunning = false;
    if (runBtn) {
      runBtn.disabled = isJailbroken;
      runBtn.innerHTML = isJailbroken ? '✓ Jailbreak Complete' : '▶ Run Jailbreak';
    }
  }
}
window.runExploit = runExploit;

// Tab management
function switchTab(tabId) {
  document.querySelectorAll(".tab-content").forEach((el) => el.classList.remove("active"));
  document.querySelectorAll(".nav-tab").forEach((el) => el.classList.remove("active"));

  const targetContent = document.getElementById(tabId);
  const targetTab = document.querySelector(`[data-tab="${tabId}"]`);

  if (targetContent) targetContent.classList.add("active");
  if (targetTab) targetTab.classList.add("active");

  if (tabId === "tab-payloads") {
    loadPayloads();
  }
}

function updateStatus(text, state = "idle") {
  const pill = document.getElementById("status-pill");
  if (!pill) return;
  pill.textContent = text;
  pill.className = `status-pill state-${state}`;
}

// Toast notifications
function showToast(message, type = "info") {
  const container = document.getElementById("toast-container");
  if (!container) return;
  const toast = document.createElement("div");
  toast.className = `toast toast-${type}`;
  toast.textContent = message;
  container.appendChild(toast);
  setTimeout(() => {
    toast.classList.add("fade-out");
    setTimeout(() => toast.remove(), 400);
  }, 4500);
}

// Payloads Loader & Sender
async function loadPayloads() {
  const grid = document.getElementById("payloads-grid");
  if (!grid) return;
  grid.innerHTML = '<div class="loading-state"><span class="spinner"></span> Loading available payloads...</div>';

  try {
    const res = await fetch("/api/payloads");
    if (!res.ok) throw new Error("Failed to load payloads list");
    const data = await res.json();
    allPayloads = data.payloads || [];

    const badge = document.getElementById("payload-count-badge");
    if (badge) badge.textContent = allPayloads.length;

    renderPayloads(allPayloads);
  } catch (err) {
    grid.innerHTML = `<div class="empty-state">Could not fetch payloads: ${escapeHtml(err.message)}</div>`;
  }
}

function renderPayloads(payloads) {
  const grid = document.getElementById("payloads-grid");
  if (!grid) return;
  if (!payloads.length) {
    grid.innerHTML = '<div class="empty-state">No payloads found in the <code>payloads/</code> folder.</div>';
    return;
  }

  grid.innerHTML = "";
  payloads.forEach((item) => {
    const card = document.createElement("div");
    card.className = "payload-card";
    const isLinux = item.name.toLowerCase().includes("kexec") || item.name.toLowerCase().includes("linux");

    card.innerHTML = `
      <div class="payload-header">
        <span class="payload-ext ${item.ext === '.elf' ? 'ext-elf' : 'ext-bin'}">${item.ext.replace('.', '').toUpperCase()}</span>
        <span class="payload-size">${escapeHtml(item.formattedSize)}</span>
      </div>
      <div class="payload-name" title="${escapeHtml(item.name)}">${escapeHtml(item.name)}</div>
      ${isLinux ? '<span class="badge-linux">Linux Loader</span>' : ''}
      <button class="btn-send-payload" data-name="${escapeHtml(item.name)}">
        <span class="send-icon">🚀</span> Send to PS5
      </button>
    `;

    const sendBtn = card.querySelector(".btn-send-payload");
    sendBtn.addEventListener("click", () => sendPayload(item.name, sendBtn));
    grid.appendChild(card);
  });
}

async function sendPayload(name, buttonEl) {
  const hostInput = document.getElementById("input-console-ip");
  const portInput = document.getElementById("input-console-port");
  const host = hostInput ? hostInput.value.trim() : clientIp;
  const port = portInput ? parseInt(portInput.value.trim(), 10) : 9021;

  if (buttonEl) {
    buttonEl.disabled = true;
    buttonEl.innerHTML = '<span class="spinner"></span> Sending...';
  }

  showToast(`Sending ${name} to ${host}:${port}...`, "info");
  writeLog(`Sending payload ${name} to ${host}:${port}...`, "log");

  try {
    const res = await fetch("/api/send-payload", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, host, port }),
    });

    const data = await res.json();
    if (res.ok && data.success) {
      showToast(data.message || `Successfully sent ${name}!`, "success");
      writeLog(data.message, "success");
    } else {
      throw new Error(data.error || "Failed to send payload");
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    showToast(`Error sending ${name}: ${msg}`, "error");
    writeLog(`Error sending ${name}: ${msg}`, "error");
  } finally {
    if (buttonEl) {
      buttonEl.disabled = false;
      buttonEl.innerHTML = '<span class="send-icon">🚀</span> Send to PS5';
    }
  }
}

// Initialize UI elements
document.addEventListener("DOMContentLoaded", async () => {
  // Navigation tabs
  document.querySelectorAll(".nav-tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      const tabId = tab.getAttribute("data-tab");
      if (tabId) switchTab(tabId);
    });
  });

  // Run Jailbreak Button
  const runBtn = document.getElementById("btn-run-jailbreak");
  if (runBtn) {
    runBtn.addEventListener("click", runExploit);
  }

  // Clear Console Button
  const clearBtn = document.getElementById("btn-clear-console");
  if (clearBtn) {
    clearBtn.addEventListener("click", () => {
      if (output) output.innerHTML = "";
    });
  }

  // Refresh Payloads Button
  const refreshBtn = document.getElementById("btn-refresh-payloads");
  if (refreshBtn) {
    refreshBtn.addEventListener("click", loadPayloads);
  }

  // Filter Payloads Search
  const searchInput = document.getElementById("input-payload-search");
  if (searchInput) {
    searchInput.addEventListener("input", (e) => {
      const q = e.target.value.toLowerCase().trim();
      const filtered = allPayloads.filter((p) => p.name.toLowerCase().includes(q));
      renderPayloads(filtered);
    });
  }

  // Display detected system info
  const fwElem = document.getElementById("fw-version-display");
  if (fwElem) {
    fwElem.textContent = window.fw_str ? `PS5 Firmware ${window.fw_str}` : "PlayStation 5";
  }

  // Query server for client IP and info
  try {
    const infoRes = await fetch("/api/info");
    if (infoRes.ok) {
      const info = await infoRes.json();
      clientIp = info.clientIp || "";
      const ipInput = document.getElementById("input-console-ip");
      if (ipInput && clientIp) ipInput.value = clientIp;

      const serverIpElem = document.getElementById("server-ip-display");
      if (serverIpElem && info.serverIp) {
        serverIpElem.textContent = `Server: ${info.serverIp}`;
      }
    }
  } catch (e) {}

  // Pre-load payloads in background so the count is ready
  loadPayloads();
});