// Runtime-independent orchestration: tested with injected network/clock and no Apple key.
// No conversation text, tokens or credential values are logged or returned to a caller.
import { backendOrigin } from "./backend-origin.ts";
import { boundedBody } from "./request-body.ts";
export type Environment = (name: string) => string | undefined;
export type Network = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;
export type RPC = (
  name: string,
  args?: Record<string, unknown>,
) => Promise<unknown>;
export interface Runtime {
  env: Environment;
  fetch: Network;
}
export interface Delivery {
  account: string;
  event: string;
  installation: string;
  lease: string;
  expires: number;
  token: string;
  topic: string;
  environment: "sandbox" | "production";
  conversation: string;
  task: string;
  category: "response" | "task" | "question" | "approval" | "failure";
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const categories = ["response", "task", "question", "approval", "failure"];
const copy: Record<Delivery["category"], string> = {
  response: "Your response is ready.",
  task: "Your task has finished.",
  question: "AIM has a question for you.",
  approval: "An action needs your approval.",
  failure: "A task needs your attention.",
};
const b64 = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
type PushEnvironment = Delivery["environment"];
const cachedTokens = new Map<
  PushEnvironment,
  {
    value: string;
    issued: number;
    keyID: string;
    team: string;
    fingerprint: string;
  }
>();

function credentials(env: Environment, environment: PushEnvironment) {
  let prefix = "APNS_PRODUCTION";
  if (environment === "sandbox") {
    const explicit = ["TEAM_ID", "KEY_ID", "PRIVATE_KEY"].some(
      (field) => env(`APNS_SANDBOX_${field}`) !== undefined,
    );
    prefix = explicit ? "APNS_SANDBOX" : "APNS";
  }
  const team = env(`${prefix}_TEAM_ID`),
    keyID = env(`${prefix}_KEY_ID`),
    pem = env(`${prefix}_PRIVATE_KEY`);
  if (!team?.trim() || !keyID?.trim() || !pem?.trim())
    throw new Error("apns_not_configured");
  return { team, keyID, pem };
}

export async function providerToken(
  env: Environment,
  environment: PushEnvironment,
): Promise<string> {
  if (!["sandbox", "production"].includes(environment))
    throw new Error("invalid_apns_environment");
  const now = Math.floor(Date.now() / 1000);
  const { team, keyID, pem } = credentials(env, environment);
  const der = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")),
    (c) => c.charCodeAt(0),
  );
  // Include the actual signing key in cache identity: rotating PEM with the same key ID
  // must not keep sending JWTs signed by the previous key. Never expose this fingerprint.
  const fingerprint = b64(
    new Uint8Array(await crypto.subtle.digest("SHA-256", der)),
  );
  const cached = cachedTokens.get(environment);
  if (
    cached &&
    now >= cached.issued &&
    now - cached.issued < 3000 &&
    cached.team === team &&
    cached.keyID === keyID &&
    cached.fingerprint === fingerprint
  )
    return cached.value;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const text = new TextEncoder();
  const data =
    b64(text.encode(JSON.stringify({ alg: "ES256", kid: keyID }))) +
    "." +
    b64(text.encode(JSON.stringify({ iss: team, iat: now })));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    text.encode(data),
  );
  const value = data + "." + b64(new Uint8Array(signature));
  cachedTokens.set(environment, {
    value,
    issued: now,
    keyID,
    team,
    fingerprint,
  });
  return value;
}

export function createRPC(runtime: Runtime, key: string, bearer: string): RPC {
  const project = backendOrigin(runtime.env).origin;
  if (!key || !bearer) throw new Error("server_not_configured");
  return async (name, args = {}) => {
    if (!/^aim_[a-z_]+$/.test(name)) throw new Error("invalid_rpc");
    const response = await runtime.fetch(
      `${project.replace(/\/$/, "")}/rest/v1/rpc/${name}`,
      {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(5000),
        headers: {
          apikey: key,
          Authorization: bearer,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(args),
      },
    );
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error("rpc_rejected");
    }
    const raw = await boundedBody(response, 2 * 1024 * 1024);
    return raw ? JSON.parse(raw) : null;
  };
}

// Hash before comparison, then compare all digest bytes: no prefix/length timing oracle.
export async function validWorkerAuthorization(
  header: string | null,
  secret: string | undefined,
): Promise<boolean> {
  if (
    !secret ||
    !/^[a-f0-9]{64}$/i.test(secret) ||
    !header?.startsWith("Bearer ") ||
    header.length > 128
  )
    return false;
  const encode = new TextEncoder();
  const [actual, expected] = await Promise.all(
    [header.slice(7), secret].map((value) =>
      crypto.subtle.digest("SHA-256", encode.encode(value)),
    ),
  );
  const lhs = new Uint8Array(actual),
    rhs = new Uint8Array(expected);
  let mismatch = 0;
  for (let i = 0; i < lhs.length; i++) mismatch |= lhs[i] ^ rhs[i];
  return mismatch === 0;
}

