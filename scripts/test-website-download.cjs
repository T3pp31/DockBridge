// Run the actual inline website script without a browser or network access.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "../website/index.html"), "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1);
const source = scripts[0][1];
const repo = "T3pp31/DockBridge";
const releasesURL = `https://github.com/${repo}/releases/latest`;
const apiURL = `https://api.github.com/repos/${repo}/releases/latest`;
const dmgURL = `https://github.com/${repo}/releases/download/v1.2.3/DockBridge-1.2.3-macOS.dmg`;
const cacheKey = `github-release:${repo}`;
const now = 1_800_000_000_000;
const cacheTTL = 60 * 60 * 1000;
const release = {
  tag_name: "v1.2.3",
  assets: [
    { name: "checksums.txt", browser_download_url: "https://example.invalid/checksums.txt" },
    { name: "DockBridge-1.2.3-macOS.dmg", browser_download_url: dmgURL },
  ],
};

function response(status, body = release, headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (name) => headers[name.toLowerCase()] ?? null },
    json: async () => body,
  };
}

async function loadPage({ fetch = async () => response(200), storage = new Map(), storageError = false } = {}) {
  const classes = new Set(["is-loading"]);
  const attributes = new Set(["aria-busy"]);
  const button = {
    href: releasesURL,
    textContent: "Download for macOS",
    classList: { remove: (name) => classes.delete(name) },
    removeAttribute: (name) => attributes.delete(name),
  };
  const meta = { textContent: "Loading latest release…" };
  const requests = [];
  await vm.runInNewContext(source, {
    document: {
      getElementById: (id) => {
        assert.ok(["download-button", "download-meta"].includes(id));
        return id === "download-button" ? button : meta;
      },
    },
    fetch: async (...args) => {
      requests.push(args);
      return fetch(...args);
    },
    localStorage: {
      getItem: (key) => {
        if (storageError) throw new Error("Storage disabled");
        return storage.get(key) ?? null;
      },
      setItem: (key, value) => {
        if (storageError) throw new Error("Storage disabled");
        storage.set(key, value);
      },
    },
    Date: { now: () => now },
  });
  // Also drain promise chains when checking the pre-fix (non-async) script.
  await new Promise(setImmediate);
  assert.equal(classes.has("is-loading"), false);
  assert.equal(attributes.has("aria-busy"), false);
  assert.equal(button.textContent, "Download for macOS");
  return { button, meta, requests, storage };
}

function assertFallback(page, pattern) {
  assert.equal(page.button.href, releasesURL);
  assert.match(page.meta.textContent, pattern);
  assert.match(page.meta.textContent, /Releases page/);
  assert.equal(page.storage.has(cacheKey), false);
}

test("a successful release selects the DMG and clears the loading state", async () => {
  const page = await loadPage();
  assert.equal(page.button.href, dmgURL);
  assert.equal(page.meta.textContent, "Version 1.2.3 · macOS 15+");
  assert.equal(page.requests.length, 1);
  assert.equal(page.requests[0][0], apiURL);
  assert.equal(page.requests[0][1].headers.Accept, "application/vnd.github+json");
  assert.equal(page.requests[0][1].headers.Authorization, undefined);
});

for (const assets of [undefined, [], [release.assets[0]]]) {
  test(`a release without a DMG (${JSON.stringify(assets)}) still links to Releases with its version`, async () => {
    const page = await loadPage({ fetch: async () => response(200, { tag_name: "v1.2.3", assets }) });
    assertFallback(page, /Version 1\.2\.3/);
  });
}

for (const [status, headers] of [
  [403, { "x-ratelimit-remaining": "0" }],
  [403, { "retry-after": "60" }],
  [429, {}],
]) {
  test(`HTTP ${status} with ${JSON.stringify(headers)} reports rate limiting, not a network failure`, async () => {
    const page = await loadPage({ fetch: async () => response(status, null, headers) });
    assertFallback(page, /GitHub API rate limit reached/);
    assert.doesNotMatch(page.meta.textContent, /Could not reach/);
  });
}

