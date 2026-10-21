// Optional operations webhook; no user/account contents or hard-coded recipient.
import { createRPC, validWorkerAuthorization } from "./push-worker.ts";
export type MonitorRuntime = {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
};
export const monitorAuthorization = validWorkerAuthorization;
export function createMonitorHandler(runtime: MonitorRuntime) {
  return async (request: Request): Promise<Response> => {
    const json = (body: unknown, status = 200) =>
      Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
    if (request.method !== "POST")
      return json({ error: "method_not_allowed" }, 405);
    if (
      !(await validWorkerAuthorization(
        request.headers.get("Authorization"),
        runtime.env("AIM_MONITOR_WORKER_SECRET"),
      ))
    )
      return json({ error: "unauthorized" }, 401);
    const role = runtime.env("SUPABASE_SERVICE_ROLE_KEY");
    if (!role) return json({ error: "monitor_not_configured" }, 503);
    try {
      const rpc = createRPC(runtime, role, `Bearer ${role}`);
      const snapshot = (await rpc("aim_monitor_snapshot")) as Record<
        string,
        unknown
      >;
      const keys = [
        "push_errors",
        "push_failed",
        "push_backlog",
        "postgres_errors",
        "api_errors",
      ];
      if (
        !snapshot ||
        keys.some(
          (k) => !Number.isSafeInteger(snapshot[k]) || Number(snapshot[k]) < 0,
        ) ||
        typeof snapshot.server_time !== "string" ||
        !Number.isFinite(Date.parse(snapshot.server_time))
      )
        return json({ error: "invalid_snapshot" }, 503);
      const observations: Record<string, boolean> = {
        push:
          Number(snapshot.push_errors) +
            Number(snapshot.push_failed) +
            Number(snapshot.push_backlog) >
          0,
        postgres_errors: Number(snapshot.postgres_errors) > 0,
        api_errors: Number(snapshot.api_errors) > 0,
        postgres_api:
          Math.abs(Date.now() - Date.parse(snapshot.server_time)) > 120000,
      };
      const endpoint = runtime.env("AIM_MONITOR_ALERT_WEBHOOK_URL");
      if (!endpoint) return json({ enabled: false, observations });
      const url = new URL(endpoint);
      if (url.protocol !== "https:" || url.username || url.password)
        return json({ error: "monitor_not_configured" }, 503);
      let sent = 0;
      for (const [key, active] of Object.entries(observations)) {
        const claim = (await rpc("aim_monitor_claim", {
          p_key: key,
          p_active: active,
        })) as { lease: string; generation: number } | null;
        if (!claim) continue;
        let delivered = false;
        try {
          const token = runtime.env("AIM_MONITOR_ALERT_WEBHOOK_TOKEN");
          const result = await runtime.fetch(url.href, {
            method: "POST",
            redirect: "error",
            signal: AbortSignal.timeout(7000),
            headers: {
              "Content-Type": "application/json",
              ...(token ? { Authorization: `Bearer ${token}` } : {}),
            },
            body: JSON.stringify({
              component: "aim",
              key,
              active,
              generation: claim.generation,
            }),
          });
          delivered = result.ok;
          await result.body?.cancel();
          if (delivered) sent++;
        } finally {
          await rpc("aim_monitor_finish", {
            p_key: key,
            p_lease: claim.lease,
            p_sent: delivered,
          });
        }
      }
      return json({ sent });
    } catch {
      return json({ error: "monitor_unavailable" }, 503);
    }
  };
}
