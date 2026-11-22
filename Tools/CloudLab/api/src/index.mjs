const fileLimit = 16 * 1024 * 1024;
const releaseLimit = 8 * 1024 * 1024;
const accessLifetime = 15 * 60;
const ownerEmail = "dev@velaarturo.com";
const pinPattern = /^[0-9]{6}$/;
const tokenPattern = /^[a-f0-9]{64}$/;
const week = 7 * 24 * 60 * 60;
const assetPattern = /^UNSM-LAB-[A-F0-9]{20}$/;
const uuidPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const emailPattern = /^[^\s@]{1,64}@[^\s@]{1,189}\.[^\s@]{2,}$/;
const credentialPattern = /^[A-Fa-f0-9]{48}$/;
const noStore = { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" };

class APIError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function json(value, status = 200) { return Response.json(value, { status, headers: noStore }); }

async function readBytes(message, limit) {
  const size = Number(message.headers.get("Content-Length"));
  if (Number.isFinite(size) && size > limit) throw new APIError(413, "El archivo supera el límite admitido.");
  if (!message.body) throw new APIError(400, "Falta el contenido de la solicitud.");
  const stream = message.body.getReader();
  const chunks = [];
  let count = 0;
  try {
    for (;;) {
      const { value, done } = await stream.read();
      if (done) break;
      count += value.byteLength;
      if (count > limit) {
        await stream.cancel();
        throw new APIError(413, "El archivo supera el límite admitido.");
      }
      chunks.push(value);
    }
  } finally { stream.releaseLock(); }
  const bytes = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

async function readJSON(req) {
  const bytes = await readBytes(req, 4096);
  try {
    const body = JSON.parse(new TextDecoder().decode(bytes));
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
    return body;
  } catch { throw new APIError(400, "Datos inválidos."); }
}

function randomHex(length) {
  return [...crypto.getRandomValues(new Uint8Array(length))].map(x => x.toString(16).padStart(2, "0")).join("");
}

async function hash(value) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map(x => x.toString(16).padStart(2, "0")).join("");
}

function normalizeEmail(input) {
  const email = typeof input === "string" ? input.trim().toLowerCase() : "";
  if (email.length > 254 || !emailPattern.test(email)) throw new APIError(400, "Introduce un correo válido.");
  return email;
}

function boundedName(value, max) {
  const name = typeof value === "string" ? value.trim() : "";
  if (!name || name.length > max || /[\x00-\x1f\x7f]/.test(name)) throw new APIError(400, "El nombre es inválido o demasiado largo.");
  return name;
}

const nowSeconds = () => Math.floor(Date.now() / 1000);

async function keyedHash(secret, value) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(value)))]
    .map(byte => byte.toString(16).padStart(2, "0")).join("");
}

function sessionError() {
  return new APIError(401, "La sesión venció. Vuelve a iniciar sesión.");
}

async function throttle(db, secret, req, email, action, limits) {
  const now = nowSeconds();
  const scopes = await Promise.all([
    keyedHash(secret, `rate:${action}:email:${email}`),
    keyedHash(secret, `rate:${action}:ip:${req.headers.get("CF-Connecting-IP") ?? "local"}`),
  ]);
  const requests = scopes.map((scope, index) => db.prepare(`INSERT INTO auth_rate (scope, expires_at, count) VALUES (?, ?, 1)
    ON CONFLICT(scope) DO UPDATE SET
      count=CASE WHEN auth_rate.expires_at<=? THEN 1 ELSE auth_rate.count+1 END,
      expires_at=CASE WHEN auth_rate.expires_at<=? THEN excluded.expires_at ELSE auth_rate.expires_at END
    WHERE auth_rate.expires_at<=? OR auth_rate.count<? RETURNING count`)
    .bind(scope, now + 15 * 60, now, now, now, limits[index]));
  if (crypto.getRandomValues(new Uint8Array(1))[0] < 4) {
    requests.push(db.prepare("DELETE FROM auth_rate WHERE expires_at<=?").bind(now));
  }
  const results = await db.batch(requests);
  if (results.slice(0, scopes.length).some(result => !result.results.length)) {
    throw new APIError(429, "Demasiados intentos. Espera 15 minutos y vuelve a intentar.");
  }
}

