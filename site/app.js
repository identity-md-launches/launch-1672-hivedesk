/* HiveDesk public site. Read-only: it queries the live contracts and renders their events. */
(function () {
  "use strict";
  const { ethers } = window;
  const cfg = window.HIVEDESK_CONFIG;
  const WAD = 10n ** 18n;

  const ABI = {
    vault: [
      "event Deposited(address indexed depositor, uint256 assets, uint256 shares)",
      "event Withdrawn(address indexed depositor, address indexed receiver, uint256 shares, uint256 assets)",
      "event Allocated(uint256 indexed strategyId, bytes32 indexed decisionHash, uint256 amount)",
      "event TradeSettled(uint256 indexed strategyId, uint256 principal, uint256 returned, int256 pnl)",
      "function totalAssets() view returns (uint256)",
      "function idleBalance() view returns (uint256)",
      "function deployedCapital() view returns (uint256)",
      "function navPerShare() view returns (uint256)",
      "function realizedPnl() view returns (int256)",
      "function strategyWallet() view returns (address)",
    ],
    registry: [
      "event StrategyProposed(uint256 indexed id, bytes32 indexed decisionHash, address indexed executor, uint256 timestamp)",
      "function count() view returns (uint256)",
    ],
    tracker: [
      "event BenchmarkSnapshot(uint256 indexed epoch, uint256 blockNumber, uint256 btcPrice, uint256 equityPrice, bool heads, uint256 btcNav, uint256 equityNav, uint256 flipNav)",
      "function startBlock() view returns (uint256)",
      "function currentEpoch() view returns (uint256)",
      "function snapshotCount() view returns (uint256)",
    ],
    oracle: [
      "event Published(uint256 indexed epoch, uint256 deskNav, uint256 btcNav, uint256 equityNav, uint256 flipNav, bytes32 reportHash, address submitter)",
      "function publishedCount() view returns (uint256)",
      "function startBlock() view returns (uint256)",
    ],
    token: ["function totalSupply() view returns (uint256)", "function symbol() view returns (string)"],
  };

  const SERIES = [
    { key: "deskNav", label: "Desk", color: "var(--s1)" },
    { key: "btcNav", label: "Hold BTC", color: "var(--s2)" },
    { key: "equityNav", label: "Hold equity index (SPY)", color: "var(--s3)" },
    { key: "flipNav", label: "Coin flip", color: "var(--s4)" },
  ];

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");
  const fmtNav = (x) => (Number(x) / 1e18).toFixed(4);
  const fmtEth = (x) => (Number(x) / 1e18).toFixed(4) + " ETH";
  const fmtUsd8 = (x) => "$" + (Number(x) / 1e8).toLocaleString(undefined, { maximumFractionDigits: 2 });
  const pct = (x) => {
    const v = (Number(x) / 1e18 - 1) * 100;
    return (v >= 0 ? "+" : "") + v.toFixed(2) + "%";
  };
  const txLink = (hash) => `<a href="${cfg.explorer}/tx/${hash}#eventlog" target="_blank" rel="noopener">${short(hash)}</a>`;
  const addrLink = (a) => `<a href="${cfg.explorer}/address/${a}" target="_blank" rel="noopener" class="mono">${short(a)}</a>`;
  const blockLink = (n) => `<a href="${cfg.explorer}/block/${n}" target="_blank" rel="noopener">${n}</a>`;

  function readParams() {
    const q = new URLSearchParams(location.search);
    for (const k of ["token", "registry", "vault", "tracker", "oracle"]) {
      if (q.get(k)) cfg.contracts[k] = q.get(k);
    }
    if (q.get("rpc")) cfg.rpcUrl = q.get("rpc");
  }

  const verifyItems = [];
  function verify(label, value, log) {
    verifyItems.push({ label, value, log });
  }

  async function getLogs(contract, filter, fromBlock, toBlock) {
    const out = [];
    for (let from = fromBlock; from <= toBlock; from += cfg.logChunk) {
      const to = Math.min(toBlock, from + cfg.logChunk - 1);
      const logs = await contract.queryFilter(filter, from, to);
      out.push(...logs);
    }
    return out;
  }

  async function load() {
    verifyItems.length = 0;
    $("rpc").value = cfg.rpcUrl;
    const configured = Object.values(cfg.contracts).every((a) => ethers.isAddress(a));
    $("unconfigured").classList.toggle("hidden", configured);
    $("addresses").innerHTML = Object.entries(cfg.contracts)
      .map(([k, a]) => `${k}: ${ethers.isAddress(a) ? addrLink(a) + " " + a : '<span class="muted">not set</span>'}`)
      .join("<br/>");
    if (!configured) {
      $("conn").textContent = "waiting for addresses";
      renderChart([]);
      return;
    }
    const provider = new ethers.JsonRpcProvider(cfg.rpcUrl, cfg.chainId, { staticNetwork: true });
    const head = await provider.getBlockNumber();
    $("conn").textContent = `chain ${cfg.chainId}, block ${head}`;

    const vault = new ethers.Contract(cfg.contracts.vault, ABI.vault, provider);
    const registry = new ethers.Contract(cfg.contracts.registry, ABI.registry, provider);
    const tracker = new ethers.Contract(cfg.contracts.tracker, ABI.tracker, provider);
    const oracle = new ethers.Contract(cfg.contracts.oracle, ABI.oracle, provider);

    const startBlock = Number(await tracker.startBlock());
    const from = cfg.startBlock || startBlock;

    const [published, snapshots, allocations, settlements, proposals, totalAssets, idle, deployed, navPerShare, pnl, strategyWallet, currentEpoch] =
      await Promise.all([
        getLogs(oracle, oracle.filters.Published(), from, head),
        getLogs(tracker, tracker.filters.BenchmarkSnapshot(), from, head),
        getLogs(vault, vault.filters.Allocated(), from, head),
        getLogs(vault, vault.filters.TradeSettled(), from, head),
        getLogs(registry, registry.filters.StrategyProposed(), from, head),
        vault.totalAssets(),
        vault.idleBalance(),
        vault.deployedCapital(),
        vault.navPerShare(),
        vault.realizedPnl(),
        vault.strategyWallet(),
        tracker.currentEpoch(),
      ]);

    renderTiles(published, { totalAssets, idle, deployed, navPerShare, pnl, strategyWallet, currentEpoch, startBlock });
    const rows = published
      .map((l) => ({ epoch: Number(l.args.epoch), deskNav: l.args.deskNav, btcNav: l.args.btcNav, equityNav: l.args.equityNav, flipNav: l.args.flipNav, reportHash: l.args.reportHash, log: l }))
      .sort((a, b) => a.epoch - b.epoch);
    renderChart(rows);
    renderNavTable(rows);
    renderTrades(allocations, settlements, proposals);
    renderStrategies(proposals);
    renderSnapshots(snapshots);
    renderVerify();
  }

  function renderTiles(published, live) {
    const latest = published.length ? published.reduce((a, b) => (Number(b.args.epoch) > Number(a.args.epoch) ? b : a)) : null;
    const tiles = SERIES.map((s, i) => {
      const v = latest ? latest.args[s.key] : null;
      if (latest) verify(`${s.label} NAV, epoch ${latest.args.epoch}`, fmtNav(v), latest);
      return `<div class="tile"><div class="label"><span class="swatch" style="background:${s.color}"></span>${esc(s.label)}</div>
        <div class="value">${v === null ? "—" : fmtNav(v)}</div>
        <div class="delta ${v === null ? "" : Number(v) >= 1e18 ? "up" : "down"}">${v === null ? "no publication yet" : pct(v) + " since start"}</div></div>`;
    });
    tiles.push(`<div class="tile"><div class="label">Desk total assets (live)</div><div class="value">${fmtEth(live.totalAssets)}</div>
      <div class="delta">idle ${fmtEth(live.idle)} · out trading ${fmtEth(live.deployed)}</div></div>`);
    tiles.push(`<div class="tile"><div class="label">Realised P&amp;L (live)</div><div class="value ${Number(live.pnl) >= 0 ? "" : ""}">${(Number(live.pnl) / 1e18).toFixed(4)} ETH</div>
      <div class="delta">NAV/share ${fmtNav(live.navPerShare * 1000n)} per 1000 shares · epoch ${live.currentEpoch} · strategy ${addrLink(live.strategyWallet)}</div></div>`);
    $("tiles").innerHTML = tiles.join("");
  }

  function renderChart(rows) {
    const svg = $("chart");
    const tip = $("tooltip");
    $("legend").innerHTML = SERIES.map((s) => `<span><span class="swatch" style="background:${s.color}"></span>${esc(s.label)}</span>`).join("");
    svg.innerHTML = "";
    $("chartEmpty").classList.toggle("hidden", rows.length > 0);
    if (!rows.length) return;
    const W = 1000, H = 320, m = { t: 16, r: 150, b: 32, l: 56 };
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    const xs = rows.map((r) => r.epoch);
    const vals = rows.flatMap((r) => SERIES.map((s) => Number(r[s.key]) / 1e18));
    const x0 = Math.min(...xs), x1 = Math.max(...xs);
    let y0 = Math.min(...vals, 1), y1 = Math.max(...vals, 1);
    const pad = (y1 - y0) * 0.1 || 0.05;
    y0 -= pad; y1 += pad;
    const X = (e) => m.l + ((e - x0) / Math.max(1, x1 - x0)) * (W - m.l - m.r);
    const Y = (v) => m.t + (1 - (v - y0) / (y1 - y0)) * (H - m.t - m.b);
    const ns = "http://www.w3.org/2000/svg";
    const el = (tag, attrs, text) => {
      const n = document.createElementNS(ns, tag);
      for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
      if (text !== undefined) n.textContent = text;
      svg.appendChild(n);
      return n;
    };
    // gridlines and y axis labels
    const ticks = 5;
    for (let i = 0; i <= ticks; i++) {
      const v = y0 + ((y1 - y0) * i) / ticks;
      el("line", { x1: m.l, x2: W - m.r, y1: Y(v), y2: Y(v), stroke: "var(--grid)", "stroke-width": 1 });
      el("text", { x: m.l - 8, y: Y(v) + 4, "text-anchor": "end", fill: "var(--muted)", "font-size": 11 }, v.toFixed(3));
    }
    // baseline at 1.000
    el("line", { x1: m.l, x2: W - m.r, y1: Y(1), y2: Y(1), stroke: "var(--axis)", "stroke-width": 1, "stroke-dasharray": "3 3" });
    // x axis labels
    const step = Math.max(1, Math.ceil(rows.length / 8));
    rows.forEach((r, i) => {
      if (i % step === 0 || i === rows.length - 1) {
        el("text", { x: X(r.epoch), y: H - 10, "text-anchor": "middle", fill: "var(--muted)", "font-size": 11 }, "epoch " + r.epoch);
      }
    });
    // series
    SERIES.forEach((s) => {
      const d = rows.map((r, i) => `${i ? "L" : "M"}${X(r.epoch).toFixed(1)},${Y(Number(r[s.key]) / 1e18).toFixed(1)}`).join(" ");
      el("path", { d, fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round" });
      const last = rows[rows.length - 1];
      const ly = Y(Number(last[s.key]) / 1e18);
      el("circle", { cx: X(last.epoch), cy: ly, r: 4, fill: s.color, stroke: "var(--surface)", "stroke-width": 2 });
      el("text", { x: X(last.epoch) + 10, y: ly + 4, fill: "var(--ink-2)", "font-size": 12 }, `${s.label} ${fmtNav(last[s.key])}`);
    });
    // hover crosshair + tooltip
    const cross = el("line", { x1: 0, x2: 0, y1: m.t, y2: H - m.b, stroke: "var(--axis)", "stroke-width": 1, opacity: 0 });
    svg.onmousemove = (ev) => {
      const rect = svg.getBoundingClientRect();
      const px = ((ev.clientX - rect.left) / rect.width) * W;
      let best = rows[0];
      for (const r of rows) if (Math.abs(X(r.epoch) - px) < Math.abs(X(best.epoch) - px)) best = r;
      cross.setAttribute("x1", X(best.epoch)); cross.setAttribute("x2", X(best.epoch)); cross.setAttribute("opacity", 1);
      tip.style.display = "block";
      tip.style.left = Math.min(rect.width - 200, (X(best.epoch) / W) * rect.width + 12) + "px";
      tip.style.top = "12px";
      tip.innerHTML = `<strong>Epoch ${best.epoch}</strong> · block ${best.log.blockNumber}<table>${SERIES.map((s) => `<tr><td><span class="swatch" style="background:${s.color}"></span></td><td>${esc(s.label)}</td><td class="num">${fmtNav(best[s.key])}</td></tr>`).join("")}</table>`;
    };
    svg.onmouseleave = () => { cross.setAttribute("opacity", 0); tip.style.display = "none"; };
  }

  function renderNavTable(rows) {
    if (!rows.length) { $("navTable").innerHTML = ""; return; }
    $("navTable").innerHTML = `<table><thead><tr><th>Epoch</th><th>Block</th>${SERIES.map((s) => `<th class="num">${esc(s.label)}</th>`).join("")}<th>Report hash</th><th>Tx</th></tr></thead><tbody>${rows
      .map((r) => `<tr><td>${r.epoch}</td><td>${blockLink(r.log.blockNumber)}</td>${SERIES.map((s) => `<td class="num">${fmtNav(r[s.key])}</td>`).join("")}<td class="mono">${short(r.reportHash)}</td><td>${txLink(r.log.transactionHash)}</td></tr>`)
      .join("")}</tbody></table>`;
  }

  function renderTrades(allocations, settlements, proposals) {
    const hashById = new Map(proposals.map((p) => [p.args.id.toString(), p.args.decisionHash]));
    const settledById = new Map(settlements.map((s) => [s.args.strategyId.toString(), s]));
    const rows = allocations
      .slice()
      .sort((a, b) => b.blockNumber - a.blockNumber || b.index - a.index)
      .map((a) => {
        const id = a.args.strategyId.toString();
        const s = settledById.get(id);
        verify(`Trade #${id} allocated`, fmtEth(a.args.amount), a);
        if (s) verify(`Trade #${id} settled`, `${fmtEth(s.args.returned)} returned, P&L ${(Number(s.args.pnl) / 1e18).toFixed(4)} ETH`, s);
        const pnl = s ? Number(s.args.pnl) / 1e18 : null;
        return `<tr><td>${id}</td><td class="mono">${short(hashById.get(id) || a.args.decisionHash)}</td><td class="num">${fmtEth(a.args.amount)}</td>
          <td>${blockLink(a.blockNumber)} · ${txLink(a.transactionHash)}</td>
          <td>${s ? `${fmtEth(s.args.returned)} · ${blockLink(s.blockNumber)} · ${txLink(s.transactionHash)}` : '<span class="muted">open</span>'}</td>
          <td class="num ${pnl === null ? "" : pnl >= 0 ? "delta up" : "delta down"}">${pnl === null ? "—" : (pnl >= 0 ? "+" : "") + pnl.toFixed(4)}</td></tr>`;
      });
    $("trades").innerHTML = rows.length
      ? `<table><thead><tr><th>Strategy</th><th>Decision hash</th><th class="num">Allocated</th><th>Allocation event</th><th>Settlement event</th><th class="num">P&amp;L (ETH)</th></tr></thead><tbody>${rows.join("")}</tbody></table>`
      : '<p class="muted">No trades yet.</p>';
  }

  function renderStrategies(proposals) {
    const rows = proposals
      .slice()
      .sort((a, b) => Number(b.args.id) - Number(a.args.id))
      .map((p) => {
        verify(`Strategy #${p.args.id} proposed`, short(p.args.decisionHash), p);
        return `<tr><td>${p.args.id}</td><td class="mono">${p.args.decisionHash}</td><td>${addrLink(p.args.executor)}</td><td>${new Date(Number(p.args.timestamp) * 1000).toISOString().replace("T", " ").slice(0, 19)} UTC</td><td>${txLink(p.transactionHash)}</td></tr>`;
      });
    $("strategies").innerHTML = rows.length
      ? `<table><thead><tr><th>Id</th><th>Decision hash</th><th>Executor</th><th>Time</th><th>Tx</th></tr></thead><tbody>${rows.join("")}</tbody></table>`
      : '<p class="muted">No strategies logged yet.</p>';
  }

  function renderSnapshots(snapshots) {
    const rows = snapshots
      .slice()
      .sort((a, b) => Number(b.args.epoch) - Number(a.args.epoch))
      .map((s) => {
        verify(`Benchmark snapshot, epoch ${s.args.epoch}`, `BTC ${fmtUsd8(s.args.btcPrice)}, SPY ${fmtUsd8(s.args.equityPrice)}, ${s.args.heads ? "heads" : "tails"}`, s);
        return `<tr><td>${s.args.epoch}</td><td>${blockLink(s.args.blockNumber)}</td><td class="num">${fmtUsd8(s.args.btcPrice)}</td><td class="num">${fmtUsd8(s.args.equityPrice)}</td><td>${s.args.heads ? "heads → BTC" : "tails → cash"}</td><td class="num">${fmtNav(s.args.btcNav)}</td><td class="num">${fmtNav(s.args.equityNav)}</td><td class="num">${fmtNav(s.args.flipNav)}</td><td>${txLink(s.transactionHash)}</td></tr>`;
      });
    $("snapshots").innerHTML = rows.length
      ? `<table><thead><tr><th>Epoch</th><th>Block</th><th class="num">BTC/USD</th><th class="num">SPY/USD</th><th>Flip</th><th class="num">BTC NAV</th><th class="num">Equity NAV</th><th class="num">Flip NAV</th><th>Tx</th></tr></thead><tbody>${rows.join("")}</tbody></table>`
      : '<p class="muted">No snapshots yet.</p>';
  }

  function renderVerify() {
    $("verify").innerHTML = verifyItems.length
      ? verifyItems
          .map((v) => `<div class="item"><div><strong>${esc(v.label)}</strong>: ${esc(v.value)}<br/><span class="muted">${esc(v.log.fragment ? v.log.fragment.name : "event")} · block ${v.log.blockNumber} · log index ${v.log.index}</span></div><div>${txLink(v.log.transactionHash)}</div></div>`)
          .join("")
      : '<p class="muted">Nothing published yet.</p>';
  }

  $("reload").onclick = () => { cfg.rpcUrl = $("rpc").value.trim() || cfg.rpcUrl; run(); };
  $("viewChart").onclick = () => setView(true);
  $("viewTable").onclick = () => setView(false);
  function setView(chart) {
    $("viewChart").setAttribute("aria-pressed", String(chart));
    $("viewTable").setAttribute("aria-pressed", String(!chart));
    $("chartWrap").classList.toggle("hidden", !chart);
    $("navTable").classList.toggle("hidden", chart);
  }
  function run() {
    load().catch((e) => { $("conn").textContent = "error: " + (e.shortMessage || e.message); console.error(e); });
  }
  readParams();
  run();
})();
