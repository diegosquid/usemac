import test from "node:test";
import assert from "node:assert/strict";
import "../../Extension/bridge-auth.js";

const auth = globalThis.UsemacBridgeAuth;

const VECTOR_KEY_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const VECTOR_KEY_TEXT = `umk_${VECTOR_KEY_HEX}`;
const VECTOR_CLIENT_NONCE = "aa".repeat(32);
const VECTOR_SERVER_NONCE = "bb".repeat(32);
const VECTOR_SERVER_PROOF = "0dc1c8449ec46032d911453f6e6668ee5474655b9f6b9d6de080377afc9f794a";
const VECTOR_CLIENT_PROOF = "c98c470a7e7cf4f566d842b2a2fcdd46e9894e13bcfe448ad0c180cb17fa4f35";

test("protocol v2 test vector reproduces exact serverProof and clientProof", async () => {
  const keyBytes = auth.parsePairingKey(VECTOR_KEY_TEXT);
  assert.ok(keyBytes instanceof Uint8Array);
  assert.equal(keyBytes.length, 32);

  const sp = await auth.serverProof(keyBytes, VECTOR_CLIENT_NONCE, VECTOR_SERVER_NONCE);
  const cp = await auth.clientProof(keyBytes, VECTOR_CLIENT_NONCE, VECTOR_SERVER_NONCE);

  assert.equal(sp, VECTOR_SERVER_PROOF);
  assert.equal(cp, VECTOR_CLIENT_PROOF);
});

test("parsePairingKey accepts canonical, trimmed, and uppercase forms and returns 32 bytes", () => {
  const expected = Uint8Array.from(Array.from({ length: 32 }, (_, i) => i));

  const canonical = auth.parsePairingKey(VECTOR_KEY_TEXT);
  assert.deepEqual(canonical, expected);

  const trimmedAndUpper = auth.parsePairingKey(`  \t ${VECTOR_KEY_TEXT.toUpperCase()} \n `);
  assert.deepEqual(trimmedAndUpper, expected);
});

test("parsePairingKey rejects empty, missing prefix, wrong length, and non-hex inputs", () => {
  assert.equal(auth.parsePairingKey(""), null);
  assert.equal(auth.parsePairingKey(VECTOR_KEY_HEX), null);
  assert.equal(auth.parsePairingKey(`umk_${VECTOR_KEY_HEX.slice(0, 63)}`), null);
  assert.equal(auth.parsePairingKey(`umk_${VECTOR_KEY_HEX}0`), null);
  assert.equal(auth.parsePairingKey(`umk_${VECTOR_KEY_HEX.slice(0, 63)}g`), null);
});

test("randomNonceHex returns 64 lowercase hex characters and consecutive values differ", () => {
  const first = auth.randomNonceHex();
  const second = auth.randomNonceHex();

  assert.match(first, /^[0-9a-f]{64}$/);
  assert.match(second, /^[0-9a-f]{64}$/);
  assert.equal(auth.isNonceHex(first), true);
  assert.equal(auth.isNonceHex(second), true);
  assert.notEqual(first, second);
});

test("timingSafeEqualHex returns true for equal strings and false for unequal strings or lengths", () => {
  assert.equal(auth.timingSafeEqualHex(VECTOR_SERVER_PROOF, VECTOR_SERVER_PROOF), true);
  assert.equal(auth.timingSafeEqualHex(VECTOR_SERVER_PROOF, VECTOR_CLIENT_PROOF), false);
  assert.equal(auth.timingSafeEqualHex(VECTOR_SERVER_PROOF, VECTOR_SERVER_PROOF.slice(0, -1)), false);
});

test("changing one character of serverNonce changes serverProof", async () => {
  const keyBytes = auth.parsePairingKey(VECTOR_KEY_TEXT);
  const alteredServerNonce = `${VECTOR_SERVER_NONCE.slice(0, -1)}c`;

  const original = await auth.serverProof(keyBytes, VECTOR_CLIENT_NONCE, VECTOR_SERVER_NONCE);
  const changed = await auth.serverProof(keyBytes, VECTOR_CLIENT_NONCE, alteredServerNonce);

  assert.notEqual(changed, original);
});