function sessionResponse(user, token, refreshToken, expiresAt, refreshExpiresAt, sessionID) {
  return json({ email: user.email, role: user.role, token, refreshToken, expiresAt, refreshExpiresAt, sessionID });
}

async function signIn(db, secret, req) {
  const { email: input, pin, accessCode } = await readJSON(req);
  const email = normalizeEmail(input);
  await throttle(db, secret, req, email, "login", [5, 50]);
  const legacy = pin === undefined && typeof accessCode === "string" && credentialPattern.test(accessCode);
  if (!legacy && (typeof pin !== "string" || !pinPattern.test(pin))) {
    throw new APIError(401, "Correo o PIN incorrecto.");
  }
  const credential = legacy ? await hash(accessCode.toLowerCase()) : await keyedHash(secret, `pin:${email}:${pin}`);
  const user = legacy
    ? await db.prepare("SELECT id,email,role FROM users WHERE email=? AND access_hash=? AND pin_hash IS NULL AND active=1")
      .bind(email, credential).first()
    : await db.prepare("SELECT id,email,role FROM users WHERE email=? AND pin_hash=? AND active=1")
      .bind(email, credential).first();
  if (!user) throw new APIError(401, "Correo o PIN incorrecto.");
  const now = nowSeconds();
  const token = randomHex(32);
  const refreshToken = randomHex(32);
  const sessionID = crypto.randomUUID();
  const expiresAt = now + (legacy ? week : accessLifetime);
  await db.batch([
    db.prepare("DELETE FROM sessions WHERE COALESCE(refresh_expires_at,expires_at)<=?").bind(now),
    db.prepare(`INSERT INTO sessions (token_hash,user_id,expires_at,refresh_hash,refresh_expires_at,session_id)
      SELECT ?,id,?,?,?,? FROM users WHERE id=? AND active=1 AND
      (CASE WHEN ? THEN pin_hash IS NULL AND access_hash=? ELSE pin_hash=? END)`)
      .bind(await hash(token), expiresAt, await hash(refreshToken), now + week, sessionID, user.id, legacy ? 1 : 0,
        legacy ? credential : "", legacy ? "" : credential),
  ]).then(([, inserted]) => {
    if (!inserted.meta.changes) throw sessionError();
  });
  return sessionResponse(user, token, refreshToken, expiresAt, now + week, sessionID);
}

async function refreshSession(db, secret, req) {
  const { refreshToken, requestID, sessionID } = await readJSON(req);
  if (typeof refreshToken !== "string" || !tokenPattern.test(refreshToken)
    || typeof requestID !== "string" || !uuidPattern.test(requestID)
    || typeof sessionID !== "string" || !uuidPattern.test(sessionID)) throw sessionError();
  const now = nowSeconds();
  const nonce = `${sessionID}:${requestID}`;
  const [oldHash, token, nextRefresh] = await Promise.all([
    hash(refreshToken),
    keyedHash(secret, `access:${refreshToken}:${nonce}`),
    keyedHash(secret, `refresh:${refreshToken}:${nonce}`),
  ]);
  const [tokenHash, refreshHash] = await Promise.all([hash(token), hash(nextRefresh)]);
  const changed = await db.prepare(`UPDATE sessions
    SET previous_refresh_hash=refresh_hash, refresh_hash=?, token_hash=?,
        expires_at=MIN(?,refresh_expires_at), rotation_id=?, rotated_at=?
    WHERE refresh_hash=? AND refresh_expires_at>? AND session_id=? AND user_id IN (SELECT id FROM users WHERE active=1)
    RETURNING user_id, expires_at, refresh_expires_at`)
    .bind(refreshHash, tokenHash, now + accessLifetime, nonce, now, oldHash, now, sessionID).first();
  const row = changed ?? await db.prepare(`SELECT user_id,expires_at,refresh_expires_at FROM sessions
    WHERE previous_refresh_hash=? AND refresh_hash=? AND rotation_id=? AND rotated_at>? AND refresh_expires_at>? AND session_id=?`)
    .bind(oldHash, refreshHash, nonce, now - 120, now, sessionID).first();
  if (!row) throw sessionError();
  const user = await db.prepare("SELECT email,role FROM users WHERE id=? AND active=1").bind(row.user_id).first();
  if (!user) throw sessionError();
  return sessionResponse(user, token, nextRefresh, row.expires_at, row.refresh_expires_at, sessionID);
}

