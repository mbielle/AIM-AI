import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  readdir,
  stat,
  symlink,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { prepareLocalStack } from "./prepare-local-stack.mjs";
const execute = promisify(execFile);

async function fixture(t, config) {
  const root = await mkdtemp(join(tmpdir(), "aim-prepare-fixture-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, "source");
  for (const directory of [
    "migrations",
    "functions/_shared",
    "functions/endpoint",
    "functions/.private",
    "functions/cache",
    "functions/link",
    ".temp",
    "backups",
  ])
    await mkdir(join(source, directory), { recursive: true });
  await writeFile(
    join(source, "config.toml"),
    config ??
      `project_id = "fixture-old-id"\n[api]\nport = 54321\nmax_rows = 1000\n[db]\nport = 54322\nshadow_port = 54320\nmajor_version = 17\n[functions.endpoint]\nverify_jwt = true\n`,
  );
  await writeFile(join(source, "migrations/001.sql"), "select 1;\n");
  await writeFile(
    join(source, "functions/_shared/helper.ts"),
    "export const fixture = true;\n",
  );
  await writeFile(
    join(source, "functions/endpoint/index.ts"),
    'import "../_shared/helper.ts";\n',
  );
  await writeFile(join(source, "functions/deno.json"), "{}\n");
  for (const path of [
    "secret.env",
    "functions/endpoint/secret.env",
    "functions/endpoint/.env.local",
    "functions/.private/identity.ts",
    "functions/cache/state.ts",
    "functions/link/project.ts",
    ".temp/project-ref",
    "backups/data.sql",
  ])
    await writeFile(join(source, path), "fixture-only private sidecar\n");
  return { root, source };
}
const mode = async (path) => (await stat(path)).mode & 0o777;
async function files(directory, prefix = "") {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = prefix + entry.name;
    if (entry.isDirectory())
      result.push(
        ...(await files(join(directory, entry.name), relative + "/")),
      );
    else result.push(relative);
  }
  return result.sort();
}

test("preparation copies only source closure, leaves private sidecars out and disables push", async (t) => {
  const { root, source } = await fixture(t);
  const prepared = await prepareLocalStack({
    sourceSupabase: source,
    temporaryRoot: root,
  });
  assert.equal(await mode(prepared.parent), 0o700);
  assert.equal(await mode(prepared.runtimeHome), 0o700);
  assert.equal(await mode(prepared.functionsEnv), 0o600);
  assert.equal(
    await readFile(prepared.functionsEnv, "utf8"),
    "AIM_PUSH_ENABLED=false\n",
  );
  assert.deepEqual(await files(prepared.parent), [
    "functions.env",
    "project/supabase/config.toml",
    "project/supabase/functions/_shared/helper.ts",
    "project/supabase/functions/deno.json",
    "project/supabase/functions/endpoint/index.ts",
    "project/supabase/migrations/001.sql",
  ]);
  assert.equal(
    await readFile(
      join(prepared.project, "supabase/functions/endpoint/index.ts"),
      "utf8",
    ),
    'import "../_shared/helper.ts";\n',
  );
  assert.equal(
    await readFile(join(source, "secret.env"), "utf8"),
    "fixture-only private sidecar\n",
  );
  assert.ok(prepared.project.startsWith(prepared.parent + "/"));
  assert.ok(prepared.runtimeHome.startsWith(prepared.parent + "/"));
  assert.ok(prepared.functionsEnv.startsWith(prepared.parent + "/"));
});

test("isolated config replaces project identity, removes fixed ports and keeps gateway settings", async (t) => {
  const { root, source } = await fixture(t);
  const prepared = await prepareLocalStack({
    sourceSupabase: source,
    temporaryRoot: root,
  });
  const config = await readFile(
    join(prepared.project, "supabase/config.toml"),
    "utf8",
  );
  assert.match(
    config,
    /^project_id = "[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}"\n/,
  );
  assert.doesNotMatch(config, /fixture-old-id|^\s*(?:port|shadow_port)\s*=/m);
  assert.match(config, /\[functions\.endpoint\]\nverify_jwt = true/);
  assert.match(config, /\[db\]\nmajor_version = 17/);
  assert.match(config, /\[experimental\]\nstack = true\n$/);
  assert.match(
    await readFile(join(source, "config.toml"), "utf8"),
    /fixture-old-id/,
  );
});

test("existing experimental settings are preserved once with stack enabled", async (t) => {
  const { root, source } = await fixture(
    t,
    'project_id="old"\n[experimental]\nstack=false\nfixture_feature="retained"\n[api]\nport=54321\nmax_rows=1000\n',
  );
  const prepared = await prepareLocalStack({
    sourceSupabase: source,
    temporaryRoot: root,
  });
  const config = await readFile(
    join(prepared.project, "supabase/config.toml"),
    "utf8",
  );
  assert.equal((config.match(/\[experimental\]/g) ?? []).length, 1);
  assert.match(
    config,
    /\[experimental\]\nfixture_feature="retained"\nstack = true/,
  );
  assert.doesNotMatch(config, /stack=false/);
});

test("source links including hidden private links are refused without following their targets", async (t) => {
  const { root, source } = await fixture(t);
  const outside = join(root, "outside");
  await mkdir(outside);
  await writeFile(join(outside, "fixture.ts"), "fixture external content");
  for (const [path, type] of [
    ["functions/endpoint/alias.ts", "file"],
    ["functions/.private/alias", "dir"],
  ]) {
    const link = join(source, path);
    await symlink(
      type === "file" ? join(outside, "fixture.ts") : outside,
      link,
      type,
    );
    await assert.rejects(
      prepareLocalStack({ sourceSupabase: source, temporaryRoot: root }),
      /source_symlink_not_allowed/,
    );
    await rm(link);
  }
  const alias = join(root, "source-alias");
  await symlink(source, alias, "dir");
  await assert.rejects(
    prepareLocalStack({ sourceSupabase: alias, temporaryRoot: root }),
    /source_symlink_not_allowed/,
  );
  assert.deepEqual(
    (await readdir(root)).filter((name) => name.startsWith("aim-local-stack-")),
    [],
  );
});

test("repeated preparations get separate parents and UUIDs without overwriting earlier files", async (t) => {
  const { root, source } = await fixture(t);
  const first = await prepareLocalStack({
    sourceSupabase: source,
    temporaryRoot: root,
  });
  await writeFile(
    join(first.project, "keep.txt"),
    "first preparation sentinel",
  );
  const second = await prepareLocalStack({
    sourceSupabase: source,
    temporaryRoot: root,
  });
  assert.notEqual(first.parent, second.parent);
  assert.notEqual(
    await readFile(join(first.project, "supabase/config.toml"), "utf8"),
    await readFile(join(second.project, "supabase/config.toml"), "utf8"),
  );
  assert.equal(
    await readFile(join(first.project, "keep.txt"), "utf8"),
    "first preparation sentinel",
  );
});

test("CLI prints only the private parent path and creates no runtime process or state", async (t) => {
  const { source } = await fixture(t);
  const { stdout, stderr } = await execute(process.execPath, [
    fileURLToPath(new URL("./prepare-local-stack.mjs", import.meta.url)),
    "--source-supabase",
    source,
  ]);
  const parent = stdout.trim();
  t.after(() => rm(parent, { recursive: true, force: true }));
  assert.equal(stdout, parent + "\n");
  assert.equal(stderr, "");
  assert.equal(await mode(parent), 0o700);
  assert.deepEqual((await readdir(parent)).sort(), [
    "functions.env",
    "project",
    "runtime-home",
  ]);
  assert.deepEqual(await readdir(join(parent, "runtime-home")), []);
});
