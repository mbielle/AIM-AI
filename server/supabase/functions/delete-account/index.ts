import { createAccountMaintenance } from "../_shared/account-maintenance.ts";
Deno.serve(
  createAccountMaintenance(
    { env: (name) => Deno.env.get(name), fetch },
    "delete",
  ),
);