async function revokeSession(db, req) {
  const { refreshToken } = await readJSON(req);
  if (typeof refreshToken === "string" && tokenPattern.test(refreshToken)) {
    const refreshHash = await hash(refreshToken);
    await db.prepare("DELETE FROM sessions WHERE refresh_hash=? OR previous_refresh_hash=?").bind(refreshHash, refreshHash).run();
  }
  return new Response(null, { status: 204, headers: noStore });
}

async function authenticate(db, req) {
  const token = req.headers.get("Authorization")?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
  if (!token) throw new APIError(401, "Inicia sesión para consultar el catálogo.");
  const tokenHash = await hash(token);
  const user = await db.prepare(`SELECT u.id, u.email, u.role FROM sessions s JOIN users u ON u.id=s.user_id
    WHERE s.token_hash=? AND s.expires_at>? AND u.active=1`).bind(tokenHash, Math.floor(Date.now() / 1000)).first();
  if (!user) throw new APIError(401, "La sesión venció. Vuelve a iniciar sesión.");
  return { ...user, tokenHash };
}

function requirePublisher(user) {
  if (user.role === "estudiante") throw new APIError(403, "Esta cuenta tiene acceso de consulta.");
}

function requireOwner(user) {
  if (user.email !== ownerEmail || user.role !== "admin") {
    throw new APIError(403, "Solo la cuenta administradora principal puede autorizar accesos.");
  }
}

async function requestAccess(db, secret, req) {
  const body = await readJSON(req);
  const email = normalizeEmail(body.email);
  if (!["alta", "restablecer"].includes(body.kind)) throw new APIError(400, "Solicitud inválida.");
  await throttle(db, secret, req, email, "request", [4, 30]);
  const now = nowSeconds();
  await db.batch([
    db.prepare("DELETE FROM access_requests WHERE requested_at<=?").bind(now - week),
    db.prepare(`INSERT INTO access_requests (id,email,kind,requested_at)
      SELECT ?,?,?,? WHERE ${body.kind === "alta"
        ? "NOT EXISTS (SELECT id FROM users WHERE email=?)"
        : "EXISTS (SELECT id FROM users WHERE email=? AND active=1)"}
      ON CONFLICT(email,kind) DO NOTHING`).bind(crypto.randomUUID(), email, body.kind, now, email),
  ]);
  return json({ received: true }, 202);
}

