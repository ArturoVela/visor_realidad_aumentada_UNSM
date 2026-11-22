import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

const [, , secretFile, pinFile, extra] = process.argv;
if (!secretFile || !pinFile || extra) {
  console.error("Uso: node bootstrap-admin.mjs archivo-secreto archivo-pin");
  process.exit(2);
}
const email = "dev@velaarturo.com";
const secret = readFileSync(secretFile, "utf8").trim();
const pin = readFileSync(pinFile, "utf8").trim();
if (secret.length < 32 || !/^[0-9]{6}$/.test(pin)) {
  console.error("Se requiere un secreto de al menos 32 caracteres y un PIN de seis dígitos.");
  process.exit(2);
}
const pinHash = createHmac("sha256", secret).update(`pin:${email}:${pin}`).digest("hex");
const retiredHash = createHash("sha256").update(randomBytes(32)).digest("hex");
process.stdout.write(`INSERT INTO users (id,email,role,access_hash,pin_hash)
VALUES ('${randomUUID()}','${email}','admin','${retiredHash}','${pinHash}')
ON CONFLICT(email) DO UPDATE SET pin_hash=excluded.pin_hash,access_hash=excluded.access_hash,active=1
WHERE users.role='admin';
DELETE FROM sessions WHERE user_id IN (SELECT id FROM users WHERE email='${email}' AND role='admin');
DELETE FROM access_requests WHERE email='${email}' AND kind='restablecer';\n`);
