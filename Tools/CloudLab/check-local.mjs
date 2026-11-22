import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

const [, , endpoint, pinFile, fixture] = process.argv;
if (!endpoint || !pinFile || !fixture) {
  throw new Error("Uso: node check-local.mjs endpoint-local archivo-pin laboratorio.pkt");
}
const base = new URL(endpoint);
assert(["localhost", "127.0.0.1"].includes(base.hostname), "La prueba crea registros. Usa solo almacenamiento local de Wrangler.");

async function call(path, { token, json, body, method, headers } = {}) {
  const response = await fetch(new URL(path, base), {
    method: method ?? (json === undefined && body === undefined ? "GET" : "POST"),
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(json === undefined ? {} : { "Content-Type": "application/json" }), ...headers },
    body: json === undefined ? body : JSON.stringify(json),
  });
  return { status: response.status, data: response.status === 204 ? null : await response.json() };
}

const run = randomUUID().slice(0, 8);
const queue = "/api/access-requests";
const signIn = (email, pin) => call("/api/login", { json: { email, pin } });
const adminEmail = "dev@velaarturo.com";
const refresh = (session, requestID = randomUUID()) => call("/api/session/refresh", {
  json: { sessionID: session.sessionID, requestID, refreshToken: session.refreshToken },
});
const login = await signIn(adminEmail, readFileSync(pinFile, "utf8").trim());
assert.equal(login.status, 200, login.data.message);
assert.equal(login.data.role, "admin");
const nonce = randomUUID();
const wrongSession = await refresh({ ...login.data, sessionID: randomUUID() });
assert.equal(wrongSession.status, 401);
const rotated = await refresh(login.data, nonce);
assert.equal(rotated.status, 200, rotated.data.message);
assert.notEqual(rotated.data.token, login.data.token);
assert.notEqual(rotated.data.refreshToken, login.data.refreshToken);
assert.equal(rotated.data.refreshExpiresAt, login.data.refreshExpiresAt);
assert.equal(rotated.data.refreshExpiresAt - login.data.expiresAt, 7 * 86400 - 900);
assert.deepEqual(await refresh(login.data, nonce), rotated);
assert.equal((await refresh(login.data)).status, 401);
assert.equal((await call("/api/session", { token: login.data.token })).status, 401);
const token = rotated.data.token;
let parentID;
let code;
for (const name of [`Aula ${run}`, "Sala A", "Rack 1", "Servidor DNS"]) {
  const created = await call("/api/nodes", { token, json: { name, parentID, rackUnits: name === "Rack 1" ? 12 : undefined } });
  assert.equal(created.status, 201, created.data.message);
  parentID = created.data.id;
  code = created.data.code;
}
assert.match(code, /^UNSM-LAB-/);
const root = await call("/api/nodes", { token });
assert(root.data.some(node => node.name === `Aula ${run}`));
const email = `estudiante-${run}@example.com`;
const submission = kind => call(queue, { json: { email, kind } });
assert.equal((await submission("alta")).status, 202);
assert.equal((await submission("alta")).status, 202);
assert.equal((await submission("restablecer")).status, 202);
assert.equal((await signIn(email, "000000")).status, 401);
assert.equal((await call(queue)).status, 401);
const candidates = (await call(queue, { token })).data.filter(entry => entry.email === email);
assert.equal(candidates.length, 1);
const approval = `${queue}/${candidates[0].id}`;
const approvals = await Promise.all([1, 2].map(() => call(approval, { token, json: { role: "estudiante" } })));
const createStudent = approvals.find(result => result.status === 200);
assert(createStudent, JSON.stringify(approvals.map(result => result.status)));
assert(approvals.some(result => [404, 409].includes(result.status)));
assert.match(createStudent.data.pin, /^[0-9]{6}$/);
let student = await signIn(email, createStudent.data.pin);
assert.equal(student.status, 200);
assert.equal((await call(queue, { token: student.data.token })).status, 403);
assert.equal((await call(approval, { token: student.data.token, json: { role: "estudiante" } })).status, 403);
const bogus = `sin-cuenta-${run}@example.com`;
for (let attempt = 0; attempt < 5; attempt++) assert.equal((await signIn(bogus, "000000")).status, 401);
assert.equal((await signIn(bogus, "000000")).status, 429);
const upload = `/api/assets/${code}/releases`;
const latest = `/api/assets/${code}/latest`;
const body = readFileSync(fixture);
const send = (content, id = randomUUID(), session = token, device = "DHCP 1") => call(upload, { token: session, body: content,
  headers: { "X-Nexus-Device": encodeURIComponent(device), "X-Nexus-Verified": "1", "X-Nexus-Upload-ID": id } });

