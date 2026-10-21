import { boundedBody } from "./request-body.ts";
import { backendOrigin } from "./backend-origin.ts";
export type AccountRuntime = {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
};
const exportTables = [
  "profiles",
  "projects",
  "conversations",
  "messages",
  "project_files",
  "user_preferences",
  "user_memory_documents",
  "aim_account_documents",
  "account_media_assets",
];
export function createAccountMaintenance(
  runtime: AccountRuntime,
  operation: "export" | "delete",
) {
  return async (request: Request): Promise<Response> => {
    const json = (body: unknown, status = 200) =>
      Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
    if (request.method !== "POST")
      return json({ error: "method_not_allowed" }, 405);
    const bearer = request.headers.get("Authorization");
    if (!bearer?.startsWith("Bearer "))
      return json({ error: "unauthorized" }, 401);
    const anon = runtime.env("SUPABASE_ANON_KEY");
    if (!anon) return json({ error: "not_configured" }, 503);
    let base: URL;
    try {
      base = backendOrigin(runtime.env);
    } catch {
      return json({ error: "not_configured" }, 503);
    }
    const call = (
      path: string,
      init: RequestInit = {},
      key = anon,
      auth = bearer,
    ) =>
      runtime.fetch(new URL(path, base), {
        ...init,
        redirect: "error",
        signal: AbortSignal.timeout(10000),
        headers: {
          apikey: key,
          Authorization: auth,
          "Content-Type": "application/json",
          ...init.headers,
        },
      });
    try {
      const auth = await call("/auth/v1/user");
      if (!auth.ok) {
        await auth.body?.cancel();
        return json({ error: "unauthorized" }, 401);
      }
      const user = JSON.parse(await boundedBody(auth, 64 * 1024)) as {
        id?: string;
        email?: string;
      };
      if (!user.id || !/^[0-9a-f-]{36}$/i.test(user.id))
        return json({ error: "unauthorized" }, 401);
      const live = await call("/rest/v1/rpc/aim_maintenance_session", {
        method: "POST",
        body: "{}",
      });
      if (!live.ok) {
        await live.body?.cancel();
        return json({ error: "session_revoked" }, 401);
      }
      if (JSON.parse(await boundedBody(live, 64)) !== true)
        return json({ error: "session_revoked" }, 401);
      if (operation === "export") {
        const tables: Record<string, unknown[]> = {};
        let bytes = 0;
        for (const table of exportTables) {
          const all: unknown[] = [];
          for (let offset = 0; ; offset += 250) {
            if (offset >= 20000)
              return json(
                {
                  error: "export_too_large",
                  message: "Use a database export for this account.",
                },
                413,
              );
            const result =
              table === "aim_account_documents"
                ? await call(
                    `/rest/v1/rpc/aim_export_account_documents?limit=250&offset=${offset}`,
                    { method: "POST", body: "{}" },
                  )
                : await call(
                    `/rest/v1/${table}?select=*&limit=250&offset=${offset}`,
                  );
            if (!result.ok) {
              await result.body?.cancel();
              return json({ error: "export_unavailable" }, 503);
            }
            let text: string;
            try {
              // Bound while streaming: a single document/page may exceed the whole export budget.
              text = await boundedBody(result, 25 * 1024 * 1024 - bytes);
            } catch (error) {
              if (
                error instanceof Error &&
                error.message === "request_too_large"
              )
                return json({ error: "export_too_large" }, 413);
              return json({ error: "export_unavailable" }, 503);
            }
            bytes += new TextEncoder().encode(text).length;
            const rows = JSON.parse(text);
            if (!Array.isArray(rows))
              return json({ error: "export_unavailable" }, 503);
            all.push(...rows);
            if (rows.length < 250) break;
          }
          tables[table] = all;
        }
        return json({
          version: 1,
          accountID: user.id,
          exportedAt: new Date().toISOString(),
          tables,
          includesBinaryAttachments: false,
          includesKeychainCredentials: false,
        });
      }
      if (Number(request.headers.get("Content-Length") ?? 0) > 2048)
        return json({ error: "invalid_confirmation" }, 400);
      let raw: string;
      try {
        raw = await boundedBody(request, 2048);
      } catch {
        return json({ error: "invalid_confirmation" }, 400);
      }
      if (raw.length > 2048)
        return json({ error: "invalid_confirmation" }, 400);
      let body: unknown;
      try {
        body = JSON.parse(raw);
      } catch {
        return json({ error: "invalid_confirmation" }, 400);
      }
      const input = body as { confirmEmail?: string; confirmText?: string };
      if (
        !user.email ||
        input?.confirmEmail?.trim().toLowerCase() !==
          user.email.toLowerCase() ||
        input?.confirmText !== "SUPPRIMER"
      )
        return json({ error: "invalid_confirmation" }, 400);
      const paths = await call("/rest/v1/rpc/aim_account_storage_paths", {
        method: "POST",
        body: "{}",
      });
      if (!paths.ok) {
        await paths.body?.cancel();
        return json({ error: "deletion_unavailable" }, 503);
      }
      let pathText: string;
      try {
        pathText = await boundedBody(paths, 10 * 1024 * 1024);
      } catch (error) {
        return json(
          {
            error:
              error instanceof Error && error.message === "request_too_large"
                ? "deletion_too_large"
                : "deletion_unavailable",
          },
          error instanceof Error && error.message === "request_too_large"
            ? 413
            : 503,
        );
      }
      const objects = JSON.parse(pathText) as {
        bucket: string;
        name: string;
      }[];
      if (
        !Array.isArray(objects) ||
        objects.some(
          (o) =>
            typeof o.bucket !== "string" ||
            typeof o.name !== "string" ||
            o.name.split("/")[0] !== user.id,
        )
      )
        return json({ error: "deletion_unavailable" }, 503);
      // No privileged credential is consulted before user/session/confirmation/path checks.
      const role = runtime.env("SUPABASE_SERVICE_ROLE_KEY");
      if (!role) return json({ error: "not_configured" }, 503);
      for (const bucket of [...new Set(objects.map((o) => o.bucket))]) {
        const names = objects
          .filter((o) => o.bucket === bucket)
          .map((o) => o.name);
        for (let index = 0; index < names.length; index += 100) {
          const removed = await call(
            `/storage/v1/object/${encodeURIComponent(bucket)}`,
            {
              method: "DELETE",
              body: JSON.stringify({
                prefixes: names.slice(index, index + 100),
              }),
            },
            role,
            `Bearer ${role}`,
          );
          if (!removed.ok) {
            await removed.body?.cancel();
            return json({ error: "deletion_incomplete_retry" }, 503);
          }
          await removed.body?.cancel();
        }
      }
      const removed = await call(
        `/auth/v1/admin/users/${user.id}`,
        { method: "DELETE" },
        role,
        `Bearer ${role}`,
      );
      if (!removed.ok) {
        await removed.body?.cancel();
        return json({ error: "deletion_incomplete_retry" }, 503);
      }
      await removed.body?.cancel();
      return json({ success: true });
    } catch {
      return json({ error: "service_unavailable" }, 503);
    }
  };
}
