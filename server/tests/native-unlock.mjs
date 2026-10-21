import assert from "node:assert/strict";
/** Exercise the authoritative bcrypt, attempt lockout and device-v2 boundary under actual SQL roles. */
export async function verifyNativeUnlock(db) {
  const scalar = async (sql, args = []) =>
    (await db.query(sql, args)).rows[0]?.r;
  const id = (n) => "60000000-0000-0000-0000-" + String(n).padStart(12, "0");
  const account = id(1),
    other = id(2),
    session = id(3),
    device = id(4),
    foreignDevice = id(5);
  const secret = "fixture-unlock-" + "u".repeat(32);
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
    "unlock-a@example.invalid",
    other,
    "unlock-b@example.invalid",
  ]);
  await db.query("insert into auth.sessions(id,user_id) values($1,$2)", [
    session,
    account,
  ]);
  await db.query(
    "insert into remote_devices(id,user_id,secret_hash) values($1,$2,encode(extensions.digest($5,'sha256'),'hex')),($3,$4,encode(extensions.digest($5,'sha256'),'hex'))",
    [device, account, foreignDevice, other, secret],
  );
  await claims();
  const invoke = (
    action,
    pin = null,
    token = null,
    target = device,
    deviceSecret = secret,
  ) =>
    scalar("select aim_native_pin_unlock($1,$2,$3,$4,$5) as r", [
      action,
      target,
      deviceSecret,
      pin,
      token,
    ]);
  await assert.rejects(
    () =>
      scalar("select remote_unlock_check_pin($1,$2) as r", [account, "123456"]),
    /permission denied/,
  );
  await assert.rejects(
    () => invoke("pin-set", "123456", null, foreignDevice),
    /device_not_paired/,
  );
  await assert.rejects(
    () => invoke("pin-set", "123456", null, device, "wrong"),
    /device_not_paired/,
  );
  assert.equal((await invoke("pin-verify", "123456")).error, "no_pin");
  assert.equal((await invoke("pin-set", "12345")).error, "pin_invalide");
  const first = await invoke("pin-set", "123456");
  assert.equal(first.ok, true);
  assert.match(first.unlock.token, /^[a-f0-9]{64}$/);
  assert.equal(first.unlock.method, "pin");
  await db.exec("reset role");
  assert.equal(
    await scalar(
      "select pin_hash<>$2 and pin_hash like '$2%' as r from remote_unlock_pin where user_id=$1",
      [account, "123456"],
    ),
    true,
    "PIN is bcrypt, never plaintext",
  );
  assert.equal(
    await scalar(
      "select token_hash<>$2 and token_hash=encode(extensions.digest($2,'sha256'),'hex') as r from remote_unlock_sessions where user_id=$1",
      [account, first.unlock.token],
    ),
    true,
    "only token hash is stored",
  );
  await claims();
  assert.equal(
    (await invoke("pin-set", "654321")).error,
    "deverrouillage_requis",
  );
  for (let attempt = 1; attempt <= 5; attempt++) {
    const result = await invoke("pin-verify", "000000");
    assert.equal(result.error, "wrong_pin");
    assert.equal(result.attempts, attempt);
  }
  const locked = await invoke("pin-verify", "123456");
  assert.equal(locked.error, "locked");
  assert.ok(Date.parse(locked.locked_until) > Date.now());
  await db.exec("reset role");
  await db.query(
    "update remote_unlock_pin set locked_until=now()-interval '1 minute' where user_id=$1",
    [account],
  );
  await claims();
  const verified = await invoke("pin-verify", "123456");
  assert.equal(verified.ok, true);
  const changed = await invoke("pin-set", "654321", verified.unlock.token);
  assert.equal(
    changed.ok,
    true,
    "current own device token authorizes PIN change",
  );
  await invoke("lock", null, changed.unlock.token);
  await db.exec("reset role");
  assert.equal(
    await scalar(
      "select count(*)::int as r from remote_unlock_sessions where user_id=$1 and token_hash=encode(extensions.digest($2,'sha256'),'hex')",
      [account, changed.unlock.token],
    ),
    0,
  );
  await claims();
  await scalar("select remote_migrate_device_authorization($1,$2) as r", [
    device,
    secret,
  ]);
  const grant = await scalar("select remote_authorize_device($1,$2) as r", [
    device,
    secret,
  ]);
  assert.equal(
    (await invoke("pin-set", "123456")).error,
    "legacy_security_retired",
  );
  assert.equal(
    (await invoke("pin-verify", "654321")).error,
    "legacy_security_retired",
  );
  assert.equal(
    (await invoke("lock", null, grant.token)).ok,
    true,
    "cleanup stays available after v2 migration",
  );
  await db.exec("reset role");
  assert.equal(
    await scalar(
      "select revoked_at is not null as r from aim_device_grants where user_id=$1",
      [account],
    ),
    true,
  );
  assert.equal(
    await scalar(
      "select count(*)::int as r from remote_unlock_pin where user_id=$1",
      [account],
    ),
    0,
    "PIN cannot be recreated after migration",
  );
  await db.query(
    "insert into aim_account_session_metadata(id,user_id,device,platform,revoked_at) values($1,$2,'Fixture','test',now())",
    [session, account],
  );
  await claims();
  await assert.rejects(() => invoke("lock"), /session_revoked/);
  await db.exec("reset role");
  await db.query("delete from auth.users where id in ($1,$2)", [
    account,
    other,
  ]);
  console.log(
    "PASS: native PIN bcrypt, token hashing, five-attempt lockout, owner/device/session checks and v2 retirement/lock cleanup",
  );
}
