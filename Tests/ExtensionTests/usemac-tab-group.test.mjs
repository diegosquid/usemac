import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

// Every window has at most one "UseMac" tab group, however many agents' commands group tabs at once.
const TITLE = "UseMac";
const RESTRICTED = "https://chromewebstore.google.com/detail/usemac/abcdefghijklmnop"; // opens without a debugger
const REMEMBERED_KEY = "usemacGroupIdsByWindow";
// Chrome takes a few ms per tab-group call; without it every fake call lands in the same microtask turn.
const groupLatency = (api) => (api === "tabs.group" || api.startsWith("tabGroups.") ? 4 : 0);

let counter = 0;
const nextId = () => `group-${++counter}`;

function withSandbox(t, options) {
  const sandbox = createBackgroundSandbox(options);
  t.after(() => sandbox.dispose());
  return sandbox;
}

const usemacGroups = (sb, windowId) =>
  Array.from(sb.groups.values()).filter((g) => g.title === TITLE && (windowId == null || g.windowId === windowId));
const tabsInGroup = (sb, groupId) =>
  Array.from(sb.tabs.values()).filter((t) => t.groupId === groupId).map((t) => t.id).sort((a, b) => a - b);
const groupsCreated = (sb) => sb.callsTo("tabs.group").filter((c) => c.args[0].groupId == null);
const ensureGrouped = (sb, tabId) => sb.call("ensureTabInUsemacGroup", tabId);

function userTabs(ids, windowId = 1, extra = {}) {
  return ids.map((id, index) => ({ id, windowId, index, url: `https://example.com/${id}`, ...extra }));
}

test("tabs grouped at the same time in one window share one UseMac group", async (t) => {
  const ids = [11, 12, 13, 14];
  const sb = withSandbox(t, { tabs: userTabs(ids), windows: [{ id: 1, focused: true }], apiDelayMs: groupLatency });

  await Promise.all(ids.map((id) => ensureGrouped(sb, id)));

  const groups = usemacGroups(sb, 1);
  assert.equal(groups.length, 1, `one UseMac group, got ${JSON.stringify(Array.from(sb.groups.values()))}`);
  assert.deepEqual(tabsInGroup(sb, groups[0].id), ids);
  assert.equal(groups[0].color, "blue");
  assert.equal(groupsCreated(sb).length, 1, "only the first call creates a group");
});

test("an open and observes on other tabs at the same time leave one UseMac group", async (t) => {
  const sb = withSandbox(t, {
    tabs: userTabs([21, 22, 23]),
    windows: [{ id: 1, focused: true }],
    apiDelayMs: groupLatency
  });

  const results = await Promise.all([
    sb.request({ type: "request", id: nextId(), command: "open", url: RESTRICTED, stream: false }),
    sb.request({ type: "request", id: nextId(), command: "observe", tabId: 21 }),
    sb.request({ type: "request", id: nextId(), command: "observe", tabId: 22 }),
    sb.request({ type: "request", id: nextId(), command: "observe", tabId: 23 })
  ]);
  for (const { response } of results) assert.equal(response.ok, true, JSON.stringify(response.error));

  const groups = usemacGroups(sb, 1);
  assert.equal(groups.length, 1, `one UseMac group, got ${JSON.stringify(Array.from(sb.groups.values()))}`);
  assert.deepEqual(tabsInGroup(sb, groups[0].id), [21, 22, 23, results[0].response.tabId].sort((a, b) => a - b));
});

