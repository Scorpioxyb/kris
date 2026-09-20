const $ = (id) => document.getElementById(id);

const statusLabels = {
  partial: "进行中 · 未封账",
  final: "完整日",
  usable_with_known_gaps: "可用 · 有缺口",
  warning: "需要补数据",
};

const signalLabels = {
  sleep: "睡眠",
  hrv_sdnn: "HRV",
  resting_hr: "静息心率",
  acute_to_baseline_load: "近期负荷",
};

const uiState = {
  trainingRange: 14,
  progressionExpanded: false,
  payload: null,
};

const loadStatusLabels = {
  baseline_building: "负荷基线建立中",
  below_28d_baseline: "近期刺激偏低",
  within_28d_baseline: "近期负荷在基线内",
  above_28d_baseline: "近期负荷高于基线",
  elevated_recent_load: "近期负荷明显升高",
};

const progressionLabels = {
  add_repetitions: "补次数",
  confirm_top_range: "确认上限",
  establish_baseline: "建立基线",
  rebuild_at_lower_bound: "回到下限",
};

function finite(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function fmt(value, digits = 1) {
  return finite(value) ? value.toFixed(digits) : "—";
}

function fmtDate(value) {
  if (!value) return "—";
  const parts = String(value).split("-");
  return parts.length >= 3 ? `${parts[1]}/${parts[2]}` : value;
}

function fmtDateTime(value) {
  if (!value) return "—";
  return String(value).replace("T", " ").replace(/([+-]\d\d):?(\d\d)$/, "");
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;",
  }[char]));
}

function showToast(message) {
  const toast = $("toast");
  toast.textContent = message;
  toast.classList.add("show");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove("show"), 2200);
}

function setText(id, value) { $(id).textContent = value; }

function svgChart(series, options = {}) {
  const width = 620;
  const laneHeight = 70;
  const laneGap = 16;
  const height = 24 + series.length * laneHeight + Math.max(0, series.length - 1) * laneGap + 24;
  const pad = { top: 6, right: 58, bottom: 24, left: 62 };
  const innerW = width - pad.left - pad.right;
  const usable = series.map((s) => ({ ...s, points: s.points.filter((p) => finite(p.value)) })).filter((s) => s.points.length);
  if (!usable.length || !usable.some((s) => s.points.length > 1)) {
    return `<div class="chart-empty">可比数据还不够，继续同步后这里会自动形成趋势。</div>`;
  }
  // 不同指标可能缺少不同日期；合并后必须重新按日期排序，避免稀疏线
  // 把新日期追加到末尾，导致日期轴与实际时间顺序不一致。
  const dates = [...new Set(usable.flatMap((s) => s.points.map((p) => p.date)))].sort((a, b) => String(a).localeCompare(String(b)));
  const x = (date) => pad.left + (dates.length === 1 ? innerW / 2 : dates.indexOf(date) / (dates.length - 1) * innerW);
  const domains = usable.map((s) => {
    const values = s.points.map((p) => p.value);
    const min = Math.min(...values);
    const max = Math.max(...values);
    const spread = Math.max(max - min, Math.abs(max) * .03, 1);
    return { min: min - spread * .14, max: max + spread * .14 };
  });
  const yFor = (s, value, laneIndex) => {
    const domain = domains[laneIndex];
    const laneTop = pad.top + laneIndex * (laneHeight + laneGap);
    return laneTop + laneHeight - ((value - domain.min) / (domain.max - domain.min)) * laneHeight;
  };
  const grid = usable.map((s, i) => {
    const laneTop = pad.top + i * (laneHeight + laneGap);
    const domain = domains[i];
    const middle = (domain.min + domain.max) / 2;
    return `<line x1="${pad.left}" y1="${laneTop}" x2="${width - pad.right}" y2="${laneTop}" stroke="rgba(21,32,24,.14)" stroke-width="1" /><line x1="${pad.left}" y1="${laneTop + laneHeight / 2}" x2="${width - pad.right}" y2="${laneTop + laneHeight / 2}" stroke="rgba(21,32,24,.08)" stroke-width="1" stroke-dasharray="3 5" /><line x1="${pad.left}" y1="${laneTop + laneHeight}" x2="${width - pad.right}" y2="${laneTop + laneHeight}" stroke="rgba(21,32,24,.14)" stroke-width="1" /><text x="0" y="${laneTop + 13}" fill="#536257" font-size="10" font-family="DM Mono,monospace">${escapeHtml(s.label)}</text><text x="${width - pad.right + 8}" y="${laneTop + 10}" fill="#536257" font-size="9" font-family="DM Mono,monospace">${s.labelValue(domain.max)}</text><text x="${width - pad.right + 8}" y="${laneTop + laneHeight}" fill="#7d857d" font-size="9" font-family="DM Mono,monospace">${s.labelValue(domain.min)}</text>`;
  }).join("");
  const labels = dates.filter((_, i) => i === 0 || i === dates.length - 1 || i === Math.floor((dates.length - 1) / 2)).map((date) => {
    const xx = x(date);
    return `<text x="${xx}" y="${height - 5}" text-anchor="${xx === pad.left ? "start" : xx === width - pad.right ? "end" : "middle"}" fill="#536257" font-size="10" font-family="DM Mono,monospace">${fmtDate(date)}</text>`;
  }).join("");
  const lines = usable.map((s, i) => {
    const points = s.points.map((p) => `${x(p.date)},${yFor(s, p.value, i)}`).join(" ");
    const last = s.points[s.points.length - 1];
    const lx = x(last.date); const ly = yFor(s, last.value, i);
    return `<polyline points="${points}" fill="none" stroke="${s.color}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" opacity=".98" />${s.points.map((p) => `<circle cx="${x(p.date)}" cy="${yFor(s, p.value, i)}" r="2.6" fill="#dbe4d8" stroke="${s.color}" stroke-width="2" />`).join("")}<text x="${Math.min(lx + 8, width - 50)}" y="${Math.max(ly - 8, pad.top + i * (laneHeight + laneGap) + 12)}" fill="${s.color}" font-size="10" font-family="DM Mono,monospace">${s.labelValue(last.value)}</text>`;
  }).join("");
  return `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" aria-hidden="true">${grid}${lines}${labels}</svg>`;
}

