import { boundedBody } from "./request-body.ts";
import { backendOrigin } from "./backend-origin.ts";
export type UnlockRuntime = {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
};
/** Native PIN/lock compatibility; no browser WebAuthn or privileged service key dependency. */
export function createRemoteUnlock(runtime: UnlockRuntime) {
  return async (request: Request): Promise<Response> => {
    const json = (body: unknown, status = 200) =>
      Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
    if (request.method !== "POST")
      return json({ ok: false, error: "method_not_allowed" }, 405);
    const bearer = request.headers.get("Authorization");
    if (!bearer?.startsWith("Bearer "))
      return json({ ok: false, error: "not_authenticated" }, 401);
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(await boundedBody(request, 8192));
      if (!body || typeof body !== "object" || Array.isArray(body))
        throw Error();
    } catch {
      return json({ ok: false, error: "invalid_request" }, 400);
    }
    const action = body.action,
      device = body.deviceId,
      secret = body.deviceSecret;
    if (!["pin-set", "pin-verify", "lock"].includes(String(action)))
      return json({ ok: false, error: "action_inconnue" }, 400);
    if (
      typeof device !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        device,
      ) ||
      typeof secret !== "string" ||
      secret.length < 1 ||
      secret.length > 1024 ||
      (body.pin !== undefined &&
        body.pin !== null &&
        typeof body.pin !== "string") ||
      (body.unlockToken !== undefined &&
        body.unlockToken !== null &&
        typeof body.unlockToken !== "string")
    )
      return json({ ok: false, error: "invalid_request" }, 400);
    const key = runtime.env("SUPABASE_ANON_KEY");
    let base: URL;
    try {
      base = backendOrigin(runtime.env);
      if (!key) throw Error();
    } catch {
      return json({ ok: false, error: "not_configured" }, 503);
    }
    const call = (path: string, init: RequestInit = {}) =>
      runtime.fetch(new URL(path, base), {
        ...init,
        redirect: "error",
        signal: AbortSignal.timeout(10000),
        headers: {
          apikey: key!,
          Authorization: bearer,
          "Content-Type": "application/json",
        },
      });
    try {
      const auth = await call("/auth/v1/user");
      if (!auth.ok) {
        await auth.body?.cancel();
        return json({ ok: false, error: "not_authenticated" }, 401);
      }
      const user = JSON.parse(await boundedBody(auth, 65536)) as { id?: unknown };
      if (typeof user.id !== "string")
        return json({ ok: false, error: "not_authenticated" }, 401);
      // The authoritative RPC rechecks session/device and performs PIN/token changes atomically.
      const response = await call("/rest/v1/rpc/aim_native_pin_unlock", {
        method: "POST",
        body: JSON.stringify({
          p_action: action,
          p_device_id: device,
          p_device_secret: secret,
          p_pin: body.pin ?? null,
          p_unlock_token: body.unlockToken ?? null,
        }),
      });
      const result = JSON.parse(await boundedBody(response, 65536)) as Record<string, unknown>;
      if (!response.ok) {
        const message = String(result.message ?? "");
        const error = ["session_revoked", "device_not_paired"].find(
          (code) => message === code,
        );
        return json(
          { ok: false, error: error ?? "unlock_unavailable" },
          error ? 403 : 503,
        );
      }
      if (!result || typeof result.ok !== "boolean")
        return json({ ok: false, error: "unlock_unavailable" }, 503);
      if (result.ok && action !== "lock") {
        const token = result.unlock as
          | { token?: unknown; expiresAt?: unknown; method?: unknown }
          | undefined;
        if (
          !token ||
          typeof token.token !== "string" ||
          !/^[a-f0-9]{64}$/.test(token.token) ||
          typeof token.expiresAt !== "string" ||
          !Number.isFinite(Date.parse(token.expiresAt)) ||
          token.method !== "pin"
        )
          return json({ ok: false, error: "unlock_unavailable" }, 503);
        return json({ ok: true, unlock: token });
      }
      if (result.ok) return json({ ok: true });
      const allowed = [
        "pin_invalide",
        "deverrouillage_requis",
        "no_pin",
        "locked",
        "wrong_pin",
        "legacy_security_retired",
        "action_inconnue",
      ];
      if (!allowed.includes(String(result.error)))
        return json({ ok: false, error: "unlock_unavailable" }, 503);
      return json(
        {
          ok: false,
          error: result.error,
          ...(Number.isSafeInteger(result.attempts)
            ? { attempts: result.attempts }
            : {}),
          ...(typeof result.locked_until === "string" &&
          Number.isFinite(Date.parse(result.locked_until))
            ? { locked_until: result.locked_until }
            : {}),
        },
        403,
      );
    } catch {
      return json({ ok: false, error: "unlock_unavailable" }, 503);
    }
  };
}