async function reviewRequests(db, secret, req, user, id) {
  requireOwner(user);
  const cutoff = nowSeconds() - week;
  if (!id) {
    const { results } = await db.prepare(`SELECT id,email,kind FROM access_requests
      WHERE requested_at>? ORDER BY requested_at LIMIT 500`).bind(cutoff).all();
    return json(results);
  }
  if (req.method === "DELETE") {
    await db.prepare("DELETE FROM access_requests WHERE id=?").bind(id).run();
    return new Response(null, { status: 204, headers: noStore });
  }
  const request = await db.prepare(`SELECT r.email,r.kind,u.pin_hash FROM access_requests r
    LEFT JOIN users u ON u.email=r.email WHERE r.id=? AND r.requested_at>?`).bind(id, cutoff).first();
  if (!request) throw new APIError(404, "La solicitud ya fue revisada o venció.");
  const { role } = await readJSON(req);
  if (request.kind === "alta" && !["docente", "estudiante"].includes(role)) throw new APIError(400, "El rol no es válido.");
  // Draw uniformly from decimal PINs, including leading zeroes.
  const byte = new Uint8Array(1);
  let pin, pinHash;
  do {
    pin = Array.from({ length: 6 }, () => {
      do { crypto.getRandomValues(byte); } while (byte[0] >= 250);
      return String(byte[0] % 10);
    }).join("");
    pinHash = await keyedHash(secret, `pin:${request.email}:${pin}`);
  } while (pinHash === request.pin_hash);
  const pending = "SELECT email FROM access_requests WHERE id=? AND requested_at>?";
  const write = request.kind === "alta"
    ? db.prepare(`INSERT INTO users (id,email,role,access_hash,pin_hash)
        SELECT ?,email,?,?,? FROM access_requests WHERE id=? AND requested_at>?
        ON CONFLICT(email) DO NOTHING RETURNING email`)
      .bind(crypto.randomUUID(), role, await hash(randomHex(32)), pinHash, id, cutoff)
    : db.prepare(`UPDATE users SET pin_hash=? WHERE email IN (${pending}) AND active=1 RETURNING email`)
      .bind(pinHash, id, cutoff);
  const [result] = await db.batch([
    write,
    db.prepare(`DELETE FROM sessions WHERE user_id IN
      (SELECT id FROM users WHERE email IN (${pending}) AND pin_hash=?)`).bind(id, cutoff, pinHash),
    db.prepare("DELETE FROM access_requests WHERE id=?").bind(id),
  ]);
  if (!result.results.length) throw new APIError(409, "La cuenta cambió. La solicitud ya fue cerrada.");
  return json({ email: request.email, pin });
}

async function manageAccess(db, req, user, id) {
  requireOwner(user);
  if (!id) {
    const { results } = await db.prepare("SELECT id, email, role, active FROM users WHERE role != 'admin' ORDER BY email").all();
    return json(results.map(account => ({ ...account, active: account.active === 1 })));
  }
  const { role, active } = await readJSON(req);
  if (!["docente", "estudiante"].includes(role) || typeof active !== "boolean") throw new APIError(400, "Permisos inválidos.");
  const update = db.prepare(`UPDATE users SET role=?, active=? WHERE id=? AND role != 'admin'
    RETURNING id, email, role, active`).bind(role, active ? 1 : 0, id);
  const changes = [update];
  if (!active) changes.push(db.prepare(`DELETE FROM sessions WHERE user_id IN
    (SELECT id FROM users WHERE id=? AND active=0 AND role != 'admin')`).bind(id));
  const [result] = await db.batch(changes);
  const entry = result.results[0];
  if (!entry) throw new APIError(404, "Cuenta no encontrada.");
  return json({ ...entry, active: entry.active === 1 });
}

async function listNodes(db, parent) {
  if (parent !== null && !uuidPattern.test(parent)) throw new APIError(400, "Ubicación inválida.");
  const { results } = await db.prepare(`SELECT n.id, n.kind, n.name, n.code, n.rack_units AS rackUnits,
      (SELECT MAX(r.version) FROM releases r WHERE r.node_id=n.id) AS version
    FROM nodes n WHERE n.parent_id IS ? ORDER BY n.name COLLATE NOCASE`).bind(parent).all();
  return json(results);
}

async function createNode(db, req, user) {
  requirePublisher(user);
  const { parentID = null, name: input, rackUnits = null } = await readJSON(req);
  const name = boundedName(input, 96);
  let kind = 0;
  if (parentID !== null) {
    if (typeof parentID !== "string" || !uuidPattern.test(parentID)) throw new APIError(400, "Ubicación inválida.");
    const parent = await db.prepare("SELECT kind FROM nodes WHERE id=?").bind(parentID).first();
    if (!parent || parent.kind === 3) throw new APIError(400, "Elige un aula, sala o rack válido.");
    kind = parent.kind + 1;
  }
  if (rackUnits !== null && (kind !== 2 || ![12, 24, 42].includes(rackUnits))) {
    throw new APIError(400, "La capacidad del rack debe ser de 12, 24 o 42 U.");
  }
  const code = kind === 3 ? `UNSM-LAB-${randomHex(10).toUpperCase()}` : null;
  const node = await db.prepare(`INSERT INTO nodes (id, parent_id, kind, name, code, rack_units) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT DO NOTHING RETURNING id, kind, name, code, rack_units AS rackUnits`)
    .bind(crypto.randomUUID(), parentID, kind, name, code, rackUnits).first();
  if (!node) throw new APIError(409, "Ya existe una ubicación con ese nombre.");
  return json(node, 201);
}