function renderBodyChart(rows) {
  const valid = rows.filter((r) => finite(r.weight) || finite(r.body_fat));
  $("body-range").textContent = valid.length ? `${fmtDate(valid[0].date)} — ${fmtDate(valid[valid.length - 1].date)}` : "暂无记录";
  $("body-chart").innerHTML = svgChart([
    { label: "体重", color: "#506f49", points: valid.map((r) => ({ date: r.date, value: r.weight })).filter((p) => finite(p.value)), labelValue: (v) => `${fmt(v)}kg` },
    { label: "体脂", color: "#3d6f78", points: valid.map((r) => ({ date: r.date, value: r.body_fat })).filter((p) => finite(p.value)), labelValue: (v) => `${fmt(v)}%` },
  ]);
}

function renderHealthChart(rows) {
  $("health-chart").innerHTML = svgChart([
    { label: "睡眠", color: "#3d6f78", points: rows.map((r) => ({ date: r.date, value: r.sleep })).filter((p) => finite(p.value)), labelValue: (v) => `${fmt(v)}h` },
    { label: "HRV", color: "#506f49", points: rows.map((r) => ({ date: r.date, value: r.hrv })).filter((p) => finite(p.value)), labelValue: (v) => `${fmt(v)}ms` },
  ]);
}

