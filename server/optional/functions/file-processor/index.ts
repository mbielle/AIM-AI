import { createFileProcessor } from "./handler.ts";
Deno.serve(createFileProcessor({ env: (name) => Deno.env.get(name), fetch }));
