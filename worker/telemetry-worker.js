// Hermes Launcher Telemetry — Cloudflare Worker
// Routes:
//   POST /api/telemetry  — write a single anonymous event into D1
//   GET  /api/dashboard  — read aggregated metrics (Bearer Token required)
//   GET  /health         — liveness probe (no auth)
//
// Bindings:
//   env.DB              — D1 database (binding name: DB)
//   env.DASHBOARD_TOKEN — secret, Bearer Token for /api/dashboard
//   env.IP_HASH_SALT    — secret, salt for IP hashing
//   env.ALLOWED_ORIGINS — var, comma-separated origins for CORS

const VALID_EVENTS = new Set([
  'launcher_opened',
  'launcher_closed',
  'preflight_check',
  'install_residue_cleaned',
  'hermes_install_started',
  'hermes_install_completed',
  'hermes_install_failed',
  'model_config_started',
  'model_config_validated',
  'model_config_failed',
  'gateway_started',
  'gateway_failed',
  'webui_started',
  'webui_failed',
  'webui_session_kept_5min',
  'first_conversation', // kept for backward-compat with old launcher versions, no longer in funnel
  'unexpected_error',
]);

const MAX_PROPS_BYTES = 4096;
const MAX_FIELD_LEN = 256;

function parseAllowedOrigins(env) {
  const raw = env.ALLOWED_ORIGINS || '';
  return new Set(raw.split(',').map((s) => s.trim()).filter(Boolean));
}

function corsHeaders(origin, env) {
  const allowed = parseAllowedOrigins(env);
  const allowOrigin = allowed.has(origin) ? origin : (allowed.values().next().value || '*');
  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
}

function jsonResponse(obj, status, extraHeaders) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...(extraHeaders || {}) },
  });
}

