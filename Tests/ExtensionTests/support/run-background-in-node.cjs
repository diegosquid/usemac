// Runs the real Extension/background.js inside Node with a stubbed `chrome` API, so the Swift bridge tests can
// check that the extension and the daemon speak the same protocol (docs/BRIDGE-PROTOCOL.md).
//
// Usage: node run-background-in-node.cjs <port> <pairing key text or "none"> <profile name>
// Prints one line per auth state change: "STATE <wsState> <authState>".
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const [port, keyText, profileName] = process.argv.slice(2);
if (!port || !keyText || !profileName) {
  console.error("usage: run-background-in-node.cjs <port> <key|none> <profileName>");
  process.exit(2);
}

const extensionDir = path.resolve(__dirname, "..", "..", "..", "Extension");
const EXTENSION_ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";

const stubTabs = [
  { id: 101, title: "Interop One", url: "https://example.com/one", active: true, pinned: false, windowId: 1, groupId: -1 },
  { id: 102, title: "Interop Two", url: "https://example.com/two", active: false, pinned: false, windowId: 1, groupId: -1 }
];

const storage = { profileName };
if (keyText !== "none") {
  storage.bridgeKey = keyText;
}

// Every chrome.* member that is not listed below resolves to a no-op function that returns an empty result.
function looseStub(overrides = {}) {
  const target = function () {};
  return new Proxy(target, {
    get(_t, prop) {
      if (prop in overrides) return overrides[prop];
      if (prop === "then") return undefined;
      if (prop === Symbol.toPrimitive) return () => "";
      return looseStub();
    },
    apply() {
      return Promise.resolve(undefined);
    }
  });
}

const chromeStub = looseStub({
  runtime: looseStub({
    getManifest: () => ({ version: "0.5.0" })
  }),
  storage: looseStub({
    local: looseStub({
      get: async (keys) => {
        const out = {};
        for (const key of Array.isArray(keys) ? keys : [keys]) {
          if (key in storage) out[key] = storage[key];
        }
        return out;
      },
      set: async (values) => {
        Object.assign(storage, values);
      },
      remove: async (keys) => {
        for (const key of Array.isArray(keys) ? keys : [keys]) delete storage[key];
      }
    })
  }),
  tabs: looseStub({
    query: async () => stubTabs,
    get: async (id) => stubTabs.find((t) => t.id === id)
  }),
  tabGroups: looseStub({
    query: async () => [],
    TAB_GROUP_ID_NONE: -1
  }),
  windows: looseStub({
    getAll: async () => [{ id: 1, focused: true, tabs: stubTabs }]
  })
});

const NativeWebSocket = globalThis.WebSocket;
class LoopbackWebSocket extends NativeWebSocket {
  constructor(url) {
    super(String(url).replace(/127\.0\.0\.1:\d+/, `127.0.0.1:${port}`), { headers: { Origin: EXTENSION_ORIGIN } });
  }
}

globalThis.chrome = chromeStub;
globalThis.self = globalThis;
globalThis.WebSocket = LoopbackWebSocket;
globalThis.importScripts = (file) => {
  vm.runInThisContext(fs.readFileSync(path.join(extensionDir, file), "utf8"), { filename: file });
};

vm.runInThisContext(fs.readFileSync(path.join(extensionDir, "background.js"), "utf8"), { filename: "background.js" });

let lastLine = "";
setInterval(() => {
  const line = vm.runInThisContext('"STATE " + state.wsState + " " + state.authState');
  if (line !== lastLine) {
    lastLine = line;
    process.stdout.write(line + "\n");
  }
}, 25);

process.stdin.resume();
process.stdin.on("end", () => process.exit(0));
