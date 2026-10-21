import { createMonitorHandler } from "../_shared/release-monitor.ts";
// Deploy with --no-verify-jwt: this endpoint requires its own server-only 256-bit secret.
// It is never called by the public website or by app clients.
Deno.serve(createMonitorHandler({ env: (name) => Deno.env.get(name), fetch }));