assert.equal((await call(latest)).status, 401);
assert.equal((await call(latest, { token })).status, 404);
assert.equal((await send(body, randomUUID(), student.data.token)).status, 403);
assert.equal((await call("/api/nodes", { token: student.data.token, json: { name: "Prohibido" } })).status, 403);
const uploadID = randomUUID();
const first = await send(body, uploadID);
assert.equal(first.status, 201, first.data.message);
assert.equal(first.data.version, 1);
assert.deepEqual(await send(body, uploadID), { status: 200, data: { version: 1 } });
assert.equal((await send(body, uploadID, token, "DHCP 2")).status, 409);
assert.equal((await send(Buffer.from("archivo inválido"))).status, 422);
const initial = await call(latest, { token: student.data.token });
assert.equal(initial.data.version, 1);
assert.equal(initial.data.asset, code);
assert.equal(initial.data.rackUnits, 12);
assert.equal(initial.data.demo, false);
assert.equal(initial.data.topology.devices.find(device => device.id === initial.data.deviceID)?.name, "DHCP 1");
assert(initial.data.topology.devices.every(device => device.configuration === undefined));
const next = await Promise.all([send(body), send(body)]);
assert.deepEqual(next.map(value => value.data.version).sort(), [2, 3]);
assert.equal((await call(latest, { token: student.data.token })).data.version, 3);
const users = await call("/api/users", { token });
const user = users.data.find(entry => entry.email === createStudent.data.email);
assert(user);
const access = `/api/users/${user.id}`;
assert.equal((await call(access, { token: student.data.token, method: "PATCH", json: { role: "docente", active: true } })).status, 403);
assert.equal((await call(access, { token, method: "PATCH", json: { role: "docente", active: true } })).status, 200);
assert.equal((await call("/api/session", { token: student.data.token })).data.role, "docente");
assert.equal((await submission("restablecer")).status, 202);
const toReset = (await call(queue, { token })).data.find(entry => entry.email === email && entry.kind === "restablecer");
const reset = await call(`${queue}/${toReset.id}`, { token, json: {} });
assert.equal(reset.status, 200, reset.data.message);
assert.equal((await call(latest, { token: student.data.token })).status, 401);
assert.equal((await refresh(student.data)).status, 401);
assert.notEqual(reset.data.pin, createStudent.data.pin);
assert.equal((await signIn(email, createStudent.data.pin)).status, 401);
student = await signIn(email, reset.data.pin);
assert.equal(student.status, 200);
assert.equal(student.data.role, "docente");
assert.equal((await call("/api/session/logout", { json: { refreshToken: student.data.refreshToken } })).status, 204);
assert.equal((await call(latest, { token: student.data.token })).status, 401);
assert.equal((await refresh(student.data)).status, 401);
assert.equal((await call(access, { token, method: "PATCH", json: { role: "estudiante", active: false } })).status, 200);
assert.equal((await signIn(email, reset.data.pin)).status, 401);
console.log("PASS: PIN y límite de intentos, rotación y reintento, aprobación única, restablecimiento y revocación, permisos, conversión PKT y versión por QR.");