export function retryAfterSeconds(
  value: string | null,
  now = Date.now(),
): number | null {
  if (value === null) return null;
  const seconds = /^\d+$/.test(value)
    ? Number(value)
    : Math.ceil((Date.parse(value) - now) / 1000);
  return Number.isFinite(seconds) && seconds > 0
    ? Math.min(3600, seconds)
    : null;
}

function validDelivery(value: unknown): value is Delivery {
  if (!value || typeof value !== "object") return false;
  const d = value as Delivery;
  return (
    [d.account, d.event, d.installation, d.lease, d.conversation, d.task].every(
      (v) => typeof v === "string" && uuid.test(v),
    ) &&
    Number.isSafeInteger(d.expires) &&
    d.expires > 0 &&
    typeof d.token === "string" &&
    /^[0-9a-f]{64,200}$/.test(d.token) &&
    typeof d.topic === "string" &&
    /^[A-Za-z0-9][A-Za-z0-9.-]{2,200}$/.test(d.topic) &&
    ["sandbox", "production"].includes(d.environment) &&
    categories.includes(d.category)
  );
}

export async function drainQueue(options: {
  rpc: RPC;
  fetch: Network;
  token: (environment: PushEnvironment) => Promise<string>;
  allowedTopics: string[];
  allowedEnvironments: string[];
}): Promise<{
  claimed: number;
  sent: number;
  deferred: number;
  suppressed: number;
  failed: number;
}> {
  // Validate the key before claiming: unavailable configuration must not burn retry attempts.
  if (
    !options.allowedTopics.length ||
    options.allowedTopics.some(
      (topic) => !/^[A-Za-z0-9][A-Za-z0-9.-]{2,200}$/.test(topic),
    )
  )
    throw new Error("apns_topics_not_configured");
  const environments = [...new Set(options.allowedEnvironments)];
  if (
    !environments.length ||
    environments.some((value) => !["sandbox", "production"].includes(value))
  )
    throw new Error("invalid_apns_environment");
  const tokens = new Map<string, string>();
  for (const environment of environments)
    tokens.set(
      environment,
      await options.token(environment as PushEnvironment),
    );
  const raw = await options.rpc("aim_claim_push");
  if (!Array.isArray(raw) || raw.length > 8 || !raw.every(validDelivery))
    throw new Error("invalid_delivery_batch");
  const deliveries: Delivery[] = raw;
  const result = {
    claimed: deliveries.length,
    sent: 0,
    deferred: 0,
    suppressed: 0,
    failed: 0,
  };
  let next = 0;
  const consumer = async () => {
    while (next < deliveries.length) {
      const d = deliveries[next++];
      let live: unknown;
      try {
        live = await options.rpc("aim_validate_push", {
          p_event: d.event,
          p_installation: d.installation,
          p_lease: d.lease,
        });
      } catch {
        result.deferred++;
        continue;
      } // Lease expiry makes validation outages retryable.
      if (live !== true) {
        result.suppressed++;
        continue;
      }
      let status = 400,
        retryAfter: number | null = null;
      if (
        options.allowedTopics.includes(d.topic) &&
        options.allowedEnvironments.includes(d.environment)
      ) {
        const host =
          d.environment === "production"
            ? "api.push.apple.com"
            : "api.sandbox.push.apple.com";
        status = 503;
        try {
          const response = await options.fetch(
            `https://${host}/3/device/${d.token}`,
            {
              method: "POST",
              redirect: "error",
              signal: AbortSignal.timeout(10000),
              headers: {
                authorization: `bearer ${tokens.get(d.environment)}`,
                "apns-topic": d.topic,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-expiration": String(d.expires),
                "apns-id": d.event,
                "apns-collapse-id": d.task,
              },
              body: JSON.stringify({
                aps: {
                  alert: { title: "AIM", body: copy[d.category] },
                  sound: "default",
                },
                aim_account: d.account,
                aim_event: d.event,
                aim_conversation: d.conversation,
                aim_category: d.category,
              }),
            },
          );
          status = response.status;
          retryAfter = retryAfterSeconds(response.headers.get("Retry-After"));
          await response.body?.cancel();
        } catch {
          /* A timeout is an uncertain delivery; never log credentials or message bodies. */
        }
      }
      try {
        await options.rpc("aim_finish_push", {
          p_event: d.event,
          p_installation: d.installation,
          p_lease: d.lease,
          p_status: status,
          p_retry_after: retryAfter,
        });
        if (status === 200) result.sent++;
        else if (status === 429 || status >= 500) result.deferred++;
        else result.failed++;
      } catch {
        result.deferred++;
      } // Do not acknowledge a DB failure: lease will be reclaimed.
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(4, deliveries.length) }, consumer),
  );
  return result;
}