for (const status of [403, 404, 500]) {
  test(`HTTP ${status} without rate-limit evidence reports the HTTP error`, async () => {
    const page = await loadPage({ fetch: async () => response(status) });
    assertFallback(page, new RegExp(`HTTP ${status}`));
    assert.doesNotMatch(page.meta.textContent, /Could not reach|rate limit reached/);
  });
}

test("a rejected fetch retains the network-failure message and Releases link", async () => {
  const page = await loadPage({ fetch: async () => { throw new TypeError("Failed to fetch"); } });
  assertFallback(page, /Could not reach the GitHub API/);
});

test("invalid JSON does not report a network failure", async () => {
  const page = await loadPage({ fetch: async () => ({
    ...response(200),
    json: async () => { throw new SyntaxError("Invalid JSON"); },
  }) });
  assertFallback(page, /Could not read the latest release/);
});

test("a fresh successful cache avoids a second API call and preserves the direct link", async () => {
  const first = await loadPage();
  assert.equal(first.storage.has(cacheKey), true);
  const second = await loadPage({
    storage: first.storage,
    fetch: async () => { throw new Error("Cached page must not fetch"); },
  });
  assert.equal(second.requests.length, 0);
  assert.equal(second.button.href, dmgURL);
  assert.equal(second.meta.textContent, first.meta.textContent);
});

test("a cache remains usable until just before the one-hour boundary", async () => {
  const storage = new Map([[cacheKey, JSON.stringify({
    url: dmgURL, tag: "v1.2.3", savedAt: now - cacheTTL + 1,
  })]]);
  const page = await loadPage({ storage });
  assert.equal(page.requests.length, 0);
  assert.equal(page.button.href, dmgURL);
});

test("an expired cache does not hide a subsequent rate-limit response", async () => {
  const storage = new Map([[cacheKey, JSON.stringify({
    url: dmgURL, tag: "v1.2.3", savedAt: now - cacheTTL,
  })]]);
  const page = await loadPage({ storage, fetch: async () => response(429) });
  assert.equal(page.requests.length, 1);
  assert.equal(page.button.href, releasesURL);
  assert.match(page.meta.textContent, /GitHub API rate limit reached/);
});

for (const [name, value] of [
  ["expired", JSON.stringify({ url: dmgURL, tag: "v0.9", savedAt: now - cacheTTL })],
  ["future timestamp", JSON.stringify({ url: dmgURL, tag: "v0.9", savedAt: now + 1 })],
  ["invalid timestamp", JSON.stringify({ url: dmgURL, tag: "v0.9", savedAt: "yesterday" })],
  ["corrupt JSON", "{"],
  ["missing fields", "{}"],
  ["unsafe URL", JSON.stringify({ url: "javascript:alert(1)", tag: "v0.9", savedAt: now })],
  ["other repository", JSON.stringify({ url: "https://github.com/other/repo/releases/download/v1/app.dmg", tag: "v0.9", savedAt: now })],
]) {
  test(`a cache with ${name} is ignored and refreshed`, async () => {
    const page = await loadPage({ storage: new Map([[cacheKey, value]]) });
    assert.equal(page.requests.length, 1);
    assert.equal(page.button.href, dmgURL);
    assert.equal(JSON.parse(page.storage.get(cacheKey)).tag, "v1.2.3");
  });
}

test("unavailable storage does not break a successful download", async () => {
  const page = await loadPage({ storageError: true });
  assert.equal(page.requests.length, 1);
  assert.equal(page.button.href, dmgURL);
  assert.equal(page.meta.textContent, "Version 1.2.3 · macOS 15+");
});

test("an API failure is not cached and the next visit can recover", async () => {
  const first = await loadPage({ fetch: async () => response(429) });
  assert.equal(first.storage.has(cacheKey), false);
  const second = await loadPage({ storage: first.storage });
  assert.equal(second.requests.length, 1);
  assert.equal(second.button.href, dmgURL);
});
