// FE-CORTE / BE-CORTE: búsquedas clínicas y reportes de fin de mes simultáneos con actores de áreas distintas.
// Sólo contra la base desechable de scripts/load-mixed.sh (origen 127.0.0.1). Mide latencia por operación y
// comprueba que las respuestas concurrentes coinciden con una lectura secuencial previa del mismo actor.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const origin = process.env.LOAD_ORIGIN || 'http://127.0.0.1:18080', password = process.env.LOAD_PASSWORD;
const concurrency = Number(process.env.LOAD_CONCURRENCY || 20), rounds = Number(process.env.LOAD_ROUNDS || 15), limitMs = 3000;
assert(['127.0.0.1', 'localhost'].includes(new URL(origin).hostname), 'sólo origen local'); assert(password, 'LOAD_PASSWORD');

async function session(email) {
  const jar = new Map(), store = r => { for (const c of r.headers.getSetCookie()) { const [pair] = c.split(';'), i = pair.indexOf('='); jar.set(pair.slice(0, i), pair.slice(i + 1)); } };
  const cookie = () => [...jar].map(([k, v]) => k + '=' + v).join('; ');
  const call = async (path, method = 'GET', body) => {
    const headers = { cookie: cookie(), accept: 'application/json' };
    if (method !== 'GET') { const t = await fetch(origin + '/api/v1/security/csrf', { headers: { cookie: cookie() } }); store(t); const data = (await t.json()).data; headers[data.headerName] = data.token; headers.cookie = cookie(); headers['content-type'] = 'application/json'; }
    const started = performance.now(), r = await fetch(origin + path, { method, headers, body: body && JSON.stringify(body) }); store(r);
    const text = await r.text(); return { status: r.status, ms: performance.now() - started, text };
  };
  const login = await call('/api/v1/auth/login', 'POST', { email, password }); assert.equal(login.status, 200, email + ' ' + login.text);
  return { email, call };
}

const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/La_Paz' }), monthStart = today.slice(0, 8) + '01';
const accounts = {
  admin: await session('carga.admin@example.invalid'), reportes1: await session('carga.reportes1@example.invalid'), reportes2: await session('carga.reportes2@example.invalid'),
  auditor: await session('carga.auditor@example.invalid'),
  revision1: await session('carga.revision1@example.invalid'), revision2: await session('carga.revision2@example.invalid'),
  especialista1: await session('carga.especialista1@example.invalid'), especialista2: await session('carga.especialista2@example.invalid'),
};
// Pacientes que cada médico atendió (ámbito autorizado de su historia), tomados de su propia agenda.
const patientsOf = async who => { const r = await accounts[who].call('/api/medical/appointments'); assert.equal(r.status, 200); return [...new Set(JSON.parse(r.text).data.map(a => a.patient.id))].slice(0, 5); };
const doctors = {}; for (const who of ['revision1', 'revision2', 'especialista1', 'especialista2']) { doctors[who] = await patientsOf(who); assert(doctors[who].length, who + ' sin pacientes'); }

const operations = [
  ['reportes1', 'reporte clínico mensual', `/api/reports/clinical?from=${monthStart}&to=${today}`],
  ['reportes2', 'reporte clínico mensual con diagnóstico', `/api/reports/clinical?from=${monthStart}&to=${today}&diagnosis=Migra`],
  ['reportes1', 'cumplimiento institucional', '/api/reports/compliance?period=2026-2'],
  ['reportes2', 'actividad diaria del mes', `/api/reports/daily-activity?from=${monthStart}&to=${today}`],
  ['reportes2', 'cobertura de vacunación', '/api/reports/vaccination-coverage?academicPeriod=2026-2'],
  ['admin', 'panorama administrativo', '/api/reports/administrative-summary'],
  ['admin', 'listado de pacientes', '/api/patients'],
  ['auditor', 'auditoría del mes', `/api/audit-events?from=${monthStart}&to=${today}&limit=500`],
  ...Object.entries(doctors).flatMap(([who, ids]) => ids.slice(0, 2).flatMap((id, i) => [
    [who, 'historia autorizada', `/api/medical/patients/${id}`],
    [who, 'búsqueda en historia', `/api/medical/patients/${id}/search?q=${i ? 'carga' : 'Cefalea'}`],
  ])),
];
// La auditoría crece con cada consulta auditada, por eso se compara sólo su estado HTTP.
const stable = ([, name]) => name !== 'auditoría del mes';
const digest = text => createHash('sha256').update(text).digest('hex');
const baseline = new Map();
for (const op of operations) { const r = await accounts[op[0]].call(op[2]); assert.equal(r.status, 200, op[2] + ' ' + r.text.slice(0, 200)); baseline.set(op[2] + op[0], digest(r.text)); }

const queue = Array.from({ length: rounds }, () => operations).flat().sort(() => Math.random() - 0.5), samples = [];
const started = performance.now();
await Promise.all(Array.from({ length: concurrency }, async () => {
  for (let op; (op = queue.pop());) {
    const r = await accounts[op[0]].call(op[2]);
    samples.push({ actor: op[0], name: op[1], status: r.status, ms: r.ms, same: !stable(op) || digest(r.text) === baseline.get(op[2] + op[0]) });
  }
}));
const wall = performance.now() - started, pct = (list, p) => list[Math.min(list.length - 1, Math.ceil(p * list.length) - 1)];
const summary = Object.values(Object.groupBy(samples, s => s.name)).map(list => {
  const ms = list.map(s => s.ms).sort((a, b) => a - b);
  return { operacion: list[0].name, solicitudes: list.length, errores: list.filter(s => s.status !== 200).length, distintas: list.filter(s => !s.same).length, p50: Math.round(pct(ms, .5)), p95: Math.round(pct(ms, .95)), max: Math.round(ms.at(-1)) };
});
const all = samples.map(s => s.ms).sort((a, b) => a - b);
const result = { origen: origin, concurrencia: concurrency, solicitudes: samples.length, segundos: +(wall / 1000).toFixed(1), p50: Math.round(pct(all, .5)), p95: Math.round(pct(all, .95)), max: Math.round(all.at(-1)), operaciones: summary };
console.table(summary); console.log(JSON.stringify({ ...result, operaciones: undefined }));
if (process.env.LOAD_RESULT) writeFileSync(process.env.LOAD_RESULT, JSON.stringify(result, null, 2));
assert.equal(samples.filter(s => s.status !== 200).length, 0, 'todas las solicitudes responden 200');
assert.equal(samples.filter(s => !s.same).length, 0, 'ninguna respuesta concurrente difiere de la lectura secuencial del mismo actor');
assert(summary.every(s => s.p95 < limitMs), `p95 < ${limitMs} ms en cada operación`);
console.log(`PASS ${samples.length} solicitudes mixtas con concurrencia ${concurrency}: sin errores, sin mezcla entre actores, p95 global ${result.p95} ms (< ${limitMs} ms)`);
