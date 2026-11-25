# usemac Browser Bridge protocol (v2)

Contract between the Chrome extension (`Extension/`) and the daemon bridge
(`Sources/MacUseEngine/ChromeExtensionBridge.swift`). Both sides must implement it exactly.

## Transport

- WebSocket, text frames, one JSON object per frame.
- The extension is the client and connects to `ws://127.0.0.1:49222/macuse-bridge`.
- The daemon binds `127.0.0.1` only and accepts the WebSocket upgrade only when the `Origin` header starts with
  `chrome-extension://`. Authentication below, not the port, is what proves each side to the other.

## Pairing key

- One key per Mac user, created by the daemon on first start: 32 random bytes.
- Text form shown to the user and pasted into the extension popup: `umk_` followed by 64 lowercase hex characters
  (68 characters in total). Input is trimmed and compared case-insensitively; anything else is rejected.
- The HMAC key `K` is the 32 decoded bytes (never the text form).
- Daemon storage: `~/Library/Application Support/usemac/bridge-key`, file mode `0600`, directory mode `0700`,
  content is the text form followed by a newline.
- Extension storage: `chrome.storage.local`, item `bridgeKey`, value is the text form.

## Handshake

All nonces are 32 random bytes written as 64 lowercase hex characters. All proofs are HMAC-SHA256 outputs written
as 64 lowercase hex characters. Proofs are compared in constant time. `|` below is the literal ASCII character.

1. Extension → daemon, first frame after the socket opens:

   ```json
   {"type":"hello","protocol":2,"extensionVersion":"0.5.0","profileName":"Work","clientNonce":"<64 hex>","hasKey":true}
   ```

   `hello` carries no e-mail, no window titles and no tab count. A `hello` whose `protocol` is not `2`, or whose
   `clientNonce` is not 64 hex characters, gets `{"type":"auth_failed","reason":"bad_hello"}` and the socket is closed.

2. If `hasKey` is `false`, the daemon answers `{"type":"pairing_required"}` and keeps the socket open and
   unauthenticated. The extension may send a new `hello` on the same socket once the user has pasted a key.

3. If `hasKey` is `true`, the daemon answers:

   ```json
   {"type":"challenge","serverNonce":"<64 hex>","serverProof":"<64 hex>"}
   ```

   `serverProof = HMAC-SHA256(K, utf8("usemac-bridge-v2|server|" + clientNonce + "|" + serverNonce))`

   The extension verifies `serverProof`. On mismatch it closes the socket, enters the state `key_mismatch`, sends
   nothing else, and retries no more often than every 30 seconds. This covers both a wrong key and a process
   pretending to be the daemon.

4. Extension → daemon:

   ```json
   {"type":"auth","clientProof":"<64 hex>"}
   ```

   `clientProof = HMAC-SHA256(K, utf8("usemac-bridge-v2|client|" + clientNonce + "|" + serverNonce))`

   The daemon verifies it. On success it answers `{"type":"ready"}`. On failure it answers
   `{"type":"auth_failed","reason":"bad_proof"}` and closes the socket. Each `challenge` is valid for one `auth`.

5. After `ready`, the extension sends `{"type":"profile_info","profileName":"Work","tabCount":12}` and repeats it
   whenever the profile name changes.

### Rules before `ready`

- The extension ignores every `request` and `cancel` frame.
- The daemon never sends `request` or `cancel`, and drops `response`, `frame`, `cursor`, `stream_stopped` and
  `profile_info` frames. An unauthenticated session is never listed as a connected profile for agents.
- `ping` / `pong` frames are allowed in any state.

### Test vector

```
K            = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
key text     = umk_000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
clientNonce  = aa repeated 32 times (64 characters)
serverNonce  = bb repeated 32 times (64 characters)
serverProof  = 0dc1c8449ec46032d911453f6e6668ee5474655b9f6b9d6de080377afc9f794a
clientProof  = c98c470a7e7cf4f566d842b2a2fcdd46e9894e13bcfe448ad0c180cb17fa4f35
```

## Commands after `ready`

Daemon → extension requests keep the existing shape: `{"type":"request","id":"<uuid>","command":"…", …}` with
`command` one of `tabs`, `open`, `observe`, `extract`, `screenshot`, `act`, `focus_tab`, `stop_stream`.
Extension → daemon frames keep the existing shapes: `response`, `frame`, `cursor`, `stream_stopped`, `ping`.

### `cancel` (new, daemon → extension)

```json
{"type":"cancel","tabId":123}
```

`tabId` is a number, or `null` for every tab. `cancel` has no `id`, gets no `response`, and is handled immediately,
outside the per-tab command queues:

- A running `act` batch on the affected tab stops before its next step and inside any `wait` step. Steps that did
  not run are reported with `success: false` and the message `Cancelled by usemac`. The batch answers with
  `ok: false` and `error: {"code":"CANCELLED","message":"Cancelled by usemac"}`.
- Commands still queued for the affected tab answer with the same error without running.
- The extension detaches the debugger from the affected tab (or from every tab) and emits `stream_stopped`.

## URL rule

`open`, and the `openURL` / `navigate` steps of `act`, accept only `http:` and `https:` URLs and the exact string
`about:blank`. Anything else answers `error: {"code":"URL_BLOCKED","message":"Only http(s) URLs can be opened."}`.
The daemon applies the same rule before sending; the extension applies it again.
