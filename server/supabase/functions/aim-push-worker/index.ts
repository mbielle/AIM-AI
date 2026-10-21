import { createWorkerHandler } from "../_shared/push-worker.ts";

// Gateway JWT verification is disabled ONLY for this server endpoint. The handler
// authenticates a separate random worker secret before using server credentials.
Deno.serve(createWorkerHandler({ env: (name) => Deno.env.get(name), fetch }));
