(function (root) {
  "use strict";

  const PAIRING_KEY_RE = /^umk_([0-9a-f]{64})$/;
  const NONCE_HEX_RE = /^[0-9a-f]{64}$/;
  const encoder = new TextEncoder();

  function bytesToHex(bytes) {
    let hex = "";
    for (let i = 0; i < bytes.length; i++) {
      hex += bytes[i].toString(16).padStart(2, "0");
    }
    return hex;
  }

  function parsePairingKey(text) {
    if (typeof text !== "string") {
      return null;
    }
    const normalized = text.trim().toLowerCase();
    const match = PAIRING_KEY_RE.exec(normalized);
    if (!match) {
      return null;
    }
    const hex = match[1];
    const bytes = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    }
    return bytes;
  }

  function isNonceHex(s) {
    return typeof s === "string" && NONCE_HEX_RE.test(s);
  }

  function randomNonceHex() {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return bytesToHex(bytes);
  }

  async function computeProof(keyBytes, role, clientNonce, serverNonce) {
    if (!(keyBytes instanceof Uint8Array) || keyBytes.length !== 32) {
      throw new Error("keyBytes must be a 32-byte Uint8Array.");
    }
    const hmacKey = await crypto.subtle.importKey(
      "raw",
      keyBytes,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const message = encoder.encode(`usemac-bridge-v2|${role}|${clientNonce}|${serverNonce}`);
    const signature = await crypto.subtle.sign("HMAC", hmacKey, message);
    return bytesToHex(new Uint8Array(signature));
  }

  async function serverProof(keyBytes, clientNonce, serverNonce) {
    return computeProof(keyBytes, "server", clientNonce, serverNonce);
  }

  async function clientProof(keyBytes, clientNonce, serverNonce) {
    return computeProof(keyBytes, "client", clientNonce, serverNonce);
  }

  function timingSafeEqualHex(a, b) {
    if (typeof a !== "string" || typeof b !== "string") {
      return false;
    }
    if (a.length !== b.length) {
      return false;
    }
    let diff = 0;
    for (let i = 0; i < a.length; i++) {
      diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    return diff === 0;
  }

  const api = Object.freeze({
    parsePairingKey,
    randomNonceHex,
    serverProof,
    clientProof,
    timingSafeEqualHex,
    isNonceHex
  });

  root.UsemacBridgeAuth = api;
  if (typeof self !== "undefined" && self !== root) {
    self.UsemacBridgeAuth = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : self);
