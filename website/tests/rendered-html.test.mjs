import assert from "node:assert/strict";
import test from "node:test";

async function render(path = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request(`http://localhost${path}`, {
      headers: { accept: "text/html", host: "localhost" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the EQ for Mac landing page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>EQ for Mac — System-wide equalizer for macOS<\/title>/i);
  assert.match(html, /Make your Mac sound like yours\./);
  assert.match(html, /Download for macOS/);
  assert.match(html, /Not Apple-notarized/);
  assert.match(html, /Illustrated installation guide/);
  assert.match(html, /brew install --cask eq-for-mac/);
  assert.match(html, /Copy command/);
  assert.match(html, /Switch to dark mode/);
  assert.match(html, /prefers-color-scheme: dark/);
  assert.match(html, /6,808/);
  assert.match(html, /og\.png/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/);
});

test("server-renders the illustrated Gatekeeper installation guide", async () => {
  const response = await render("/install");
  assert.equal(response.status, 200);

  const html = await response.text();
  assert.match(html, /Install it safely, warning and all\./);
  assert.match(html, /Privacy &amp; Security/);
  assert.match(html, /Open Anyway/);
  assert.match(html, /gatekeeper-warning\.png/);
  assert.match(html, /privacy-security-open-anyway\.png/);
  assert.match(html, /system-audio-permission\.png/);
  assert.match(html, /brew install --cask eq-for-mac/);
  assert.match(html, /shasum -a 256 -c/);
  assert.match(html, /xattr -dr com\.apple\.quarantine/);
  assert.match(html, /Copy command/);
  assert.doesNotMatch(html, /--no-quarantine|spctl --master-disable/);
});
