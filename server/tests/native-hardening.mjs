import assert from "node:assert/strict";
/** Real SQL-role tests, isolated synthetic accounts; no Auth/Storage HTTP service is simulated. */
export async function verifyNativeHardening(db) {
  const scalar = async (sql, args = []) =>
    (await db.query(sql, args)).rows[0]?.r;
  const id = (n) => "40000000-0000-0000-0000-" + String(n).padStart(12, "0");
  const account = id(1),
    other = id(2),
    session = id(3),
    machine = id(4),
    foreignMachine = id(5),
    device = id(6),
    foreignDevice = id(7);
  const machineSecret = "fixture-machine-" + "a".repeat(32),
    deviceSecret = "fixture-device-" + "b".repeat(32);
  const claims = async () => {
    await db.exec("reset role");
    await db.query(
      "select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$2,false)",
      [account, session],
    );
    await db.exec("set role authenticated");
  };
  await db.exec(
    "reset role;grant usage on schema auth to authenticated;grant execute on all functions in schema auth to authenticated;",
  );
  await db.query("insert into auth.users(id,email) values($1,$2),($3,$4)", [
    account,
    "fixture-a@example.invalid",
    other,
    "fixture-b@example.invalid",
  ]);
  await db.query("insert into auth.sessions(id,user_id) values($1,$2)", [
    session,
    account,
  ]);
  await db.query(
    "insert into remote_machines(id,user_id,secret_hash) values($1,$2,encode(extensions.digest($5,'sha256'),'hex')),($3,$4,encode(extensions.digest($5,'sha256'),'hex'))",
    [machine, account, foreignMachine, other, machineSecret],
  );
  await db.query(
    "insert into remote_devices(id,user_id,secret_hash) values($1,$2,encode(extensions.digest($3,'sha256'),'hex'))",
    [foreignDevice, other, deviceSecret],
  );
  await db.query(
    "insert into remote_device_keys(device_id,machine_id,key_version,user_id,envelope) values($1,$2,1,$3,'{}')",
    [foreignDevice, foreignMachine, other],
  );
  await db.query(
    "insert into remote_sessions(id,user_id,machine_id,mode) values($1,$2,$3,'chat')",
    [id(8), other, foreignMachine],
  );
  await claims();
  for (const table of [
    "profiles",
    "projects",
    "messages",
    "remote_machines",
    "remote_devices",
    "remote_commands",
    "remote_sessions",
    "remote_messages",
    "remote_transfers",
    "remote_session_attachments",
    "remote_device_keys",
  ]) {
    assert.equal(
      await scalar(
        "select has_table_privilege('authenticated',$1,'TRUNCATE') as r",
        [table],
      ),
      false,
      `${table} must never expose TRUNCATE`,
    );
  }
  assert.equal(
    await scalar("select count(*)::int as r from remote_machines"),
    1,
    "native machine list is owner scoped",
  );
  assert.equal(
    await scalar("select count(*)::int as r from remote_devices"),
    0,
    "foreign device is hidden",
  );
  await assert.rejects(
    () =>
      db.query(
        "insert into remote_commands(id,user_id,machine_id,type,payload) values($1,$2,$3,'request_keys','{}')",
        [id(9), account, machine],
      ),
    /permission denied/,
  );
  await assert.rejects(
    () =>
      db.query("update remote_machines set secret_hash='forged' where id=$1", [
        machine,
      ]),
    /permission denied/,
  );
  // A valid code for A cannot reset B's device or erase B's envelopes.
  const code = (
    await scalar("select remote_create_pairing_code($1,$2) as r", [
      machine,
      machineSecret,
    ])
  ).code;
  await assert.rejects(
    () =>
      scalar("select remote_pair_device($1,$2,$3,$4,$5) as r", [
        code,
        foreignDevice,
        deviceSecret,
        "Fixture",
        null,
      ]),
    /device_conflict/,
  );
  await db.exec("reset role");
  assert.equal(
    await scalar(
      "select count(*)::int as r from remote_device_keys where device_id=$1",
      [foreignDevice],
    ),
    1,
  );
  await claims();
  assert.equal(
    (
      await scalar("select remote_pair_device($1,$2,$3,$4,$5) as r", [
        code,
        device,
        deviceSecret,
        "Fixture",
        null,
      ])
    ).ok,
    true,
    "failed foreign pairing did not consume own code",
  );
  await assert.rejects(
    () =>
      db.query(
        "update remote_devices set secret_hash='forged',revoked_at=now() where id=$1",
        [device],
      ),
    /permission denied/,
  );
  await db.query("update remote_devices set revoked_at=now() where id=$1", [
    device,
  ]);
  await db.exec("reset role");
  await db.query("update remote_devices set revoked_at=null where id=$1", [
    device,
  ]);
  await claims();
  // Host publication and phone metadata writes need table ACLs as well as RLS.
  await db.query(
    "insert into remote_sessions(id,user_id,machine_id,mode,title) values($1,$2,$3,'chat','Fixture')",
    [id(10), account, machine],
  );
  await db.query("update remote_sessions set is_pinned=true where id=$1", [
    id(10),
  ]);
  await db.query(
    "insert into remote_messages(id,session_id,user_id,seq,role,content) values($1,$2,$3,1,'user','fixture encrypted text')",
    [id(11), id(10), account],
  );
  assert.equal(
    await scalar("select count(*)::int as r from remote_messages"),
    1,
  );
  await assert.rejects(
    () =>
      db.query(
        "insert into remote_sessions(id,user_id,machine_id,mode) values($1,$2,$3,'chat')",
        [id(12), account, foreignMachine],
      ),
    /machine_not_owned/,
  );
  await assert.rejects(
    () =>
      db.query(
        "insert into remote_messages(id,session_id,user_id,seq,role,content) values($1,$2,$3,2,'user','fixture')",
        [id(13), id(8), account],
      ),
    /session_not_owned/,
  );
  const transfer = id(14);
  await db.query(
    "insert into remote_transfers(id,user_id,machine_id,session_id,kind,key_version,manifest,chunk_count,expires_at) values($1,$2,$3,$4,'detail',1,'\"fixture ciphertext\"',1,now()+interval '1 hour')",
    [transfer, account, machine, id(10)],
  );
  await assert.rejects(
    () =>
      db.query("update remote_transfers set machine_id=$1 where id=$2", [
        foreignMachine,
        transfer,
      ]),
    /session_machine_mismatch/,
  );
  const transferPath = `${account}/${machine}/${transfer}/0`;
  await db.query("insert into storage.objects(bucket_id,name) values($1,$2)", [
    "remote-transfers",
    transferPath,
  ]);
  assert.equal(
    await scalar(
      "select count(*)::int as r from storage.objects where name=$1",
      [transferPath],
    ),
    1,
  );
  await db.query("delete from storage.objects where name=$1", [transferPath]);
  await db.query(
    "insert into remote_session_attachments(id,user_id,machine_id,session_id,key_version,metadata) values($1,$2,$3,$4,1,'\"fixture ciphertext\"')",
    [id(15), account, machine, id(10)],
  );
  assert.equal(
    await scalar("select count(*)::int as r from remote_session_attachments"),
    1,
  );
  // All ordinary read/write commands share the queue bound, while safety controls remain usable.
  await scalar("select remote_migrate_device_authorization($1,$2) as r", [
    device,
    deviceSecret,
  ]);
  await scalar("select aim_register_remote_host($1,$2) as r", [
    machine,
    machineSecret,
  ]);
  const token = (
    await scalar("select remote_authorize_device($1,$2) as r", [
      device,
      deviceSecret,
    ])
  ).token;
  const send = (n, type = "get_mac_settings") =>
    scalar(
      "select remote_send_command($1,$2,$3,$4,null,$5,'{}'::jsonb,$6,'chat') as r",
      [device, deviceSecret, id(n), machine, type, token],
    );
  await db.exec(
    "reset role;update aim_remote_capacity.settings set max_pending=1,commands_per_minute=120",
  );
  await claims();
  assert.equal((await send(30)).ok, true);
  assert.equal(
    (await send(31, "list_folders")).error,
    "queue_capacity_reached",
  );
  assert.equal((await send(32, "set_model")).error, "queue_capacity_reached");
  assert.equal(
    (await send(30)).ok,
    true,
    "exact command retries remain admitted at capacity",
  );
  assert.equal(
    (await send(33, "stop_generation")).ok,
    true,
    "stop remains admitted at capacity",
  );
  await db.exec("reset role");
  await db.query("update remote_commands set status='done' where user_id=$1", [
    account,
  ]);
  await db.query("delete from aim_remote_capacity.windows where user_id=$1", [
    account,
  ]);
  await db.exec(
    "update aim_remote_capacity.settings set max_pending=500,commands_per_minute=1",
  );
  await claims();
  assert.equal((await send(34)).ok, true);
  assert.equal(
    (await send(35, "request_detail")).error,
    "rate_limited",
    "ordinary reads cannot bypass per-minute limits",
  );
  await db.exec(
    "reset role;update aim_remote_capacity.settings set commands_per_minute=120,max_pending=500",
  );
  await db.query(
    "update aim_account_session_metadata set revoked_at=now() where id=$1",
    [session],
  );
  // A session may have no metadata until registered; register before explicit revocation.
  if (
    !(await scalar(
      "select exists(select 1 from aim_account_session_metadata where id=$1) as r",
      [session],
    ))
  )
    await db.query(
      "insert into aim_account_session_metadata(id,user_id,device,platform,revoked_at) values($1,$2,'Fixture','test',now())",
      [session, account],
    );
  await claims();
  assert.equal(
    await scalar("select count(*)::int as r from remote_machines"),
    0,
  );
  await assert.rejects(() => send(36), /session_revoked/);
  await db.exec("reset role");
  await db.query("delete from auth.users where id=$1", [account]);
  for (const table of [
    "profiles",
    "remote_machines",
    "remote_devices",
    "remote_sessions",
    "remote_messages",
    "remote_transfers",
    "remote_session_attachments",
  ])
    assert.equal(
      await scalar(
        `select count(*)::int as r from ${table} where ${table === "profiles" ? "id" : "user_id"}=$1`,
        [account],
      ),
      0,
      `${table} cascades only deleted account`,
    );
  assert.equal(
    await scalar(
      "select count(*)::int as r from remote_device_keys where device_id=$1",
      [foreignDevice],
    ),
    1,
    "other account data survives account deletion",
  );
  console.log(
    "PASS: explicit native ACLs, no TRUNCATE/direct command insert, parent ownership, foreign pairing, transfer Storage, read-command bounds and account cascade",
  );
}