function loadChart(rows, days) {
  const width = 720;
  const height = 238;
  const pad = { top: 24, right: 66, bottom: 30, left: 38 };
  const data = rows.slice(-days).filter((row) => row.date);
  if (data.length < 2) {
    return `<div class="chart-empty">训练负荷记录不足，完成并归档训练后会形成趋势。</div>`;
  }
  const values = data.flatMap((row) => [row.load, row.short_ema, row.long_ema]).filter(finite);
  const max = Math.max(...values, 1) * 1.16;
  const innerW = width - pad.left - pad.right;
  const innerH = height - pad.top - pad.bottom;
  const x = (index) => pad.left + (data.length === 1 ? innerW / 2 : index / (data.length - 1) * innerW);
  const y = (value) => pad.top + innerH - Math.max(0, value) / max * innerH;
  const barW = Math.min(10, Math.max(3, innerW / data.length * .52));
  const gridValues = [max, max / 2, 0];
  const grid = gridValues.map((value) => {
    const yy = y(value);
    return `<line x1="${pad.left}" y1="${yy}" x2="${width - pad.right}" y2="${yy}" stroke="rgba(21,32,24,.13)" stroke-width="1" ${value === max / 2 ? 'stroke-dasharray="3 5"' : ""}/><text x="0" y="${yy + 4}" fill="#657269" font-size="10" font-family="DM Mono,monospace">${Math.round(value)}</text>`;
  }).join("");
  const bars = data.map((row, index) => {
    if (!finite(row.load) || row.load <= 0) return "";
    const xx = x(index) - barW / 2;
    const yy = y(row.load);
    return `<rect x="${xx}" y="${yy}" width="${barW}" height="${pad.top + innerH - yy}" rx="1.5" fill="#9aac9f" opacity=".78"><title>${fmtDate(row.date)} · 每日负荷 ${fmt(row.load, 0)}</title></rect>`;
  }).join("");
  const line = (field, color, label) => {
    const points = data.map((row, index) => finite(row[field]) ? { x: x(index), y: y(row[field]), value: row[field], date: row.date } : null).filter(Boolean);
    if (points.length < 2) return "";
    const last = points[points.length - 1];
    return `<polyline points="${points.map((point) => `${point.x},${point.y}`).join(" ")}" fill="none" stroke="${color}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/><circle cx="${last.x}" cy="${last.y}" r="3.6" fill="#d5dfd7" stroke="${color}" stroke-width="2"><title>${fmtDate(last.date)} · ${label} ${fmt(last.value, 1)}</title></circle><text x="${Math.min(last.x + 8, width - 58)}" y="${Math.max(last.y - 8, 12)}" fill="${color}" font-size="10" font-family="DM Mono,monospace">${fmt(last.value, 1)}</text>`;
  };
  const dateIndexes = [...new Set([0, Math.floor((data.length - 1) / 2), data.length - 1])];
  const dateLabels = dateIndexes.map((index) => `<text x="${x(index)}" y="${height - 5}" text-anchor="${index === 0 ? "start" : index === data.length - 1 ? "end" : "middle"}" fill="#536257" font-size="10" font-family="DM Mono,monospace">${fmtDate(data[index].date)}</text>`).join("");
  return `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" aria-hidden="true">${grid}${bars}${line("long_ema", "#506f49", "42日长期")}${line("short_ema", "#3d6f78", "7日短期")}${dateLabels}</svg>`;
}

function renderProgression(progression) {
  const decisions = progression.recent_decisions || [];
  const states = progression.states || {};
  const summary = [
    `${progression.exercise_count ?? decisions.length} 个动作`,
    `${states.add_repetitions || 0} 补次数`,
    `${states.confirm_top_range || 0} 确认上限`,
    `${states.establish_baseline || 0} 建基线`,
    `${states.rebuild_at_lower_bound || 0} 回到下限`,
  ];
  setText("progression-summary", summary.join(" · "));
  const visible = uiState.progressionExpanded ? decisions : decisions.slice(0, 6);
  $("progression-list").innerHTML = visible.map((row) => {
    const state = progressionLabels[row.progression_state] || row.progression_state || "待确认";
    const stateClass = Object.prototype.hasOwnProperty.call(progressionLabels, row.progression_state) ? row.progression_state : "unknown";
    return `<article class="progression-row">
      <div class="progression-exercise"><strong>${escapeHtml(row.exercise)}</strong><span>${escapeHtml(row.equipment_variant)} · ${fmtDate(row.latest_date)}</span></div>
      <div class="progression-scheme">${escapeHtml(row.latest_scheme || "尚无可比实绩")}</div>
      <div><span class="progression-state ${stateClass}">${escapeHtml(state)}</span></div>
      <div class="progression-action">${escapeHtml(row.next_action || "继续记录同器械实绩")}
        <details class="progression-evidence"><summary>查看依据</summary><p>${escapeHtml(row.decision_evidence || "证据待补充")}</p><p><b>回退：</b>${escapeHtml(row.rollback_condition || "出现疼痛或动作变形时停止进阶")}</p></details>
      </div>
    </article>`;
  }).join("") || `<div class="progression-empty">还没有足够的同器械动作记录。</div>`;
  const toggle = $("progression-toggle");
  toggle.hidden = decisions.length <= 6;
  toggle.textContent = uiState.progressionExpanded ? "收起" : `显示全部 ${decisions.length}`;
  toggle.setAttribute("aria-expanded", String(uiState.progressionExpanded));
}

