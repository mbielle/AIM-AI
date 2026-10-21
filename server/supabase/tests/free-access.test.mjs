import { boundedBody } from "../functions/_shared/request-body.ts";
import test from "node:test";
import assert from "node:assert/strict";
import { retiredPurchases } from "../../compatibility/retired-purchases.ts";
import { createAccountMaintenance } from "../functions/_shared/account-maintenance.ts";
import { createMonitorHandler } from "../functions/_shared/release-monitor.ts";
const user = {
  id: "10000000-0000-0000-0000-000000000001",
  email: "owner@example.invalid",
};
const request = (
  body = {},
  headers = { Authorization: "Bearer fixture-user" },
) =>
  new Request("https://fixture.invalid", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
test("retired purchase returns update required without initiating payment", async () => {
  const result = retiredPurchases(request());
  assert.equal(result.status, 410);
  assert.equal((await result.json()).error, "update_required");
});
test("account maintenance authenticates and checks live session before privileged calls", async () => {
  for (const operation of ["delete", "export"]) {
    let calls = 0;
    const h = createAccountMaintenance(
      {
        env: (n) =>
          ({
            SUPABASE_URL: "https://fixture.invalid",
            SUPABASE_ANON_KEY: "fixture-public",
          })[n],
        fetch: async () => {
          calls++;
          return new Response(null, { status: 401 });
        },
      },
      operation,
    );
    assert.equal((await h(request({}, {}))).status, 401);
    assert.equal(calls, 0);
    assert.equal((await h(request())).status, 401);
    assert.equal(calls, 1);
  }
});
test("revoked session cannot export or delete and never reads service key", async () => {
  let keys = 0,
    calls = 0;
  const h = createAccountMaintenance(
    {
      env: (n) => {
        if (n === "SUPABASE_SERVICE_ROLE_KEY") keys++;
        return {
          SUPABASE_URL: "https://fixture.invalid",
          SUPABASE_ANON_KEY: "fixture-public",
        }[n];
      },
      fetch: async () =>
        ++calls === 1
          ? Response.json(user)
          : new Response(null, { status: 403 }),
    },
    "delete",
  );
  assert.equal(
    (await h(request({ confirmEmail: user.email, confirmText: "SUPPRIMER" })))
      .status,
    401,
  );
  assert.equal(keys, 0);
});
test("deletion confirmation must match authenticated account, no service key read", async () => {
  let keys = 0,
    calls = 0;
  const h = createAccountMaintenance(
    {
      env: (n) => {
        if (n === "SUPABASE_SERVICE_ROLE_KEY") keys++;
        return {
          SUPABASE_URL: "https://fixture.invalid",
          SUPABASE_ANON_KEY: "fixture-public",
        }[n];
      },
      fetch: async () =>
        ++calls === 1 ? Response.json(user) : Response.json(true),
    },
    "delete",
  );
  assert.equal(
    (
      await h(
        request({
          confirmEmail: "other@example.invalid",
          confirmText: "SUPPRIMER",
        }),
      )
    ).status,
    400,
  );
  assert.equal(keys, 0);
});
test("monitor refuses weak or missing worker secret before accessing infrastructure", async () => {
  let calls = 0;
  const h = createMonitorHandler({
    env: () => undefined,
    fetch: async () => {
      calls++;
      throw Error("unexpected");
    },
  });
  assert.equal((await h(request())).status, 401);
  assert.equal(calls, 0);
});

test("export uses caller JWT for every paginated table and excludes credentials", async () => {
  const requests = [];
  const handler = createAccountMaintenance(
    {
      env: (n) =>
        ({
          SUPABASE_URL: "https://fixture.invalid",
          SUPABASE_ANON_KEY: "fixture-public",
        })[n],
      fetch: async (url, init) => {
        requests.push({ url: String(url), headers: init.headers });
        if (String(url).endsWith("/auth/v1/user")) return Response.json(user);
        if (String(url).includes("aim_maintenance_session"))
          return Response.json(true);
        return Response.json([]);
      },
    },
    "export",
  );
  const response = await handler(request());
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.accountID, user.id);
  assert.equal(body.includesKeychainCredentials, false);
  assert.ok(!("user_connectors" in body.tables));
  assert.ok(
    requests.every((r) => r.headers.Authorization === "Bearer fixture-user"),
  );
});
test("deletion rejects forged storage paths before privileged deletion", async () => {
  let removed = 0;
  const h = createAccountMaintenance(
    {
      env: (n) =>
        ({
          SUPABASE_URL: "https://fixture.invalid",
          SUPABASE_ANON_KEY: "fixture-public",
          SUPABASE_SERVICE_ROLE_KEY: "fixture-role",
        })[n],
      fetch: async (url, init) => {
        const p = String(url);
        if (init.method === "DELETE") removed++;
        if (p.endsWith("/auth/v1/user")) return Response.json(user);
        if (p.includes("aim_maintenance_session"))
          return Response.json(true);
        return Response.json([
          { bucket: "fixture", name: "another-user/private" },
        ]);
      },
    },
    "delete",
  );
  assert.equal(
    (await h(request({ confirmEmail: user.email, confirmText: "SUPPRIMER" })))
      .status,
    503,
  );
  assert.equal(removed, 0);
});

