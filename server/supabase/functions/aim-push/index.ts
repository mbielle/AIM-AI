import { createEventHandler } from "../_shared/push-worker.ts";

// JWT verification stays enabled at the gateway. The user-scoped RPC additionally
// rejects revoked sessions and a launch account that no longer matches the JWT.
Deno.serve(createEventHandler({ env: (name) => Deno.env.get(name), fetch }));