async function sha256Hex(text) {
  const enc = new TextEncoder().encode(text);
  const buf = await crypto.subtle.digest('SHA-256', enc);
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function hashIp(ip, salt) {
  if (!ip) return '';
  const full = await sha256Hex(`${salt || 'unset-salt'}:${ip}`);
  return full.substring(0, 8);
}

function clampStr(value, max) {
  if (typeof value !== 'string') return '';
  return value.length > max ? value.substring(0, max) : value;
}

function isValidAnonymousId(id) {
  return typeof id === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(id);
}

async function handleTelemetry(request, env, headers) {
  let body;
  try {
    body = await request.json();
  } catch {
    return new Response('bad json', { status: 400, headers });
  }

  const eventName = clampStr(body.event_name || '', 64);
  if (!VALID_EVENTS.has(eventName)) {
    return new Response('unknown event', { status: 400, headers });
  }

  const anonId = clampStr(body.anonymous_id || '', 64);
  if (!isValidAnonymousId(anonId)) {
    return new Response('bad anonymous_id', { status: 400, headers });
  }

  const version = clampStr(body.version || '', MAX_FIELD_LEN);
  const osVersion = clampStr(body.os_version || '', MAX_FIELD_LEN);
  const memCategory = clampStr(body.memory_category || '', 16);
  const clientTs = Number.isFinite(body.client_timestamp) ? Math.floor(body.client_timestamp) : 0;
  const serverTs = Math.floor(Date.now() / 1000);

  let propsJson = '{}';
  if (body.properties && typeof body.properties === 'object') {
    let s;
    try {
      s = JSON.stringify(body.properties);
    } catch {
      s = '{}';
    }
    if (s.length > MAX_PROPS_BYTES) s = s.substring(0, MAX_PROPS_BYTES);
    propsJson = s;
  }

  const ip = request.headers.get('CF-Connecting-IP') || '';
  const ipHash = await hashIp(ip, env.IP_HASH_SALT);

  // 任务 015 Bug F (v2026.05.06.1): country / region 来自 Cloudflare 边缘 IP geo,
  // 不需要 launcher 上报。粒度到省份,不存城市。陷阱 #47。
  const cf = request.cf || {};
  const country = clampStr((cf.country || '').toString(), 8);
  const region = clampStr((cf.region || '').toString(), 64);

  try {
    await env.DB.prepare(
      `INSERT INTO events (event_name, anonymous_id, version, os_version, memory_category, ip_hash, client_timestamp, server_timestamp, properties, server_country, server_region)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
      .bind(eventName, anonId, version, osVersion, memCategory, ipHash, clientTs, serverTs, propsJson, country, region)
      .run();
  } catch (e) {
    return new Response('db error', { status: 500, headers });
  }

  return new Response(null, { status: 204, headers });
}

async function handleDashboard(request, env, headers) {
  const auth = request.headers.get('Authorization') || '';
  const expected = env.DASHBOARD_TOKEN ? `Bearer ${env.DASHBOARD_TOKEN}` : null;
  if (!expected || auth !== expected) {
    return new Response('unauthorized', { status: 401, headers });
  }

  const url = new URL(request.url);
  const days = Math.max(1, Math.min(30, parseInt(url.searchParams.get('days') || '1', 10) || 1));
  const sinceTs = Math.floor(Date.now() / 1000) - days * 86400;

  const eventCounts = await env.DB
    .prepare(`SELECT event_name, COUNT(*) AS count FROM events WHERE server_timestamp >= ? GROUP BY event_name ORDER BY count DESC`)
    .bind(sinceTs)
    .all();

  const uniqUsers = await env.DB
    .prepare(`SELECT COUNT(DISTINCT anonymous_id) AS count FROM events WHERE server_timestamp >= ?`)
    .bind(sinceTs)
    .first();

  const totalEvents = await env.DB
    .prepare(`SELECT COUNT(*) AS count FROM events WHERE server_timestamp >= ?`)
    .bind(sinceTs)
    .first();

  const failureRows = await env.DB
    .prepare(
      `SELECT properties FROM events
       WHERE (event_name LIKE '%failed' OR event_name = 'unexpected_error')
         AND server_timestamp >= ?
       ORDER BY server_timestamp DESC LIMIT 500`
    )
    .bind(sinceTs)
    .all();

  const reasonCounts = {};
  for (const row of failureRows.results || []) {
    try {
      const p = JSON.parse(row.properties || '{}');
      const reason = (p.reason || 'unknown').toString().substring(0, 200);
      reasonCounts[reason] = (reasonCounts[reason] || 0) + 1;
    } catch {
      reasonCounts['unparseable'] = (reasonCounts['unparseable'] || 0) + 1;
    }
  }
  const topReasons = Object.entries(reasonCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([reason, count]) => ({ reason, count }));

  // 任务 015 Bug H (v2026.05.06.3):trend 查询之前硬编码 7 天，不跟着 days 下拉变
  // 切换"最近 30 天"后这个区块还是只画 7 天柱子，PM 直觉以为整体看板没响应。
  // 改用 sinceTs（与其他区块一致）。陷阱 #48。
  const dailyTrend = await env.DB
    .prepare(
      `SELECT date(server_timestamp, 'unixepoch') AS day,
              COUNT(DISTINCT anonymous_id) AS users,
              COUNT(*) AS events
       FROM events
       WHERE server_timestamp >= ?
       GROUP BY day ORDER BY day`
    )
    .bind(sinceTs)
    .all();

  const funnelSteps = [
    'launcher_opened',
    'preflight_check',
    'hermes_install_started',
    'hermes_install_completed',
    'webui_started',
    'webui_session_kept_5min',
  ];
  const funnel = {};
  for (const step of funnelSteps) {
    const r = await env.DB
      .prepare(`SELECT COUNT(DISTINCT anonymous_id) AS count FROM events WHERE event_name = ? AND server_timestamp >= ?`)
      .bind(step, sinceTs)
      .first();
    funnel[step] = r ? r.count : 0;
  }

  // 任务 015 Bug F (v2026.05.06.1):用户地区分布 — 国家粒度 + 国内省份 Top
  const countryDist = await env.DB
    .prepare(
      `SELECT COALESCE(NULLIF(server_country, ''), 'UNKNOWN') AS country,
              COUNT(DISTINCT anonymous_id) AS users
       FROM events WHERE server_timestamp >= ?
       GROUP BY country ORDER BY users DESC LIMIT 15`
    )
    .bind(sinceTs)
    .all();
  const cnRegionDist = await env.DB
    .prepare(
      `SELECT COALESCE(NULLIF(server_region, ''), 'UNKNOWN') AS region,
              COUNT(DISTINCT anonymous_id) AS users
       FROM events WHERE server_country = 'CN' AND server_timestamp >= ?
       GROUP BY region ORDER BY users DESC LIMIT 10`
    )
    .bind(sinceTs)
    .all();

  const data = {
    days,
    generated_at: new Date().toISOString(),
    total_events: totalEvents ? totalEvents.count : 0,
    unique_users: uniqUsers ? uniqUsers.count : 0,
    events_by_name: eventCounts.results || [],
    top_failure_reasons: topReasons,
    country_distribution: countryDist.results || [],
    cn_region_distribution: cnRegionDist.results || [],
    daily_trend: dailyTrend.results || [],
    funnel,
  };

  return jsonResponse(data, 200, headers);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin') || '';
    const cors = corsHeaders(origin, env);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors });
    }

    if (url.pathname === '/health') {
      return new Response('ok', { status: 200 });
    }

    if (url.pathname === '/api/telemetry' && request.method === 'POST') {
      return handleTelemetry(request, env, cors);
    }

    if (url.pathname === '/api/dashboard' && request.method === 'GET') {
      return handleDashboard(request, env, cors);
    }

    return new Response('not found', { status: 404, headers: cors });
  },
};
