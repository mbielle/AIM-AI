// No external network, private key, user data or installed package is required.
// Node 26 executes erasable TypeScript; production host entrypoints stay Deno.serve.
import assert from "node:assert/strict";
import test from "node:test";
import {
  createEventHandler,
  createWorkerHandler,
  drainQueue,
  providerToken,
  retryAfterSeconds,
  validWorkerAuthorization,
} from "../functions/_shared/push-worker.ts";
const id = (n) => "10000000-0000-0000-0000-" + String(n).padStart(12, "0");
const delivery = (n = 1) => ({
  account: id(1),
  event: id(10 + n),
  installation: id(20 + n),
  lease: id(30 + n),
  expires: Math.floor(Date.now() / 1000) + 1800,
  token: "a".repeat(64),
  topic: "com.aimai.ios.continuityqualification",
  environment: "sandbox",
  conversation: id(40),
  task: id(50),
  category: "task",
});
const options = (overrides = {}) => ({
  rpc: async () => [],
  fetch: async () => {
    throw new Error("unexpected network");
  },
  token: async () => "fixture-APNs-token",
  allowedTopics: ["com.aimai.ios.continuityqualification"],
  allowedEnvironments: ["sandbox"],
  ...overrides,
});
const env =
  (values = {}) =>
  (name) =>
    ({
      AIM_PUSH_ENABLED: "true",
      APNS_ALLOWED_TOPICS: "com.aimai.ios.continuityqualification",
      APNS_ALLOWED_ENVIRONMENTS: "sandbox",
      ...values,
    })[name];

test("worker requires its own strong server credential before any service-role/network access", async () => {
  const secret = "f".repeat(64);
  let calls = 0;
  const handler = createWorkerHandler({
    env: env({ AIM_PUSH_WORKER_SECRET: secret }),
    fetch: async () => {
      calls++;
      throw new Error("network");
    },
  });
  for (const bearer of [
    null,
    "Bearer client-user-jwt",
    "Bearer " + "e".repeat(64),
    "Bearer " + secret + "x",
  ]) {
    const headers = bearer ? { Authorization: bearer } : {};
    assert.equal(
      (
        await handler(
          new Request("https://fixture.test", { method: "POST", headers }),
        )
      ).status,
      401,
    );
  }
  assert.equal(calls, 0);
  assert.equal(
    await validWorkerAuthorization("Bearer " + secret, secret),
    true,
  );
  assert.equal(await validWorkerAuthorization("Bearer short", "short"), false);
  assert.equal(
    (
      await handler(
        new Request("https://fixture.test", {
          method: "GET",
          headers: { Authorization: "Bearer " + secret },
        }),
      )
    ).status,
    405,
  );
  assert.equal(
    (
      await handler(
        new Request("https://fixture.test", {
          method: "POST",
          headers: { Authorization: "Bearer " + secret },
        }),
      )
    ).status,
    503,
  );
  assert.equal(calls, 0, "missing configuration never claims a delivery");
});

test("configured server signs a verifiable ES256 provider token using only a disposable fixture key", async () => {
  const key = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const privateBytes = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", key.privateKey),
  );
  const pem =
    "-----BEGIN PRIVATE KEY-----\n" +
    Buffer.from(privateBytes).toString("base64") +
    "\n-----END PRIVATE KEY-----";
  const secret = "c".repeat(64),
    job = delivery();
  let apnsCalls = 0;
  const handler = createWorkerHandler({
    env: env({
      AIM_PUSH_WORKER_SECRET: secret,
      SUPABASE_URL: "https://fixture.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "fixture-server-role",
      APNS_TEAM_ID: "FIXTURETEAM",
      APNS_KEY_ID: "FIXTUREKEY",
      APNS_PRIVATE_KEY: pem,
    }),
    fetch: async (url, init) => {
      if (url.includes("/rest/v1/rpc/")) {
        assert.equal(init.headers.Authorization, "Bearer fixture-server-role");
        assert.equal(init.headers.apikey, "fixture-server-role");
        if (url.endsWith("/aim_claim_push")) return Response.json([job]);
        if (url.endsWith("/aim_validate_push")) return Response.json(true);
        if (url.endsWith("/aim_finish_push")) return Response.json(null);
        throw new Error("unexpected RPC");
      }
      assert.ok(url.startsWith("https://api.sandbox.push.apple.com/"));
      apnsCalls++;
      const [header, payload, signature] = init.headers.authorization
        .slice(7)
        .split(".");
      assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), {
        alg: "ES256",
        kid: "FIXTUREKEY",
      });
      const claims = JSON.parse(Buffer.from(payload, "base64url"));
      assert.equal(claims.iss, "FIXTURETEAM");
      assert.ok(Math.abs(claims.iat - Math.floor(Date.now() / 1000)) < 5);
      assert.equal(
        await crypto.subtle.verify(
          { name: "ECDSA", hash: "SHA-256" },
          key.publicKey,
          Buffer.from(signature, "base64url"),
          new TextEncoder().encode(header + "." + payload),
        ),
        true,
      );
      return new Response(null, { status: 200 });
    },
  });
  const response = await handler(
    new Request("https://fixture.test", {
      method: "POST",
      headers: { Authorization: "Bearer " + secret },
    }),
  );
  assert.equal(response.status, 200);
  assert.equal((await response.json()).sent, 1);
  assert.equal(apnsCalls, 1);
});