function renderTraining(intelligence, rows) {
  const current = intelligence.current_load || {};
  const cardio = intelligence.cardio || {};
  $("load-chart").innerHTML = loadChart(rows, uiState.trainingRange);
  setText("load-state", loadStatusLabels[current.load_status] || current.load_status || "负荷状态待确认");
  setText("load-7d", finite(current.rolling_7d) ? fmt(current.rolling_7d, 0) : "—");
  setText("load-28d", finite(current.weekly_28d) ? fmt(current.weekly_28d, 0) : "—");
  setText("load-ema", finite(current.short_ema) && finite(current.long_ema) ? `${fmt(current.short_ema, 0)} / ${fmt(current.long_ema, 0)}` : "—");
  setText("vo2max", finite(cardio.latest_vo2max) ? fmt(cardio.latest_vo2max, 1) : "—");
  $("vo2max").parentElement.title = cardio.latest_vo2max_at ? `最近记录 ${fmtDate(cardio.latest_vo2max_at.slice(0, 10))}` : "最近记录日期待补充";
  setText("load-model-note", `${finite(current.model_days) ? Math.round(current.model_days) : "—"} 天模型 · ${current.model_status === "baseline_building" ? "基线建立中" : "已具备趋势语境"}`);
  renderProgression(intelligence.progression || {});
  document.querySelectorAll("[data-training-range]").forEach((button) => {
    const active = Number(button.dataset.trainingRange) === uiState.trainingRange;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  });
}

function renderEvidence(evidence) {
  const labels = { sleep: "睡眠", hrv_sdnn: "HRV", resting_hr: "静息心率", acute_to_baseline_load: "近期负荷" };
  $("evidence-list").innerHTML = (evidence || []).map((row) => {
    const value = finite(row.value) ? `${fmt(row.value)} ${row.unit || ""}` : "—";
    const baseline = finite(row.baseline) ? `基线 ${fmt(row.baseline)} ${row.unit || ""}` : "暂无基线";
    const pct = finite(row.delta_pct) ? row.delta_pct : finite(row.delta) ? Math.min(Math.abs(row.delta) * 10, 100) : 50;
    return `<div class="evidence-row"><span class="evidence-name">${labels[row.signal] || escapeHtml(row.signal)}</span><div><div class="evidence-value">${value} <span class="metric-note">${baseline}</span></div><div class="evidence-track"><span class="evidence-fill" style="width:${Math.max(8, Math.min(100, pct + 45))}%"></span></div></div></div>`;
  }).join("") || `<p class="muted">暂时没有足够的解释信号。</p>`;
}

function renderQuality(quality, today) {
  const checks = quality.checks || [];
  const pass = checks.filter((c) => c.status === "pass").length;
  const pct = checks.length ? Math.round(pass / checks.length * 100) : 0;
  $("quality-meter-fill").style.width = `${Math.max(12, pct)}%`;
  setText("quality-state", statusLabels[quality.overall] || quality.overall || "—");
  setText("quality-summary", `${pass}/${checks.length || 0} 项检查通过 · 恢复基线 ${quality.recovery_baseline_days ?? "—"}/14 天 · 今日${today.status === "partial" ? "尚未封账" : "已封账"}`);
  const gaps = (today.data_gaps || []).slice(0, 4);
  $("gap-list").innerHTML = gaps.map((gap) => `<div class="gap-item">${escapeHtml(gap)}</div>`).join("") || `<div class="gap-item">暂无高优先级数据缺口</div>`;
}

function renderNutrition(nutrition) {
  const items = nutrition.inventory_items || [];
  const gaps = nutrition.priority_gaps || [];
  const total = Object.values(nutrition.coverage_states || {}).reduce((sum, value) => sum + (Number(value) || 0), 0);
  setText("nutrition-summary", `${items.length} 项食材`);
  $("nutrition-summary").innerHTML = `<strong>${items.length}</strong><span>库存食材 · ${total || 17} 个覆盖维度</span>`;
  $("nutrition-gaps").innerHTML = gaps.length ? gaps.map((gap) => `<span>${escapeHtml(gap === "omega3" ? "Omega-3" : gap === "vitamin_d" ? "维生素 D" : gap)}</span>`).join("") : `<span>暂无重点缺口</span>`;
}