async function findAsset(db, code) {
  if (!assetPattern.test(code)) throw new APIError(404, "Etiqueta de servidor desconocida.");
  const asset = await db.prepare(`SELECT n.id,n.name,n.code,p.rack_units FROM nodes n JOIN nodes p ON n.parent_id=p.id
    WHERE n.code=? AND n.kind=3`).bind(code).first();
  if (!asset) throw new APIError(404, "No se encontró el servidor de prácticas.");
  return asset;
}

async function latest(db, env, code) {
  const asset = await findAsset(db, code);
  const row = await db.prepare(`SELECT version, published_at, device_id, object_prefix, demo FROM releases
    WHERE node_id=? ORDER BY version DESC LIMIT 1`).bind(asset.id).first();
  if (!row) throw new APIError(404, "Este servidor aún no tiene una publicación.");
  const object = await env.LABS.get(`${row.object_prefix}/topology.json`);
  if (!object) throw new APIError(503, "La versión publicada no está disponible temporalmente.");
  const metadata = JSON.stringify({ schemaVersion: 1, asset: code, version: row.version,
    publishedAt: row.published_at, deviceID: row.device_id, rackUnits: asset.rack_units, demo: row.demo === 1 });
  return new Response(new Blob([metadata.slice(0, -1), ',"topology":', await object.arrayBuffer(), "}"]), {
    headers: { ...noStore, "Content-Type": "application/json" },
  });
}

async function publish(db, env, req, user, code) {
  requirePublisher(user);
  const asset = await findAsset(db, code);
  const uploadID = req.headers.get("X-Nexus-Upload-ID");
  const demo = req.headers.get("X-Nexus-Demo") === "1";
  if (demo) requireOwner(user);
  if (!uuidPattern.test(uploadID ?? "") || (!demo && req.headers.get("X-Nexus-Verified") !== "1")) {
    throw new APIError(400, "Confirma la prueba física antes de publicar.");
  }
  let selector;
  try { selector = decodeURIComponent(req.headers.get("X-Nexus-Device") ?? ""); }
  catch { throw new APIError(400, "El nombre del equipo en Packet Tracer no es válido."); }
  selector = boundedName(selector, 160);
  const raw = await readBytes(req, fileLimit);
  if (!raw.length) throw new APIError(400, "El archivo .pkt está vacío.");
  const fingerprint = await hash(`${await hash(raw)}/${selector}${demo ? "/demo" : ""}`);
  const findUpload = () => db.prepare(`SELECT version, fingerprint FROM releases WHERE node_id=? AND upload_id=?`)
    .bind(asset.id, uploadID).first();
  const previous = await findUpload();
  if (previous) {
    if (previous.fingerprint !== fingerprint) throw new APIError(409, "La solicitud ya pertenece a otro archivo.");
    return json({ version: previous.version });
  }
  const converted = await env.CONVERTER.fetch("https://converter.internal/convert", {
    method: "POST", body: raw, headers: { "X-Nexus-Device": encodeURIComponent(selector) },
  });
  if (converted.status === 422) throw new APIError(422, (await converted.text()).slice(0, 300));
  if (!converted.ok) throw new APIError(503, "El conversor no está disponible. La versión anterior sigue publicada.");
  const deviceID = converted.headers.get("X-Nexus-Device-ID");
  if (!deviceID || deviceID.length > 64) throw new APIError(502, "El conversor devolvió un equipo inválido.");
  const topology = await readBytes(converted, releaseLimit - 1024);
  const prefix = `labs/${asset.id}/${crypto.randomUUID()}`;
  const original = `${prefix}/source.pkt`;
  const exported = `${prefix}/topology.json`;
  const files = await Promise.allSettled([
    env.LABS.put(original, raw, { httpMetadata: { contentType: "application/octet-stream" } }),
    env.LABS.put(exported, topology, { httpMetadata: { contentType: "application/json" } }),
  ]);
  if (files.some(result => result.status === "rejected")) {
    await env.LABS.delete([original, exported]);
    throw new APIError(503, "No se guardaron ambos archivos. Vuelve a intentar.");
  }
  const at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const row = await db.prepare(`INSERT INTO releases (node_id, version, published_at, author_id,
    upload_id, fingerprint, device_id, object_prefix, demo)
    VALUES (?, (SELECT COALESCE(MAX(version), 0) + 1 FROM releases WHERE node_id=?), ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(node_id, upload_id) DO NOTHING RETURNING version`)
    .bind(asset.id, asset.id, at, user.id, uploadID, fingerprint, deviceID, prefix, demo ? 1 : 0).first();
  if (row) return json(row, 201);
  const concurrent = await findUpload();
  await env.LABS.delete([original, exported]);
  if (!concurrent || concurrent.fingerprint !== fingerprint) throw new APIError(409, "La solicitud ya pertenece a otro archivo.");
  return json({ version: concurrent.version });
}

