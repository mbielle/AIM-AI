import test from "node:test";
import assert from "node:assert/strict";
import {
  createFileProcessor,
  MAX_FILE_BYTES,
  MAX_REQUEST_BYTES,
} from "./handler.ts";

const userID = "00000000-0000-4000-8000-000000000001";
function harness({ auth = 200, live = 200, liveValue = true, env = {} } = {}) {
  const calls = [];
  const handler = createFileProcessor({
    env: (name) =>
      ({
        SUPABASE_URL: "https://backend.example.invalid",
        SUPABASE_ANON_KEY: "public-test-key",
        ...env,
      })[name],
    fetch: async (url, options) => {
      calls.push({ url: String(url), options });
      assert.equal(new URL(url).origin, "https://backend.example.invalid");
      assert.equal(options.redirect, "error");
      assert.equal(options.headers.Authorization, "Bearer test-session");
      if (new URL(url).pathname === "/auth/v1/user")
        return Response.json({ id: userID }, { status: auth });
      assert.equal(
        new URL(url).pathname,
        "/rest/v1/rpc/aim_maintenance_session",
      );
      assert.equal(options.method, "POST");
      return Response.json(liveValue, { status: live });
    },
  });
  return { handler, calls };
}
function request(fields = {}, headers = {}) {
  return new Request("https://edge.example.invalid/file-processor", {
    method: "POST",
    headers: {
      Authorization: "Bearer test-session",
      "Content-Type": "application/json",
      ...headers,
    },
    body: JSON.stringify({
      file: btoa("fixture text"),
      fileName: "example.txt",
      fileType: "text/plain",
      forceOCR: false,
      ...fields,
    }),
  });
}
async function invoke(options = {}, fields = {}, headers = {}) {
  const h = harness(options),
    response = await h.handler(request(fields, headers));
  return { ...h, response, body: await response.json() };
}

test("requires POST and a bearer before any outbound call", async () => {
  const h = harness();
  assert.equal(
    (await h.handler(new Request("https://edge.example.invalid"))).status,
    405,
  );
  assert.equal(
    (await h.handler(request({}, { Authorization: "" }))).status,
    401,
  );
  assert.deepEqual(h.calls, []);
});
test("rejects advertised oversized payload before auth or parsing", async () => {
  const r = await invoke(
    {},
    {},
    { "Content-Length": String(MAX_REQUEST_BYTES + 1) },
  );
  assert.equal(r.response.status, 413);
  assert.equal(r.body.errorCode, "file_too_large");
  assert.deepEqual(r.calls, []);
});
test("bounds streamed bodies without Content-Length before outbound calls", async () => {
  const h = harness();
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(MAX_REQUEST_BYTES));
      controller.enqueue(new Uint8Array(1));
      controller.close();
    },
  });
  const result = await h.handler(
    new Request("https://edge.example.invalid", {
      method: "POST",
      headers: {
        Authorization: "Bearer test-session",
        "Content-Type": "application/json",
      },
      body: stream,
      duplex: "half",
    }),
  );
  assert.equal(result.status, 413);
  assert.deepEqual(h.calls, []);
});
test("bounds decoded file size and rejects malformed base64 before outbound calls", async () => {
  for (const file of [
    "https://example.invalid/private",
    "data:text/plain;base64,eA==",
    "!!!!",
    "A===",
  ]) {
    const r = await invoke({}, { file });
    assert.equal(r.response.status, 400);
    assert.deepEqual(r.calls, []);
  }
  const r = await invoke(
    {},
    { file: "A".repeat(Math.ceil(MAX_FILE_BYTES / 3) * 4 + 4) },
  );
  assert.equal(r.response.status, 413);
  assert.deepEqual(r.calls, []);
});
test("invalid auth stops before live-session RPC", async () => {
  const r = await invoke({ auth: 401 });
  assert.equal(r.response.status, 401);
  assert.equal(r.calls.length, 1);
});
test("revoked or invalid live session never extracts text", async () => {
  for (const options of [{ live: 403 }, { liveValue: false }]) {
    const r = await invoke(options);
    assert.equal(r.response.status, 401);
    assert.equal(r.body.errorCode, "session_revoked");
    assert.equal(r.body.extractedText, undefined);
    assert.equal(r.calls.length, 2);
  }
});
test("only own HTTPS Supabase endpoint is configurable", async () => {
  const credentialURL = new URL("https://backend.example.invalid");
  credentialURL.username = "fixture-user";
  credentialURL.password = "fixture-password";
  for (const SUPABASE_URL of [
    "http://backend.example.invalid",
    credentialURL.href,
    "https://backend.example.invalid/private",
  ]) {
    const r = await invoke({ env: { SUPABASE_URL } });
    assert.equal(r.response.status, 503);
    assert.deepEqual(r.calls, []);
  }
});
test("plain UTF-8 preserves text and native response contract without OCR", async () => {
  const text = "Title\n\nline two — example";
  const r = await invoke({}, { file: Buffer.from(text).toString("base64") });
  assert.equal(r.response.status, 200);
  assert.deepEqual(r.body, {
    status: "ok",
    fileName: "example.txt",
    originalType: "text/plain",
    extractedText: text,
    usedOcr: false,
  });
  assert.equal(r.calls.length, 2);
  assert.equal(r.response.headers.get("Cache-Control"), "no-store");
});
test("image and all unparsed PDFs explicitly need local OCR/extraction", async () => {
  for (const [fileType, errorCode] of [
    ["image/png", "image_requires_ocr"],
    ["application/pdf", "unsupported_pdf"],
  ]) {
    const r = await invoke({}, { fileType });
    assert.equal(r.body.status, "needs_ocr");
    assert.equal(r.body.errorCode, errorCode);
    assert.equal(r.body.extractedText, undefined);
    assert.equal(r.calls.length, 2);
  }
});
test("Office and unsupported formats are honest errors", async () => {
  for (const [fileType, errorCode] of [
    [
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "unsupported_office",
    ],
    ["application/vnd.ms-excel", "unsupported_office"],
    ["text/html", "unsupported_type"],
    ["application/rtf", "unsupported_type"],
  ]) {
    const r = await invoke({}, { fileType });
    assert.equal(r.body.status, "error");
    assert.equal(r.body.errorCode, errorCode);
    assert.equal(r.calls.length, 2);
  }
});
test("neither spelling of force OCR can trigger provider traffic", async () => {
  for (const fields of [{ forceOCR: true }, { forceOcr: true }]) {
    const r = await invoke({}, fields);
    assert.equal(r.body.status, "needs_ocr");
    assert.equal(r.body.errorCode, "ocr_unavailable");
    assert.equal(r.calls.length, 2);
  }
});
test("binary text and overlong extracted text never become completed content", async () => {
  for (const [file, errorCode] of [
    [Buffer.from([255]).toString("base64"), "invalid_text_encoding"],
    [
      Buffer.from("x".repeat(120001)).toString("base64"),
      "extracted_text_too_large",
    ],
  ]) {
    const r = await invoke({}, { file });
    assert.equal(r.body.status, "error");
    assert.equal(r.body.errorCode, errorCode);
  }
});