test("request byte limit rejects a chunked body even without Content-Length", async () => {
  const body = new ReadableStream({
    start(c) {
      c.enqueue(new Uint8Array(2000));
      c.enqueue(new Uint8Array(1000));
      c.close();
    },
  });
  await assert.rejects(
    () =>
      boundedBody(
        new Request("https://fixture.invalid", {
          method: "POST",
          body,
          duplex: "half",
        }),
        2048,
      ),
    /request_too_large/,
  );
});

function oversizedStream(maximumChunks = 40) {
  let read = 0,
    cancelled = false;
  const chunk = new Uint8Array(1024 * 1024).fill(120);
  const response = new Response(
    new ReadableStream({
      pull(controller) {
        if (read++ < maximumChunks) controller.enqueue(chunk);
        else controller.close();
      },
      cancel() {
        cancelled = true;
      },
    }),
  );
  return { response, state: () => ({ read, cancelled }) };
}

test("export bounds each response by the remaining byte budget and never returns a truncated export", async () => {
  const stream = oversizedStream();
  let calls = 0;
  const handler = createAccountMaintenance(
    {
      env: (name) => {
        assert.notEqual(name, "SUPABASE_SERVICE_ROLE_KEY");
        return {
          SUPABASE_URL: "https://fixture.invalid",
          SUPABASE_ANON_KEY: "fixture-public",
        }[name];
      },
      fetch: async () => {
        calls++;
        if (calls === 1) return Response.json(user);
        if (calls === 2) return Response.json(true);
        if (calls === 3)
          return Response.json([{ payload: "x".repeat(24 * 1024 * 1024) }]);
        return stream.response;
      },
    },
    "export",
  );
  const response = await handler(request());
  assert.equal(response.status, 413);
  assert.deepEqual(await response.json(), { error: "export_too_large" });
  assert.equal(calls, 4);
  assert.equal(stream.state().cancelled, true);
  assert.ok(
    stream.state().read <= 2,
    "remaining budget stops the next page near 1 MiB",
  );
});

test("oversized Auth response is cancelled before session calls or secret access", async () => {
  const stream = oversizedStream();
  let calls = 0;
  const handler = createAccountMaintenance(
    {
      env: (name) => {
        assert.notEqual(name, "SUPABASE_SERVICE_ROLE_KEY");
        return {
          SUPABASE_URL: "https://fixture.invalid",
          SUPABASE_ANON_KEY: "fixture-public",
        }[name];
      },
      fetch: async () => {
        calls++;
        return stream.response;
      },
    },
    "export",
  );
  assert.equal((await handler(request())).status, 503);
  assert.equal(calls, 1);
  assert.equal(stream.state().cancelled, true);
});

test("oversized storage-path response is cancelled before privileged deletion or secret access", async () => {
  const stream = oversizedStream();
  let calls = 0;
  const handler = createAccountMaintenance(
    {
      env: (name) => {
        assert.notEqual(name, "SUPABASE_SERVICE_ROLE_KEY");
        return {
          SUPABASE_URL: "https://fixture.invalid",
          SUPABASE_ANON_KEY: "fixture-public",
        }[name];
      },
      fetch: async () => {
        calls++;
        if (calls === 1) return Response.json(user);
        if (calls === 2) return Response.json(true);
        return stream.response;
      },
    },
    "delete",
  );
  const response = await handler(
    request({ confirmEmail: user.email, confirmText: "SUPPRIMER" }),
  );
  assert.equal(response.status, 413);
  assert.deepEqual(await response.json(), { error: "deletion_too_large" });
  assert.equal(calls, 3);
  assert.equal(stream.state().cancelled, true);
});

 test("HTTP 200 with a false or malformed live-session value cannot reach privileged maintenance", async () => {
  for (const value of [false, null, [], "fixture-user"]) {
    let calls = 0, keys = 0;
    const h = createAccountMaintenance({
      env: name => { if (name === "SUPABASE_SERVICE_ROLE_KEY") keys++; return { SUPABASE_URL: "https://fixture.invalid", SUPABASE_ANON_KEY: "fixture" }[name]; },
      fetch: async () => ++calls === 1 ? Response.json(user) : Response.json(value),
    }, "delete");
    assert.equal((await h(request({ confirmEmail: user.email, confirmText: "SUPPRIMER" }))).status, 401);
    assert.equal(calls, 2); assert.equal(keys, 0);
  }
});