test("a window with several UseMac groups is folded into one, and other groups are left alone", async (t) => {
  // What Diego's window looked like: four UseMac groups side by side, next to a group of his own.
  const sb = withSandbox(t, {
    windows: [{ id: 1, focused: true }, { id: 2 }],
    groups: [
      { id: 41, windowId: 1, title: TITLE, color: "blue" },
      { id: 42, windowId: 1, title: TITLE, color: "blue" },
      { id: 43, windowId: 1, title: TITLE, color: "blue" },
      { id: 44, windowId: 1, title: TITLE, color: "blue" },
      { id: 50, windowId: 1, title: "Work", color: "red" },
      { id: 60, windowId: 2, title: TITLE, color: "blue" }
    ],
    tabs: [
      { id: 101, windowId: 1, index: 0, url: "https://example.com/mail", active: true },
      { id: 102, windowId: 1, index: 1, url: "https://example.com/work-a", groupId: 50 },
      { id: 103, windowId: 1, index: 2, url: "https://example.com/work-b", groupId: 50 },
      { id: 111, windowId: 1, index: 3, url: "https://example.com/a", groupId: 41 },
      { id: 112, windowId: 1, index: 4, url: "https://example.com/b", groupId: 41 },
      { id: 121, windowId: 1, index: 5, url: "https://example.com/c", groupId: 42 },
      { id: 131, windowId: 1, index: 6, url: "https://example.com/d", groupId: 43 },
      { id: 141, windowId: 1, index: 7, url: "https://example.com/e", groupId: 44 },
      { id: 201, windowId: 2, index: 0, url: "https://example.com/other-window", groupId: 60 }
    ]
  });

  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: RESTRICTED, stream: false });
  assert.equal(response.ok, true, JSON.stringify(response.error));

  const groups = usemacGroups(sb, 1);
  assert.equal(groups.length, 1, "one UseMac group left in the window");
  assert.equal(groups[0].id, 41, "the leftmost group is kept");
  assert.deepEqual(tabsInGroup(sb, 41), [111, 112, 121, 131, 141, response.tabId].sort((a, b) => a - b));
  for (const gone of [42, 43, 44]) assert.equal(sb.groups.has(gone), false, `empty group ${gone} is gone`);

  // The user's own group, the ungrouped tab and the other window's UseMac group are untouched.
  assert.deepEqual(tabsInGroup(sb, 50), [102, 103]);
  assert.equal(sb.groups.get(50).title, "Work");
  assert.equal(sb.tabs.get(101).groupId, -1);
  assert.deepEqual(tabsInGroup(sb, 60), [201]);
  for (const call of sb.callsTo("tabs.group")) {
    assert.ok(!call.args[0].tabIds.some((id) => [101, 102, 103, 201].includes(id)), `moved only UseMac tabs: ${JSON.stringify(call)}`);
  }
  assert.equal(groupsCreated(sb).length, 0, "no new group");
  assert.ok(!sb.callsTo("tabGroups.update").some((c) => c.args[0] === 50));
});

test("folding keeps the group UseMac was already using", async (t) => {
  const sb = withSandbox(t, {
    windows: [{ id: 1, focused: true }],
    session: { [REMEMBERED_KEY]: { 1: 43 } },
    groups: [
      { id: 41, windowId: 1, title: TITLE, color: "blue" },
      { id: 43, windowId: 1, title: TITLE, color: "blue" }
    ],
    tabs: [
      { id: 111, windowId: 1, index: 0, url: "https://example.com/a", groupId: 41 },
      { id: 131, windowId: 1, index: 1, url: "https://example.com/b", groupId: 43 },
      { id: 150, windowId: 1, index: 2, url: "https://example.com/new" }
    ]
  });

  await ensureGrouped(sb, 150);

  assert.deepEqual(usemacGroups(sb, 1).map((g) => g.id), [43]);
  assert.deepEqual(tabsInGroup(sb, 43), [111, 131, 150]);
});

test("a remembered group that is gone, renamed or in another window is not reused", async (t) => {
  const cases = [
    { name: "closed since a worker restart", remembered: 777, groups: [] },
    { name: "renamed by the user", remembered: 60, groups: [{ id: 60, windowId: 1, title: "Research", color: "green" }] },
    { name: "dragged to another window", remembered: 70, groups: [{ id: 70, windowId: 2, title: TITLE, color: "blue" }] }
  ];
  for (const c of cases) {
    const sb = createBackgroundSandbox({
      windows: [{ id: 1, focused: true }, { id: 2 }],
      session: { [REMEMBERED_KEY]: { 1: c.remembered } },
      groups: c.groups,
      tabs: [
        { id: 301, windowId: 1, index: 0, url: "https://example.com/new" },
        { id: 302, windowId: 1, index: 1, url: "https://example.com/research", groupId: 60 },
        { id: 401, windowId: 2, index: 0, url: "https://example.com/other", groupId: 70 }
      ].filter((tab) => tab.groupId == null || c.groups.some((g) => g.id === tab.groupId))
    });
    try {
      await ensureGrouped(sb, 301);

      const groups = usemacGroups(sb, 1);
      assert.equal(groups.length, 1, `${c.name}: one UseMac group in the window`);
      assert.notEqual(groups[0].id, c.remembered, `${c.name}: a new group`);
      assert.deepEqual(tabsInGroup(sb, groups[0].id), [301], c.name);
      assert.ok(!sb.callsTo("tabs.group").some((call) => call.args[0].groupId === c.remembered), `${c.name}: stale id not used`);
      for (const g of c.groups) assert.deepEqual(sb.groups.get(g.id), { ...g, collapsed: false }, `${c.name}: group ${g.id} untouched`);
      assert.equal(sb.session[REMEMBERED_KEY]["1"], groups[0].id, `${c.name}: the new group is remembered`);
    } finally {
      sb.dispose();
    }
  }
});