export default {
  async fetch(req, env) {
    try {
      const url = new URL(req.url);
      const { pathname } = url;
      // Read from the primary for a scan immediately after publishing, including deployments with replication.
      const db = env.DB.withSession("first-primary");
      const secret = env.AUTH_SECRET;
      if (!secret || secret.length < 32) throw new APIError(503, "El servicio de acceso aún no está configurado.");
      if (req.method === "POST" && pathname === "/api/login") return await signIn(db, secret, req);
      if (req.method === "POST" && pathname === "/api/session/refresh") return await refreshSession(db, secret, req);
      if (req.method === "POST" && pathname === "/api/session/logout") return await revokeSession(db, req);
      if (req.method === "POST" && pathname === "/api/access-requests") return await requestAccess(db, secret, req);
      const user = await authenticate(db, req);
      if (pathname === "/api/session" && req.method === "GET") return json({ email: user.email, role: user.role });
      if (pathname === "/api/session" && req.method === "DELETE") {
        await db.prepare("DELETE FROM sessions WHERE token_hash=?").bind(user.tokenHash).run();
        return new Response(null, { status: 204, headers: noStore });
      }
      if (pathname === "/api/access-requests" && req.method === "GET") return await reviewRequests(db, secret, req, user);
      const requestID = pathname.match(/^\/api\/access-requests\/([a-f0-9-]+)$/)?.[1];
      if (requestID && uuidPattern.test(requestID) && ["POST", "DELETE"].includes(req.method)) {
        return await reviewRequests(db, secret, req, user, requestID);
      }
      if (pathname === "/api/users" && req.method === "GET") return await manageAccess(db, req, user);
      const userID = pathname.startsWith("/api/users/") ? pathname.slice("/api/users/".length) : "";
      if (req.method === "PATCH" && uuidPattern.test(userID)) return await manageAccess(db, req, user, userID.toLowerCase());
      if (pathname === "/api/nodes" && req.method === "GET") return await listNodes(db, url.searchParams.get("parent"));
      if (pathname === "/api/nodes" && req.method === "POST") return await createNode(db, req, user);
      const resource = pathname.match(/^\/api\/assets\/([A-Z0-9-]+)\/(latest|releases)$/);
      if (resource?.[2] === "latest" && req.method === "GET") return await latest(db, env, resource[1]);
      if (resource?.[2] === "releases" && req.method === "POST") return await publish(db, env, req, user, resource[1]);
      throw new APIError(404, "Ruta de catálogo desconocida.");
    } catch (error) {
      if (error instanceof APIError) return json({ message: error.message }, error.status);
      console.error("Nexus Lab request failed", error?.name ?? "Error");
      return json({ message: "Error temporal del catálogo. Vuelve a intentar." }, 503);
    }
  },
};
