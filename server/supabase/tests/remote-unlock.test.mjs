import test from "node:test";
import assert from "node:assert/strict";
import { createRemoteUnlock } from "../functions/_shared/remote-unlock.ts";
const user = { id: "50000000-0000-0000-0000-000000000001" };
const input = {
  action: "pin-verify",
  deviceId: "50000000-0000-0000-0000-000000000002",
  deviceSecret: "fixture-device-" + "x".repeat(32),
  pin: "123456",
};
const request = (
  body = input,
  headers = { Authorization: "Bearer fixture-user" },
) =>
  new Request("https://fixture.invalid", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
const env = (name) =>
  ({
    SUPABASE_URL: "https://fixture.invalid",
    SUPABASE_ANON_KEY: "fixture-public",
  })[name];
test("unlock rejects unauthenticated, malformed and unsupported WebAuthn requests before network", async () => {
  let calls = 0;
  const handler = createRemoteUnlock({
    env,
    fetch: async () => {
      calls++;
      throw Error("unexpected");
    },
  });
  assert.equal((await handler(request(input, {}))).status, 401);
  assert.equal(
    (await handler(request({ ...input, action: "passkey-register-options" })))
      .status,
    400,
  );
  assert.equal(
    (await handler(request({ ...input, deviceId: "invalid" }))).status,
    400,
  );
  assert.equal(calls, 0);
});
test("unlock validates Auth and uses only caller JWT for authoritative RPC", async () => {
  let calls = 0;
  const handler = createRemoteUnlock({
    env: (name) => {
      assert.notEqual(name, "SUPABASE_SERVICE_ROLE_KEY");
      return env(name);
    },
    fetch: async (url, init) => {
      assert.equal(init.headers.Authorization, "Bearer fixture-user");
      calls++;
      if (calls === 1) return Response.json(user);
      assert.match(String(url), /aim_native_pin_unlock$/);
      const body = JSON.parse(init.body);
      assert.equal(body.p_device_id, input.deviceId);
      assert.ok(!("p_user" in body));
      return Response.json({
        ok: true,
        unlock: {
          token: "a".repeat(64),
          expiresAt: new Date(Date.now() + 60000).toISOString(),
          method: "pin",
        },
      });
    },
  });
  const result = await handler(request());
  assert.equal(result.status, 200);
  assert.equal((await result.json()).unlock.method, "pin");
  assert.equal(calls, 2);
});
test("revoked or unpaired RPC denial never issues a token or falls back to privileged access", async () => {
  for (const code of ["session_revoked", "device_not_paired"]) {
    let calls = 0;
    const handler = createRemoteUnlock({
      env,
      fetch: async () =>
        ++calls === 1
          ? Response.json(user)
          : Response.json({ code: "42501", message: code }, { status: 403 }),
    });
    const result = await handler(request());
    assert.equal(result.status, 403);
    assert.deepEqual(await result.json(), { ok: false, error: code });
  }
});
test("PIN attempt status, migration retirement and lock are preserved", async () => {
  for (const reply of [
    { ok: false, error: "wrong_pin", attempts: 2 },
    { ok: false, error: "legacy_security_retired" },
    { ok: true },
  ]) {
    let calls = 0;
    const handler = createRemoteUnlock({
      env,
      fetch: async () =>
        ++calls === 1 ? Response.json(user) : Response.json(reply),
    });
    const result = await handler(
      request({
        ...input,
        action: reply.ok ? "lock" : "pin-verify",
        ...(reply.ok ? { pin: null, unlockToken: null } : {}),
      }),
    );
    assert.deepEqual(await result.json(), reply);
  }
});
test("invalid upstream responses fail closed without returning backend details", async () => {
  let calls = 0;
  const handler = createRemoteUnlock({
    env,
    fetch: async () =>
      ++calls === 1
        ? Response.json(user)
        : Response.json({ message: "private backend detail" }, { status: 500 }),
  });
  const result = await handler(request());
  assert.equal(result.status, 503);
  assert.deepEqual(await result.json(), {
    ok: false,
    error: "unlock_unavailable",
  });
});

/** Valid JSON plus whitespace: an unbounded .json() would accept this whole reply. */
function streamedJSON(value, totalBytes, status = 200) {
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
            Math.min(4096, totalBytes - consumed),
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
    { status },
  );
  return { response, state: () => ({ consumed, cancelled }) };
}

const unlockReply = () => ({
  ok: true,
  unlock: {
    token: "a".repeat(64),
    expiresAt: new Date(Date.now() + 60000).toISOString(),
    method: "pin",
  },
});

test("oversized unlock Auth stream is cancelled before any PIN RPC or secret access", async () => {
  const stream = streamedJSON(user, 1024 * 1024);
  const calls = [];
  const handler = createRemoteUnlock({
    env: (name) => {
      assert.notEqual(name, "SUPABASE_SERVICE_ROLE_KEY");
      return env(name);
    },
    fetch: async (url) => {
      calls.push(new URL(url).pathname);
      return stream.response;
    },
  });
  const response = await handler(request());
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "unlock_unavailable",
  });
  assert.deepEqual(calls, ["/auth/v1/user"]);
  assert.equal(stream.state().cancelled, true);
  assert.ok(
    stream.state().consumed <= 65536 + 4096,
    "stop reading at the Auth bound",
  );
});

test("oversized successful or rejected PIN RPC streams are cancelled without token return or retry", async () => {
  for (const status of [200, 403]) {
    const stream = streamedJSON(
      status === 200 ? unlockReply() : { message: "device_not_paired" },
      1024 * 1024,
      status,
    );
    const calls = [];
    const handler = createRemoteUnlock({
      env: (name) => {
        assert.notEqual(name, "SUPABASE_SERVICE_ROLE_KEY");
        return env(name);
      },
      fetch: async (url) => {
        calls.push(new URL(url).pathname);
        if (calls.length === 1) return Response.json(user);
        assert.equal(
          calls.length,
          2,
          "a PIN attempt is never retried after response overflow",
        );
        return stream.response;
      },
    });
    const response = await handler(request());
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), {
      ok: false,
      error: "unlock_unavailable",
    });
    assert.deepEqual(calls, [
      "/auth/v1/user",
      "/rest/v1/rpc/aim_native_pin_unlock",
    ]);
    assert.equal(stream.state().cancelled, true);
    assert.ok(
      stream.state().consumed <= 65536 + 4096,
      "stop reading at the RPC bound",
    );
  }
});

test("exactly bounded Auth and PIN responses preserve the valid native unlock contract", async () => {
  const auth = streamedJSON(user, 65536),
    reply = unlockReply(),
    rpc = streamedJSON(reply, 65536);
  let calls = 0;
  const handler = createRemoteUnlock({
    env,
    fetch: async () => (++calls === 1 ? auth.response : rpc.response),
  });
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), reply);
  assert.equal(calls, 2);
  assert.deepEqual(auth.state(), { consumed: 65536, cancelled: false });
  assert.deepEqual(rpc.state(), { consumed: 65536, cancelled: false });
});