test("APNs accepts equivalent full PEM and bare base64 PKCS8 without changing the signing key", async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const der = Buffer.from(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  ).toString("base64");
  for (const [environment, prefix] of [
    ["sandbox", "APNS"],
    ["production", "APNS_PRODUCTION"],
  ]) {
    for (const value of [
      der,
      "-----BEGIN PRIVATE KEY-----\n" + der + "\n-----END PRIVATE KEY-----",
    ]) {
      const jwt = await providerToken(
        env({
          [prefix + "_TEAM_ID"]: "FIXTURETEAM",
          [prefix + "_KEY_ID"]: "FIXTUREKEY",
          [prefix + "_PRIVATE_KEY"]: value,
        }),
        environment,
      );
      const [header, payload, signature] = jwt.split(".");
      assert.equal(
        await crypto.subtle.verify(
          { name: "ECDSA", hash: "SHA-256" },
          pair.publicKey,
          Buffer.from(signature, "base64url"),
          new TextEncoder().encode(header + "." + payload),
        ),
        true,
      );
    }
  }
});

test("event request is bounded and preserves the explicit launch account", async () => {
  const requests = [];
  const handler = createEventHandler({
    env: env({
      SUPABASE_URL: "https://project.supabase.co",
      SUPABASE_ANON_KEY: "fixture-anon",
    }),
    fetch: async (url, init) => {
      requests.push({
        url,
        headers: init.headers,
        body: JSON.parse(init.body),
      });
      return Response.json(null);
    },
  });
  const body = {
    account: id(1),
    event: id(2),
    task: id(3),
    conversation: id(4),
    category: "response",
  };
  assert.equal(
    (
      await handler(
        new Request("https://fixture.test", {
          method: "POST",
          body: JSON.stringify(body),
        }),
      )
    ).status,
    401,
  );
  for (const payload of ["null", "[]", "{}", "x".repeat(8193)]) {
    assert.equal(
      (
        await handler(
          new Request("https://fixture.test", {
            method: "POST",
            headers: { Authorization: "Bearer fixture-user" },
            body: payload,
          }),
        )
      ).status,
      400,
    );
  }
  const response = await handler(
    new Request("https://fixture.test", {
      method: "POST",
      headers: { Authorization: "Bearer fixture-user" },
      body: JSON.stringify(body),
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { queued: true });
  assert.equal(
    requests.length,
    1,
    "missing Apple configuration leaves the durable event for scheduler",
  );
  assert.deepEqual(requests[0].body, {
    p_account_id: id(1),
    p_event: id(2),
    p_task: id(3),
    p_conversation: id(4),
    p_category: "response",
  });
  assert.equal(requests[0].headers.Authorization, "Bearer fixture-user");
  assert.equal(requests[0].headers.apikey, "fixture-anon");
});

test("revoked/user RPC rejection cannot reach APNs or service-role queue", async () => {
  let calls = 0;
  const handler = createEventHandler({
    env: env({
      SUPABASE_URL: "https://project.supabase.co",
      SUPABASE_ANON_KEY: "anon",
      SUPABASE_SERVICE_ROLE_KEY: "server",
    }),
    fetch: async () => {
      calls++;
      return new Response(null, { status: 403 });
    },
  });
  const response = await handler(
    new Request("https://fixture.test", {
      method: "POST",
      headers: { Authorization: "Bearer stale-jwt" },
      body: JSON.stringify({
        account: id(1),
        event: id(2),
        task: id(3),
        conversation: id(4),
        category: "task",
      }),
    }),
  );
  assert.equal(response.status, 403);
  assert.equal(calls, 1);
});

test("unconfigured key fails before claiming rows or burning attempts", async () => {
  let claimed = false;
  await assert.rejects(
    drainQueue(
      options({
        token: async () => {
          throw new Error("not configured");
        },
        rpc: async () => {
          claimed = true;
        },
      }),
    ),
    /not configured/,
  );
  assert.equal(claimed, false);
});

test("foreground/revoked/disabled deliveries never send a system notification", async () => {
  let sent = false;
  const rpc = async (name) =>
    name === "aim_claim_push" ? [delivery()] : false;
  const result = await drainQueue(
    options({
      rpc,
      fetch: async () => {
        sent = true;
        return new Response(null, { status: 200 });
      },
    }),
  );
  assert.equal(sent, false);
  assert.equal(result.suppressed, 1);
});

test("generic payload, lease fencing and bounded concurrency apply to each root event", async () => {
  const jobs = Array.from({ length: 8 }, (_, i) => delivery(i + 1)),
    finished = [],
    checked = new Set();
  let concurrent = 0,
    maxConcurrent = 0;
  const rpc = async (name, args) => {
    if (name === "aim_claim_push") return jobs;
    if (name === "aim_validate_push") {
      assert.equal(
        args.p_lease,
        jobs.find((d) => d.event === args.p_event).lease,
      );
      checked.add(args.p_event);
      return true;
    }
    if (name === "aim_finish_push") {
      finished.push(args);
      return null;
    }
    throw new Error("unexpected RPC");
  };
  const result = await drainQueue(
    options({
      rpc,
      fetch: async (url, init) => {
        concurrent++;
        maxConcurrent = Math.max(maxConcurrent, concurrent);
        assert.ok(
          url.startsWith("https://api.sandbox.push.apple.com/3/device/"),
        );
        const body = JSON.parse(init.body),
          job = jobs.find((d) => d.event === body.aim_event);
        assert.ok(checked.has(job.event));
        assert.deepEqual(Object.keys(body).sort(), [
          "aim_account",
          "aim_category",
          "aim_conversation",
          "aim_event",
          "aps",
        ]);
        assert.deepEqual(body.aps, {
          alert: { title: "AIM", body: "Your task has finished." },
          sound: "default",
        });
        assert.equal(body.aim_category, job.category);
        assert.equal(init.headers["apns-collapse-id"], job.task);
        assert.equal(init.headers["apns-id"], job.event);
        assert.equal(init.headers["apns-expiration"], String(job.expires));
        assert.equal(init.redirect, "error");
        await new Promise((resolve) => setTimeout(resolve, 5));
        concurrent--;
        return new Response(null, { status: 200 });
      },
    }),
  );
  assert.ok(maxConcurrent <= 4);
  assert.equal(maxConcurrent, 4);
  assert.equal(result.sent, 8);
  assert.equal(finished.length, 8);
  assert.ok(
    finished.every(
      (f) => f.p_status === 200 && f.p_retry_after === null && f.p_lease,
    ),
  );
});

test("transient APNs/network failures carry retry timing and permanent failures stay distinct", async () => {
  for (const status of [429, 503, 400]) {
    let completion;
    const rpc = async (name, args) =>
      name === "aim_claim_push"
        ? [delivery()]
        : name === "aim_validate_push"
          ? true
          : ((completion = args), null);
    const result = await drainQueue(
      options({
        rpc,
        fetch: async () =>
          new Response(null, { status, headers: { "Retry-After": "120" } }),
      }),
    );
    assert.equal(completion.p_status, status);
    assert.equal(completion.p_retry_after, 120);
    assert.equal(status === 400 ? result.failed : result.deferred, 1);
  }
  let completion;
  const rpc = async (name, args) =>
    name === "aim_claim_push"
      ? [delivery()]
      : name === "aim_validate_push"
        ? true
        : ((completion = args), null);
  await drainQueue(
    options({
      rpc,
      fetch: async () => {
        throw new Error("network timeout");
      },
    }),
  );
  assert.equal(completion.p_status, 503);
  assert.equal(completion.p_retry_after, null);
});

test("validation/finish outage leaves lease retryable and unapproved production is never sent", async () => {
  let apns = 0;
  const failedValidation = async (name) => {
    if (name === "aim_claim_push") return [delivery()];
    throw new Error("database unavailable");
  };
  assert.equal(
    (await drainQueue(options({ rpc: failedValidation }))).deferred,
    1,
  );
  const rpc = async (name) =>
    name === "aim_claim_push"
      ? [{ ...delivery(), environment: "production" }]
      : name === "aim_validate_push"
        ? true
        : null;
  assert.equal(
    (
      await drainQueue(
        options({
          rpc,
          fetch: async () => {
            apns++;
            throw new Error("must not call");
          },
        }),
      )
    ).failed,
    1,
  );
  assert.equal(apns, 0);
});

test("malformed batch or injectable token is rejected before any provider request", async () => {
  for (const jobs of [
    [{ ...delivery(), token: "../../private" }],
    Array.from({ length: 9 }, () => delivery()),
  ]) {
    await assert.rejects(
      drainQueue(options({ rpc: async () => jobs })),
      /invalid_delivery_batch/,
    );
  }
  assert.equal(retryAfterSeconds("120"), 120);
  assert.equal(retryAfterSeconds("99999"), 3600);
  const now = Date.parse("2026-10-06T20:00:00Z");
  assert.equal(retryAfterSeconds("Tue, 06 Oct 2026 20:02:00 GMT", now), 120);
  assert.equal(retryAfterSeconds("not a date"), null);
  assert.equal(retryAfterSeconds("-1"), null);
});

// Configuration is explicit: deployed functions do not start Apple delivery.
test("disabled delivery never claims rows even with server credentials", async () => {
  let calls = 0;
  const secret = "f".repeat(64);
  const handler = createWorkerHandler({
    env: env({
      AIM_PUSH_ENABLED: "false",
      AIM_PUSH_WORKER_SECRET: secret,
      SUPABASE_SERVICE_ROLE_KEY: "fixture-server",
    }),
    fetch: async () => {
      calls++;
      throw new Error("unexpected network");
    },
  });
  assert.equal(
    (
      await handler(
        new Request("https://fixture.test", {
          method: "POST",
          headers: { Authorization: "Bearer " + secret },
        }),
      )
    ).status,
    503,
  );
  assert.equal(calls, 0);
});

async function fixtureSigningKey() {
  const key = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pem =
    "-----BEGIN PRIVATE KEY-----\n" +
    Buffer.from(
      await crypto.subtle.exportKey("pkcs8", key.privateKey),
    ).toString("base64") +
    "\n-----END PRIVATE KEY-----";
  return { key, pem };
}
async function signedBy(jwt, key) {
  const [header, payload, signature] = jwt.split(".");
  return crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key.publicKey,
    Buffer.from(signature, "base64url"),
    new TextEncoder().encode(header + "." + payload),
  );
}

test("missing production credentials never fall back to legacy or claim mixed-environment queue", async () => {
  const fixture = await fixtureSigningKey(),
    secret = "d".repeat(64);
  let calls = 0;
  const values = {
    AIM_PUSH_WORKER_SECRET: secret,
    SUPABASE_URL: "https://fixture.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "fixture-role",
    APNS_ALLOWED_ENVIRONMENTS: "sandbox,production",
    APNS_TEAM_ID: "FIXTURETEAM",
    APNS_KEY_ID: "FIXTUREKEY",
    APNS_PRIVATE_KEY: fixture.pem,
  };
  const handler = createWorkerHandler({
    env: env(values),
    fetch: async () => {
      calls++;
      throw new Error("must not claim");
    },
  });
  assert.equal(
    (
      await handler(
        new Request("https://fixture.test", {
          method: "POST",
          headers: { Authorization: "Bearer " + secret },
        }),
      )
    ).status,
    503,
  );
  assert.equal(calls, 0);
  await assert.rejects(
    providerToken(env(values), "production"),
    /apns_not_configured/,
  );
  for (const partial of [
    { APNS_SANDBOX_KEY_ID: "EXPLICIT" },
    { APNS_SANDBOX_TEAM_ID: "" },
    { APNS_SANDBOX_PRIVATE_KEY: fixture.pem },
  ]) {
    await assert.rejects(
      providerToken(env({ ...values, ...partial }), "sandbox"),
      /apns_not_configured/,
    );
  }
  assert.ok(
    await providerToken(env(values), "sandbox"),
    "legacy is used only when no sandbox-specific field exists",
  );
});

test("mixed batch routes each environment to its exact host and separate signing identity", async () => {
  const sandbox = await fixtureSigningKey(),
    production = await fixtureSigningKey(),
    secret = "a".repeat(64);
  const jobs = [
    delivery(201),
    { ...delivery(202), environment: "production", topic: "com.aimai.ios" },
  ];
  const seen = [];
  const values = {
    AIM_PUSH_WORKER_SECRET: secret,
    SUPABASE_URL: "https://fixture.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "fixture-role",
    APNS_ALLOWED_ENVIRONMENTS: "sandbox,production",
    APNS_ALLOWED_TOPICS: "com.aimai.ios.continuityqualification,com.aimai.ios",
    APNS_SANDBOX_TEAM_ID: "SANDBOXTEAM",
    APNS_SANDBOX_KEY_ID: "SANDBOXKEY",
    APNS_SANDBOX_PRIVATE_KEY: sandbox.pem,
    APNS_PRODUCTION_TEAM_ID: "PRODTEAM",
    APNS_PRODUCTION_KEY_ID: "PRODKEY",
    APNS_PRODUCTION_PRIVATE_KEY: production.pem,
    APNS_TEAM_ID: "LEGACY",
    APNS_KEY_ID: "LEGACY",
    APNS_PRIVATE_KEY: "invalid-legacy-key",
  };
  const handler = createWorkerHandler({
    env: env(values),
    fetch: async (url, init) => {
      if (url.includes("/rest/v1/rpc/"))
        return Response.json(
          url.endsWith("aim_claim_push")
            ? jobs
            : url.endsWith("aim_validate_push")
              ? true
              : null,
        );
      const jwt = init.headers.authorization.slice(7),
        isProduction = new URL(url).hostname === "api.push.apple.com";
      const [header, payload] = jwt.split(".");
      assert.equal(
        JSON.parse(Buffer.from(header, "base64url")).kid,
        isProduction ? "PRODKEY" : "SANDBOXKEY",
      );
      assert.equal(
        JSON.parse(Buffer.from(payload, "base64url")).iss,
        isProduction ? "PRODTEAM" : "SANDBOXTEAM",
      );
      assert.equal(
        init.headers["apns-topic"],
        isProduction
          ? "com.aimai.ios"
          : "com.aimai.ios.continuityqualification",
      );
      assert.equal(
        await signedBy(jwt, (isProduction ? production : sandbox).key),
        true,
      );
      seen.push(new URL(url).hostname);
      return new Response(null, { status: 200 });
    },
  });
  const response = await handler(
    new Request("https://fixture.test", {
      method: "POST",
      headers: { Authorization: "Bearer " + secret },
    }),
  );
  assert.equal(response.status, 200);
  assert.equal((await response.json()).sent, 2);
  assert.deepEqual(
    seen.sort(),
    ["api.push.apple.com", "api.sandbox.push.apple.com"].sort(),
  );
});

test("JWT cache is isolated by environment and rotated signing-key fingerprint with unchanged key ID", async () => {
  const first = await fixtureSigningKey(),
    second = await fixtureSigningKey();
  const values = {
    APNS_SANDBOX_TEAM_ID: "SAMETEAM",
    APNS_SANDBOX_KEY_ID: "SAMEKEY",
    APNS_SANDBOX_PRIVATE_KEY: first.pem,
    APNS_PRODUCTION_TEAM_ID: "SAMETEAM",
    APNS_PRODUCTION_KEY_ID: "SAMEKEY",
    APNS_PRODUCTION_PRIVATE_KEY: second.pem,
  };
  const sandbox = await providerToken(env(values), "sandbox");
  const production = await providerToken(env(values), "production");
  assert.notEqual(sandbox, production);
  assert.equal(await signedBy(sandbox, first.key), true);
  assert.equal(await signedBy(production, second.key), true);
  assert.equal(
    await providerToken(env(values), "sandbox"),
    sandbox,
    "production cache does not displace sandbox",
  );
  const rotated = await providerToken(
    env({ ...values, APNS_SANDBOX_PRIVATE_KEY: second.pem }),
    "sandbox",
  );
  assert.notEqual(rotated, sandbox);
  assert.equal(await signedBy(rotated, second.key), true);
  assert.equal(await signedBy(rotated, first.key), false);
  assert.equal(
    await providerToken(env(values), "production"),
    production,
    "sandbox rotation does not displace production",
  );
  await assert.rejects(
    providerToken(env({ ...values, APNS_SANDBOX_PRIVATE_KEY: "" }), "sandbox"),
    /apns_not_configured/,
  );
});