async function recordPushMonitorError(
  runtime: Runtime,
  code: "delivery_failed" | "request_failed",
) {
  // Optional server telemetry: no event/account/token/error text, never changes delivery state.
  if (runtime.env("AIM_MONITOR_TELEMETRY_ENABLED") !== "true") return;
  const role = runtime.env("SUPABASE_SERVICE_ROLE_KEY");
  if (!role) return;
  try {
    const project = backendOrigin(runtime.env).origin;
    const response = await runtime.fetch(
      `${project.replace(/\/$/, "")}/rest/v1/rpc/aim_monitor_record_error`,
      {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(1000),
        headers: {
          apikey: role,
          Authorization: `Bearer ${role}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_component: "push", p_code: code }),
      },
    );
    await response.body?.cancel();
  } catch {
    /* Monitoring failure is never a delivery failure. */
  }
}

async function serverDrain(runtime: Runtime) {
  // Deployment can prepare the authenticated endpoints before Apple credentials
  // and the signed Test profile are ready. Do not claim/age queue attempts then.
  if (runtime.env("AIM_PUSH_ENABLED") !== "true")
    throw new Error("delivery_not_enabled");
  const role = runtime.env("SUPABASE_SERVICE_ROLE_KEY");
  if (!role) throw new Error("server_not_configured");
  try {
    const result = await drainQueue({
      rpc: createRPC(runtime, role, `Bearer ${role}`),
      fetch: runtime.fetch,
      token: (environment) => providerToken(runtime.env, environment),
      allowedTopics: (runtime.env("APNS_ALLOWED_TOPICS") ?? "")
        .split(",")
        .map((s) => s.trim()),
      allowedEnvironments: (
        runtime.env("APNS_ALLOWED_ENVIRONMENTS") ?? "sandbox"
      )
        .split(",")
        .map((s) => s.trim()),
    });
    if (result.failed > 0 || result.deferred > 0)
      await recordPushMonitorError(runtime, "delivery_failed");
    return result;
  } catch (error) {
    await recordPushMonitorError(runtime, "request_failed");
    throw error;
  }
}

export function createWorkerHandler(
  runtime: Runtime,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method !== "POST")
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    if (
      !(await validWorkerAuthorization(
        req.headers.get("Authorization"),
        runtime.env("AIM_PUSH_WORKER_SECRET"),
      ))
    )
      return Response.json(
        { error: "authentication_required" },
        { status: 401 },
      );
    try {
      return Response.json(await serverDrain(runtime));
    } catch {
      return Response.json({ error: "delivery_unavailable" }, { status: 503 });
    }
  };
}

async function readEvent(req: Request): Promise<Record<string, unknown>> {
  if (!req.body || Number(req.headers.get("content-length") ?? 0) > 8192)
    throw new Error("invalid_event");
  const reader = req.body.getReader(),
    parts: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 8192) throw new Error("invalid_event");
      parts.push(value);
    }
  } finally {
    await reader.cancel();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  const value: unknown = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(bytes),
  );
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("invalid_event");
  return value as Record<string, unknown>;
}

export function createEventHandler(
  runtime: Runtime,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method !== "POST")
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    const bearer = req.headers.get("Authorization");
    if (!bearer?.startsWith("Bearer ") || bearer.length > 8192)
      return Response.json(
        { error: "authentication_required" },
        { status: 401 },
      );
    let body: Record<string, unknown>;
    try {
      body = await readEvent(req);
    } catch {
      return Response.json({ error: "invalid_event" }, { status: 400 });
    }
    if (
      ![body.account, body.event, body.task, body.conversation].every(
        (v) => typeof v === "string" && uuid.test(v),
      ) ||
      typeof body.category !== "string" ||
      !categories.includes(body.category)
    )
      return Response.json({ error: "invalid_event" }, { status: 400 });
    try {
      const anon = runtime.env("SUPABASE_ANON_KEY");
      if (!anon) throw new Error("server_not_configured");
      await createRPC(
        runtime,
        anon,
        bearer,
      )("aim_enqueue_push", {
        p_account_id: body.account,
        p_event: body.event,
        p_task: body.task,
        p_conversation: body.conversation,
        p_category: body.category,
      });
    } catch {
      return Response.json({ error: "event_rejected" }, { status: 403 });
    }
    // Fast path is optional. Durable scheduler retries the same rows if configuration/network is unavailable.
    try {
      await serverDrain(runtime);
    } catch {
      /* The event is already durable. */
    }
    return Response.json({ queued: true });
  };
}
