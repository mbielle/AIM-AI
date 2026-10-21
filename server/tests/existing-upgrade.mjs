import fs from "node:fs/promises";
import assert from "node:assert/strict";
import { platformFixture } from "./platform-fixture.mjs";
import { verifyNativeHardening } from "./native-hardening.mjs";
import { verifyNativeUnlock } from "./native-unlock.mjs";
/** A second empty database models the reviewed pre-free baseline, not the fresh hardening chain. */
export async function verifyExistingUpgrade() {
  const db = await platformFixture();
  try {
    const migrations = new URL("../supabase/migrations/", import.meta.url);
    for (const name of (await fs.readdir(migrations))
      .filter((n) => n.endsWith(".sql") && n < "20261016000000")
      .sort())
      await db.exec(await fs.readFile(new URL(name, migrations), "utf8"));
    await db.exec(
      await fs.readFile(
        new URL("./fixtures/previous-billing.sql", import.meta.url),
        "utf8",
      ),
    );
    // Reproduce the old policies' private-helper dependency and inherited broad ACLs.
    await db.exec(`alter policy account_media_read on public.account_media_assets to authenticated using(account_id=auth.uid() and public.aim_require_live_session() is not null);
  alter policy aim_media_object_insert on storage.objects to authenticated with check(bucket_id='account-media' and public.aim_require_live_session() is not null);
  grant all on public.profiles,public.projects,public.conversations,public.messages,public.project_files,public.user_preferences,public.user_memory_documents,public.generated_images,public.generated_videos,public.user_connectors,public.remote_machines,public.remote_devices,public.remote_commands,public.remote_sessions,public.remote_messages,public.remote_transfers,public.remote_session_attachments,public.remote_device_keys to authenticated;`);
    for (const name of [
      "20261016000100_free_access.sql",
      "20261016000200_remote_capacity.sql",
      "20261016000300_maintenance_policy_hardening.sql",
    ])
      await db.exec(
        await fs.readFile(
          new URL("../existing/" + name, import.meta.url),
          "utf8",
        ),
      );
    assert.equal(
      (
        await db.query(
          "select count(*)::int n from aim_billing_private.grants where external_id='fixture-history'",
        )
      ).rows[0].n,
      1,
    );
    const account = "70000000-0000-0000-0000-000000000001",
      session = "70000000-0000-0000-0000-000000000002";
    await db.query("insert into auth.users(id,email) values($1,$2)", [
      account,
      "upgrade@example.invalid",
    ]);
    await db.query("insert into auth.sessions(id,user_id) values($1,$2)", [
      session,
      account,
    ]);
    await db.exec(
      "grant usage on schema auth to authenticated;grant execute on all functions in schema auth to authenticated;",
    );
    await db.query(
      "select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$2,false)",
      [account, session],
    );
    await db.exec("set role authenticated");
    await assert.rejects(
      () => db.query("select aim_require_live_session()"),
      /permission denied/,
    );
    await assert.rejects(
      () => db.query("select * from aim_account_documents"),
      /permission denied/,
    );
    assert.equal(
      (await db.query("select aim_maintenance_session() live")).rows[0].live,
      true,
    );
    await db.query("select aim_put_account_document($1::jsonb,$2)", [
      JSON.stringify({
        id: "70000000-0000-0000-0000-000000000003",
        kind: "chat",
        payload: "{}",
        revision: 0,
      }),
      account,
    ]);
    assert.equal(
      (
        await db.query(
          "select count(*)::int n from aim_export_account_documents()",
        )
      ).rows[0].n,
      1,
    );
    const path = account + "/70000000-0000-0000-0000-000000000004/result";
    await db.query(
      "insert into storage.objects(bucket_id,name) values($1,$2)",
      ["account-media", path],
    );
    assert.equal(
      (await db.query("select count(*)::int n from storage.objects")).rows[0].n,
      1,
    );
    await db.query("delete from storage.objects where name=$1", [path]);
    await db.exec("reset role");
    await verifyNativeUnlock(db);
    await verifyNativeHardening(db);
    assert.equal(
      (
        await db.query(
          "select count(*)::int n from aim_billing_private.grants where external_id='fixture-history'",
        )
      ).rows[0].n,
      1,
    );
    console.log(
      "PASS: separate existing-installation maintenance/policy upgrade, scoped exporter, media liveness, native hardening and retained financial history",
    );
  } finally {
    await db.close();
  }
}