/** Complete JSON plus spaces remains valid, so these exercise byte limits rather than syntax errors. */
function streamedJSON(value, totalBytes, chunkBytes = 4096) {
  const prefix = new TextEncoder().encode(JSON.stringify(value));
  let consumed = 0,
    cancelled = false;
  assert.ok(totalBytes >= prefix.length);
  const response = new Response(
    new ReadableStream(
      {
        pull(controller) {
          if (consumed === totalBytes) {
            controller.close();
            return;
          }
          const chunk = new Uint8Array(
            Math.min(chunkBytes, totalBytes - consumed),
          ).fill(32);
          if (consumed < prefix.length)
            chunk.set(prefix.subarray(consumed, consumed + chunk.length));
          consumed += chunk.length;
          controller.enqueue(chunk);
        },
        cancel() {
          cancelled = true;
        },
      },
      { highWaterMark: 0 },
    ),
  );
  return { response, state: () => ({ consumed, cancelled }) };
}

function streamHarness(responses) {
  const calls = [];
  const handler = createFileProcessor({
    env: (name) => {
      assert.notEqual(name, "SUPABASE_SERVICE_ROLE_KEY");
      return {
        SUPABASE_URL: "https://backend.example.invalid",
        SUPABASE_ANON_KEY: "public-test-key",
      }[name];
    },
    fetch: async (url, options) => {
      calls.push(new URL(url).pathname);
      assert.equal(options.headers.Authorization, "Bearer test-session");
      assert.ok(
        calls.length <= responses.length,
        "no retry/provider/storage request follows a bounded response failure",
      );
      return responses[calls.length - 1];
    },
  });
  return { handler, calls };
}

test("oversized processor Auth stream is cancelled before live-session check or extraction", async () => {
  const auth = streamedJSON({ id: userID }, 1024 * 1024);
  const { handler, calls } = streamHarness([auth.response]);
  const response = await handler(request());
  assert.equal(response.status, 503);
  const body = await response.json();
  assert.equal(body.status, "error");
  assert.equal(body.errorCode, "service_unavailable");
  assert.equal(body.extractedText, undefined);
  assert.deepEqual(calls, ["/auth/v1/user"]);
  assert.equal(auth.state().cancelled, true);
  assert.ok(
    auth.state().consumed <= 65536 + 4096,
    "the 64 KiB Auth response limit cancels the remaining stream",
  );
});

test("oversized processor live-session stream is cancelled and never authorizes extraction", async () => {
  const live = streamedJSON(true, 1024, 16);
  const { handler, calls } = streamHarness([
    Response.json({ id: userID }),
    live.response,
  ]);
  const response = await handler(request());
  assert.equal(response.status, 503);
  const body = await response.json();
  assert.equal(body.status, "error");
  assert.equal(body.errorCode, "service_unavailable");
  assert.equal(body.extractedText, undefined);
  assert.deepEqual(calls, [
    "/auth/v1/user",
    "/rest/v1/rpc/aim_maintenance_session",
  ]);
  assert.equal(live.state().cancelled, true);
  assert.ok(
    live.state().consumed <= 64 + 16,
    "the 64-byte boolean-response limit stops the stream",
  );
});

test("processor accepts Auth and true live-session responses exactly at their byte limits", async () => {
  const auth = streamedJSON({ id: userID }, 65536),
    live = streamedJSON(true, 64, 16);
  const { handler, calls } = streamHarness([auth.response, live.response]);
  const response = await handler(request());
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.status, "ok");
  assert.equal(body.extractedText, "fixture text");
  assert.equal(calls.length, 2);
  assert.deepEqual(auth.state(), { consumed: 65536, cancelled: false });
  assert.deepEqual(live.state(), { consumed: 64, cancelled: false });
});
