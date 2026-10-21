import fs from "node:fs/promises";
import { platformFixture } from "./platform-fixture.mjs";
const db = await platformFixture();
for (const name of (
  await fs.readdir(new URL("../supabase/migrations/", import.meta.url))
)
  .filter((n) => n.endsWith(".sql"))
  .sort()) {
  try {
    await db.exec(
      await fs.readFile(
        new URL("../supabase/migrations/" + name, import.meta.url),
        "utf8",
      ),
    );
  } catch (e) {
    console.error(name, e.message);
    process.exitCode = 1;
    await db.close();
    process.exit(1);
  }
  console.log("APPLIED", name);
}
await (await import("./native-unlock.mjs")).verifyNativeUnlock(db);
await (await import("./native-hardening.mjs")).verifyNativeHardening(db);
await (await import("./security.mjs")).verify(db);
await db.close();
await (await import("./existing-upgrade.mjs")).verifyExistingUpgrade();
