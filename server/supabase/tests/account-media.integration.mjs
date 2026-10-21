// Isolated PostgreSQL assertions only. No network client, credentials or deployed database.
import fs from "node:fs";
import assert from "node:assert/strict";
const { PGlite } = await import(
  process.env.AIM_PGLITE_MODULE || "@electric-sql/pglite"
);
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth; create schema storage;
create table auth.users(id uuid primary key);
create table auth.sessions(id uuid primary key,user_id uuid,not_after timestamptz);
create table public.aim_account_session_metadata(id uuid primary key,revoked_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('session_id',current_setting('request.jwt.claim.session_id',true))$$;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(bucket_id text,name text primary key);
alter table storage.objects enable row level security;
create function storage.foldername(text) returns text[] language sql immutable as $$select (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1]$$;
create function storage.filename(text) returns text language sql immutable as $$select (string_to_array($1,'/'))[array_length(string_to_array($1,'/'),1)]$$;
-- Fixture for the documented Storage operation helper; the real Storage HTTP service is not running here.
create function storage.allow_any_operation(text[]) returns boolean language sql stable as $$select coalesce(current_setting('fixture.storage.operation',true)=any($1),false)$$;
grant usage on schema auth,storage to authenticated;
grant select,insert,update,delete on storage.objects to authenticated;
`);
// Execute the exact current session guards, without replaying historical migrations.
const previous = fs.readFileSync(
  new URL(
    "../migrations/20261006000200_account_sessions_device_authorization.sql",
    import.meta.url,
  ),
  "utf8",
);
for (const name of ["aim_session_is_live", "aim_require_live_session"]) {
  const definition = previous.match(
    new RegExp("create function public\\." + name + "\\([^]*?\\$\\$;"),
  )?.[0];
  assert.ok(definition, "session guard must be present");
  await db.exec(definition);
}
await db.exec(
  fs.readFileSync(
    new URL(
      "../migrations/20261007000100_account_media_assets.sql",
      import.meta.url,
    ),
    "utf8",
  ),
);
const a = "10000000-0000-0000-0000-000000000001",
  b = "10000000-0000-0000-0000-000000000002";
const sa = "20000000-0000-0000-0000-000000000001",
  sb = "20000000-0000-0000-0000-000000000002";
const id = "30000000-0000-0000-0000-000000000001",
  other = "30000000-0000-0000-0000-000000000002";
const asset = {
  id,
  jobID: id,
  accountID: a,
  kind: "image",
  provider: "openRouter",
  modelID: "fixture/image",
  title: "Fixture",
  mimeType: "image/png",
  byteCount: 32,
  sha256: "a".repeat(64),
  createdAt: "2026-10-07T10:00:00Z",
};
const path = `${a}/${id}/result`;
await db.exec(
  `insert into auth.users values('${a}'),('${b}'); insert into auth.sessions values('${sa}','${a}',null),('${sb}','${b}',null);`,
);
let count = 0;
const check = (actual, expected, message) => {
  assert.deepEqual(actual, expected, message);
  count++;
};
const reject = async (action, pattern) => {
  await assert.rejects(action, pattern);
  count++;
};
const query = async (sql, args = []) => (await db.query(sql, args)).rows;
const login = async (user, session) => {
  await db.exec("reset role");
  await db.query(
    "select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$2,false)",
    [user, session],
  );
  await db.exec("set role authenticated");
};
const save = (value = asset, owner = a) =>
  db.query("select aim_put_media_asset($1,$2)", [owner, value]);
const insert = (name = path) =>
  db.query("insert into storage.objects values('account-media',$1)", [name]);
await login(a, sa);
await insert();
check(
  (await query("select * from storage.objects")).length,
  1,
  "owner can retrieve an uncommitted upload for safe retry",
);
await save();
await save();
check(
  (await query("select * from account_media_assets")).length,
  1,
  "same job sync is idempotent",
);
await reject(
  db.query(
    "insert into account_media_assets(account_id,id,job_id,payload) values($1,$2,$2,$3)",
    [a, other, asset],
  ),
  /permission denied/,
);
await reject(save({ ...asset, accountID: b }), /account_changed/);
await reject(save({ ...asset, jobID: other }), /invalid_media_asset/);
await reject(
  save({ ...asset, sha256: "b".repeat(64) }),
  /immutable_media_mismatch/,
);
await reject(insert(`${b}/${other}/result`), /row-level security/);
await reject(insert(`${a}/${other}/../result`), /row-level security/);
await login(b, sb);
check(
  (await query("select * from account_media_assets")).length,
  0,
  "metadata cannot cross accounts",
);
check(
  (await query("select * from storage.objects")).length,
  0,
  "private storage cannot cross accounts",
);
check(
  (await query("delete from storage.objects returning name")).length,
  0,
  "foreign bytes cannot be deleted",
);
await reject(save(), /account_changed/);
await login(a, sa);
await save({ ...asset, deletedAt: "2026-10-07T11:00:00Z" });
await save();
check(
  (
    await query(
      "select deleted_at is not null as deleted from account_media_assets",
    )
  )[0].deleted,
  true,
  "offline original cannot remove a tombstone",
);
check(
  (await query("select * from storage.objects")).length,
  0,
  "tombstoned bytes immediately lose read access",
);
check(
  (await query("update storage.objects set name=name returning name")).length,
  0,
  "tombstoned object cannot be overwritten",
);
await db.query(
  "select set_config('fixture.storage.operation','object.delete_many',false)",
);
await db.query("delete from storage.objects where name=$1", [path]);
await db.query(
  "select set_config('fixture.storage.operation','object.get_authenticated',false)",
);
await db.exec("reset role");
check(
  (await query("select * from storage.objects")).length,
  0,
  "owner may delete bytes after tombstone",
);
await login(a, sa);
await reject(insert(), /row-level security/);
await insert(`${a}/${other}/result`);
await db.exec("reset role");
await db.query("insert into aim_account_session_metadata values($1,now())", [
  sa,
]);
await login(a, sa);
await reject(save(), /session_revoked/);
await reject(query("select * from account_media_assets"), /session_revoked/);
await reject(query("select * from storage.objects"), /session_revoked/);
await reject(insert(`${a}/${other}/result`), /session_revoked/);
await db.exec("reset role");
await db.query("delete from aim_account_session_metadata where id=$1", [sa]);
await db.query(
  "update auth.sessions set not_after=now()-interval '1 second' where id=$1",
  [sa],
);
await login(a, sa);
await reject(save(), /session_revoked/);
await db.exec("reset role");
await db.exec("set role anon");
await reject(save(), /permission denied/);
await db.exec("reset role");
await db.exec(
  fs.readFileSync(
    new URL(
      "../rollbacks/20261007000100_account_media_assets.sql",
      import.meta.url,
    ),
    "utf8",
  ),
);
check(
  (
    await query(
      "select to_regclass('public.account_media_assets') is null as absent",
    )
  )[0].absent,
  true,
  "rollback closes metadata API",
);
check(
  (
    await query("select public from storage.buckets where id='account-media'")
  )[0].public,
  false,
  "rollback retains a private recovery bucket",
);
check(
  (
    await query(
      "select count(*)::int as n from pg_policies where policyname like 'aim_media_object_%'",
    )
  )[0].n,
  0,
  "rollback removes new access policies",
);
console.log(
  JSON.stringify({
    assertions: count,
    result: "passed",
    database: "isolated PGlite",
    productionApplied: false,
    network: "none",
  }),
);
await db.close();