test("a tab dragged out of the group rejoins it, and a closed group is replaced", async (t) => {
  const sb = withSandbox(t, { tabs: userTabs([31, 32, 33]), windows: [{ id: 1, focused: true }] });

  await ensureGrouped(sb, 31);
  await ensureGrouped(sb, 32);
  const [first] = usemacGroups(sb, 1);
  assert.deepEqual(tabsInGroup(sb, first.id), [31, 32]);

  sb.ungroupTab(32);
  await ensureGrouped(sb, 32);
  assert.deepEqual(usemacGroups(sb, 1).map((g) => g.id), [first.id]);
  assert.deepEqual(tabsInGroup(sb, first.id), [31, 32]);

  // Every tab of the group closes, so Chrome drops it; the next tab gets a fresh group.
  await sb.chrome.tabs.remove(31);
  await sb.chrome.tabs.remove(32);
  assert.equal(sb.groups.has(first.id), false);
  await ensureGrouped(sb, 33);
  const groups = usemacGroups(sb, 1);
  assert.equal(groups.length, 1);
  assert.deepEqual(tabsInGroup(sb, groups[0].id), [33]);
  assert.equal(groupsCreated(sb).length, 2);
});

test("each window gets its own UseMac group", async (t) => {
  const sb = withSandbox(t, {
    tabs: [...userTabs([51, 52], 1), ...userTabs([61, 62], 2)],
    windows: [{ id: 1, focused: true }, { id: 2 }],
    apiDelayMs: groupLatency
  });

  await Promise.all([51, 61, 52, 62].map((id) => ensureGrouped(sb, id)));

  const [w1] = usemacGroups(sb, 1);
  const [w2] = usemacGroups(sb, 2);
  assert.equal(usemacGroups(sb).length, 2);
  assert.deepEqual(tabsInGroup(sb, w1.id), [51, 52]);
  assert.deepEqual(tabsInGroup(sb, w2.id), [61, 62]);
});

test("when Chrome refuses the fold, the tab still joins the kept group and the next call folds", async (t) => {
  const sb = withSandbox(t, {
    windows: [{ id: 1, focused: true }],
    groups: [
      { id: 41, windowId: 1, title: TITLE, color: "blue" },
      { id: 42, windowId: 1, title: TITLE, color: "blue" }
    ],
    tabs: [
      { id: 111, windowId: 1, index: 0, url: "https://example.com/a", groupId: 41 },
      { id: 121, windowId: 1, index: 1, url: "https://example.com/b", groupId: 42 },
      { id: 130, windowId: 1, index: 2, url: "https://example.com/new" },
      { id: 131, windowId: 1, index: 3, url: "https://example.com/newer" }
    ]
  });
  const realGroup = sb.chrome.tabs.group;
  let refused = 0;
  sb.chrome.tabs.group = async (props) => {
    // The first call is the fold (tab 121 into group 41).
    if (refused++ === 0) {
      throw new Error("Tabs cannot be edited right now (user may be dragging a tab).");
    }
    return realGroup(props);
  };

  await ensureGrouped(sb, 130);
  assert.deepEqual(usemacGroups(sb, 1).map((g) => g.id), [41, 42], "nothing folded while Chrome refused");
  assert.equal(sb.tabs.get(130).groupId, 41, "the tab joined the kept group");

  await ensureGrouped(sb, 131);
  assert.deepEqual(usemacGroups(sb, 1).map((g) => g.id), [41]);
  assert.deepEqual(tabsInGroup(sb, 41), [111, 121, 130, 131]);
  assert.equal(groupsCreated(sb).length, 0);
});

test("no group is made when Chrome cannot list the window's groups", async (t) => {
  const sb = withSandbox(t, {
    windows: [{ id: 1, focused: true }],
    groups: [{ id: 41, windowId: 1, title: TITLE, color: "blue" }],
    tabs: [
      { id: 111, windowId: 1, index: 0, url: "https://example.com/a", groupId: 41 },
      { id: 130, windowId: 1, index: 1, url: "https://example.com/new" }
    ]
  });
  sb.chrome.tabGroups.query = async () => {
    throw new Error("Unexpected error.");
  };

  await ensureGrouped(sb, 130);
  assert.equal(sb.callsTo("tabs.group").length, 0);
  assert.equal(sb.tabs.get(130).groupId, -1);
});
