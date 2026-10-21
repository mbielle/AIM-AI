import { createRemoteUnlock } from "../_shared/remote-unlock.ts";
Deno.serve(createRemoteUnlock({ env: (name) => Deno.env.get(name), fetch }));
