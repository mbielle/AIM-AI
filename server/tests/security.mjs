import assert from "node:assert/strict";
import fs from "node:fs/promises";
export async function verify(db) {
  const scalar = async (sql, args = []) =>
    (await db.query(sql, args)).rows[0]?.r;
  const id = (n) => "10000000-0000-0000-0000-" + String(n).padStart(12, "0");
  const account = id(1),
    other = id(2),
    session = id(3),
    machine = id(4),
    device = id(5);
  await db.exec(
    `grant usage on schema auth,storage to authenticated;grant execute on all functions in schema auth to authenticated;grant select,insert,update,delete on storage.objects to authenticated;`,
  );
  await db.query("insert into auth.users(id,email) values($1,$2),($3,$4)", [
    account,
    "owner@example.invalid",
    other,
    "other@example.invalid",
  ]);
  await db.query("insert into auth.sessions(id,user_id) values($1,$2)", [
    session,
    account,
  ]);
  await db.query(
    "insert into remote_machines(id,user_id,name,secret_hash) values($1,$2,'Fixture Mac',encode(extensions.digest('fixture-machine-secret','sha256'),'hex'))",
    [machine, account],
  );
  await db.query(
    "insert into remote_devices(id,user_id,secret_hash) values($1,$2,encode(extensions.digest('fixture-device-secret','sha256'),'hex'))",
    [device, account],
  );
  await db.query(
    "select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$2,false)",
    [account, session],
  );
  await db.exec("set role authenticated");
  await db.query("select aim_register_account_session('Fixture','test')");
  assert.equal(await scalar("select aim_maintenance_session() as r"), true);
  await assert.rejects(
    () => scalar("select aim_require_live_session() as r"),
    /permission denied/,
  );
  await db.query("select aim_put_account_document($1::jsonb,$2)", [
    JSON.stringify({ id: id(90), kind: "chat", payload: "{}", revision: 0 }),
    account,
  ]);
  assert.equal(
    await scalar(
      "select count(*)::int as r from aim_export_account_documents()",
    ),
    1,
  );
  await assert.rejects(
    () => db.exec("select * from aim_account_documents"),
    /permission denied/,
  );
  assert.equal(
    await scalar("select count(*)::int as r from account_media_assets"),
    0,
  );
  const mediaPath = account + "/" + id(91) + "/result";
  await db.query("insert into storage.objects(bucket_id,name) values($1,$2)", [
    "account-media",
    mediaPath,
  ]);
  assert.equal(
    await scalar("select count(*)::int as r from storage.objects"),
    1,
  );
  await db.query("delete from storage.objects where name=$1", [mediaPath]);
  await assert.rejects(
    () =>
      db.query("insert into storage.objects(bucket_id,name) values($1,$2)", [
        "account-media",
        other + "/" + id(92) + "/result",
      ]),
    /row-level security/,
  );
  await db.query("select remote_migrate_device_authorization($1,$2)", [
    device,
    "fixture-device-secret",
  ]);
  await db.query("select aim_register_remote_host($1,$2)", [
    machine,
    "fixture-machine-secret",
  ]);
  const token = (
    await scalar("select remote_authorize_device($1,$2) as r", [
      device,
      "fixture-device-secret",
    ])
  ).token;
  const send = (
    command,
    secret = "fixture-device-secret",
    target = machine,
    tok = token,
  ) =>
    scalar(
      "select remote_send_command($1,$2,$3,$4,null,'create_session','{}'::jsonb,$5,'chat') as r",
      [device, secret, command, target, tok],
    );
  assert.equal(
    (await send(id(10))).ok,
    true,
    "paired/authorized request is admitted with no financial schema",
  );
  assert.equal(
    await scalar(
      "select count(*)::int as r from information_schema.schemata where schema_name='aim_billing_private'",
    ),
    0,
  );
  await assert.rejects(() => send(id(11), "wrong-secret"), /device_not_paired/);
  assert.notEqual(
    (await send(id(12), "fixture-device-secret", machine, "wrong-token")).ok,
    true,
  );
  await db.exec("reset role");
  await db.exec(
    "update aim_remote_capacity.settings set commands_per_minute=1",
  );
  await db.exec("set role authenticated");
  assert.equal((await send(id(15))).error, "rate_limited");
  assert.equal(
    (await send(id(10))).ok,
    true,
    "same authenticated command retry is not charged twice",
  );
  await db.exec("reset role");
  await db.exec(
    "update aim_remote_capacity.settings set commands_per_minute=120",
  );
  await db.query("insert into projects(id,user_id,name) values($1,$2,$3)", [
    id(20),
    other,
    "Other account",
  ]);
  await db.exec("set role authenticated");
  assert.equal(
    await scalar("select count(*)::int as r from projects"),
    0,
    "cross-account project is hidden",
  );
  await assert.rejects(
    () =>
      db.query("insert into projects(user_id,name) values($1,$2)", [
        other,
        "Forbidden",
      ]),
    /row-level security/,
  );
  await assert.rejects(
    () =>
      db.query(
        "insert into conversations(user_id,project_id,title) values($1,$2,$3)",
        [account, id(20), "Forbidden parent"],
      ),
    /project_not_owned/,
  );
  await assert.rejects(
    () => db.exec("select aim_monitor_snapshot()"),
    /permission denied|server_only/,
  );
  await db.exec("reset role");
  await db.query("update remote_devices set revoked_at=now() where id=$1", [
    device,
  ]);
  await db.exec("set role authenticated");
  await assert.rejects(() => send(id(13)), /device_not_paired/);
  await db.exec("reset role");
  await db.query("update remote_devices set revoked_at=null where id=$1", [
    device,
  ]);
  await db.query(
    "update aim_account_session_metadata set revoked_at=now() where id=$1",
    [session],
  );
  await db.exec("set role authenticated");
  await assert.rejects(() => send(id(14)), /session_revoked/);
  await assert.rejects(
    () => scalar("select aim_maintenance_session() as r"),
    /session_revoked/,
  );
  assert.equal(
    await scalar("select count(*)::int as r from account_media_assets"),
    0,
  );
  assert.equal(
    await scalar("select count(*)::int as r from profiles"),
    0,
    "revoked session cannot read its profile",
  );
  await db.exec("reset role");
  console.log(
    "PASS: free Remote admission, wrong secret/token, revoked device/session, cross-account RLS, operations privilege",
  );
  // Exercise upgrade/rollback with exact archived financial migrations inside this
  // isolated database only; production never sees this fixture.
  const oldURL = process.env.AIM_TEST_LEGACY_BILLING_MIGRATIONS;
  if (oldURL) {
    for (const name of [
      "20261011000100_aim_account_billing.sql",
      "20261011000300_aim_remote_billing_admission.sql",
    ])
      await db.exec(await fs.readFile(oldURL + "/" + name, "utf8"));
  } else {
    await db.exec(
      await fs.readFile(
        new URL("./fixtures/previous-billing.sql", import.meta.url),
        "utf8",
      ),
    );
  }
  await db.exec(
    await fs.readFile(
      new URL("../existing/20261016000100_free_access.sql", import.meta.url),
      "utf8",
    ),
  );
  await db.query(
    "update aim_account_session_metadata set revoked_at=null where id=$1",
    [session],
  );
  await db.exec("set role authenticated");
  assert.equal(
    (await send(id(30))).ok,
    true,
    "upgrade removes financial gate but delegates security checks",
  );
  await assert.rejects(() => send(id(31), "wrong-secret"), /device_not_paired/);
  const availability = await scalar(
    "select get_aim_entitlement('production') as r",
  );
  assert.equal(availability.source, "free");
  assert.equal(availability.trial_available, false);
  await db.exec("reset role");
  if (!oldURL)
    assert.equal(
      await scalar(
        "select count(*)::int as r from aim_billing_private.grants where external_id='fixture-history'",
      ),
      1,
    );
  await db.exec(
    await fs.readFile(
      new URL("../existing/rollback-free-access.sql", import.meta.url),
      "utf8",
    ),
  );
  console.log(
    "PASS: existing-installation upgrade, delegated authorization, legacy availability and rollback; historical data retained",
  );
}