function render(payload) {
  const { meta, today, trends, nutrition, quality, training_intelligence: trainingIntelligence } = payload;
  uiState.payload = payload;
  const readiness = today.readiness || {};
  const score = Number(readiness.score);
  setText("today-date", today.date || "—");
  setText("readiness-label", readiness.label || "准备度 —");
  setText("readiness-copy", readiness.interpretation || "把健康信号、训练负荷和数据质量放在一起判断。");
  setText("readiness-score", finite(score) ? Math.round(score) : "—");
  $("score-ring").style.setProperty("--score", finite(score) ? Math.max(0, Math.min(100, score)) : 0);
  setText("day-status", statusLabels[today.status] || today.status || "—");
  setText("confidence-tag", `置信度 ${readiness.confidence || "—"}`);
  setText("quality-tag", `数据 ${statusLabels[quality.overall] || quality.overall || "—"}`);
  setText("decision-line", (today.actions || ["按今日状态执行计划"]).join(" "));
  setText("generated-at", `快照 ${fmtDateTime(meta.generated_at)}`);
  setText("sync-status", `已读取 ${fmtDateTime(meta.snapshot_mtime)}`);
  setText("footer-source", `源：${meta.app_version} · ${meta.timezone}`);

  const health = today.health || {};
  const body = today.body || {};
  setText("sleep", finite(health.sleep_hours) ? `${fmt(health.sleep_hours, 2)}h` : "—");
  setText("sleep-note", "个人基线约 6.42h");
  setText("hrv", finite(health.hrv_sdnn_ms) ? `${fmt(health.hrv_sdnn_ms, 1)}ms` : "—");
  setText("hrv-note", "与静息心率联合判断");
  setText("rhr", finite(health.resting_hr_bpm) ? `${fmt(health.resting_hr_bpm, 0)}bpm` : "—");
  setText("rhr-note", "近期基线约 65bpm");
  setText("body-weight", finite(body.weight_kg) ? `${fmt(body.weight_kg)}kg` : "—");
  setText("body-note", body.date ? `${fmtDate(body.date)} · 体脂 ${fmt(body.body_fat_pct)}%` : "尚无确认体测");
  setText("steps", finite(health.steps) ? Math.round(health.steps).toLocaleString("zh-CN") : "—");
  setText("steps-note", today.status === "partial" ? "今日实时值" : "完整日记录");
  setText("active-kcal", finite(health.active_kcal) ? `${Math.round(health.active_kcal)}kcal` : "—");
  setText("active-note", today.status === "partial" ? "暂不用于吃回" : "活动能量口径");

  const plan = today.plan || {};
  setText("plan-title", plan.title || "今日暂无锁定计划");
  setText("plan-basis", plan.prescription_basis || "计划依据将在数据完整后显示。");
  const planType = plan.title?.includes("下肢") ? "下肢力量" : plan.title?.includes("上肢") ? "上肢力量" : plan.title?.includes("跑") ? "跑步" : "今日计划";
  const duration = String(plan.title || "").match(/预计\s*(\d+)分钟/);
  setText("plan-type", planType);
  setText("plan-duration", duration ? `预计 ${duration[1]} 分钟` : "按备忘录");
  setText("plan-status", plan.status === "planned" ? "待执行" : plan.status || "—");
  $("action-list").innerHTML = (today.actions || []).map((action) => `<div class="action-item">${escapeHtml(action)}</div>`).join("") || `<div class="action-item">按备忘录执行并记录实际重量×次数</div>`;
  setText("guardrail", (today.guardrails || ["训练前检查疼痛、异常心悸和明显呼吸困难"])[0]);
  renderBodyChart(trends.body || []);
  renderHealthChart(trends.health || []);
  renderTraining(trainingIntelligence || {}, trends.training || []);
  renderEvidence(today.evidence || []);
  renderQuality(quality, today);
  renderNutrition(nutrition || {});
}

async function loadDashboard(showMessage = false) {
  const button = $("refresh");
  button.disabled = true;
  button.classList.add("loading");
  try {
    const response = await fetch(`/api/dashboard?ts=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json());
    if (showMessage) showToast("已重新读取最新教练快照");
  } catch (error) {
    console.error(error);
    showToast("读取失败：请确认本地服务仍在运行");
    setText("sync-status", "读取失败");
  } finally {
    button.disabled = false;
    button.classList.remove("loading");
  }
}

$("refresh").addEventListener("click", () => loadDashboard(true));

document.querySelectorAll("[data-training-range]").forEach((button) => {
  button.addEventListener("click", () => {
    uiState.trainingRange = Number(button.dataset.trainingRange) || 14;
    if (uiState.payload) renderTraining(uiState.payload.training_intelligence || {}, uiState.payload.trends.training || []);
  });
});

$("progression-toggle").addEventListener("click", () => {
  uiState.progressionExpanded = !uiState.progressionExpanded;
  if (uiState.payload) renderProgression(uiState.payload.training_intelligence?.progression || {});
});

loadDashboard();

document.querySelectorAll(".nav-link").forEach((link) => {
  link.addEventListener("click", () => {
    document.querySelectorAll(".nav-link").forEach((item) => item.classList.remove("active"));
    link.classList.add("active");
  });
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}
