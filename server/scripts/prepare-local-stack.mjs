/** Prepare source-only inputs for a disposable stack. Never starts a process or runtime. */
import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const defaultSource = fileURLToPath(new URL("../supabase/", import.meta.url));
const excludedDirectories = new Set([
  "node_modules",
  "cache",
  "caches",
  "dist",
  "build",
  "coverage",
  "private",
  "secrets",
  "backup",
  "backups",
  "link",
  "links",
]);
const functionExtensions = new Set([
  ".ts",
  ".mts",
  ".cts",
  ".js",
  ".mjs",
  ".cjs",
]);
const runtimeConfigs = new Set([
  "deno.json",
  "deno.jsonc",
  "import_map.json",
  "import-map.json",
]);
class PreparationFailure extends Error {}

/** Validate even excluded entries before copying: a hidden link is still a link. */
async function rejectSourceLinks(path) {
  const metadata = await lstat(path);
  if (metadata.isSymbolicLink())
    throw new PreparationFailure("source_symlink_not_allowed");
  if (metadata.isDirectory()) {
    for (const name of (await readdir(path)).sort())
      await rejectSourceLinks(join(path, name));
  } else if (!metadata.isFile())
    throw new PreparationFailure("unsupported_source_entry");
}

function excluded(name) {
  const lower = name.toLowerCase();
  return (
    name.startsWith(".") ||
    excludedDirectories.has(lower) ||
    /\.env(?:\.|$)/i.test(name)
  );
}

async function copySources(source, target, kind) {
  const metadata = await lstat(source);
  if (metadata.isSymbolicLink())
    throw new PreparationFailure("source_symlink_not_allowed");
  if (!metadata.isDirectory())
    throw new PreparationFailure("source_directory_required");
  await mkdir(target, { mode: 0o755 });
  for (const entry of (await readdir(source, { withFileTypes: true })).sort(
    (a, b) => a.name.localeCompare(b.name),
  )) {
    if (entry.isSymbolicLink())
      throw new PreparationFailure("source_symlink_not_allowed");
    if (excluded(entry.name)) continue;
    const from = join(source, entry.name),
      to = join(target, entry.name);
    if (entry.isDirectory()) await copySources(from, to, kind);
    else if (
      entry.isFile() &&
      (kind === "migrations"
        ? extname(entry.name) === ".sql"
        : functionExtensions.has(extname(entry.name)) ||
          runtimeConfigs.has(entry.name))
    ) {
      // Only runtime source/config types are copied; environment/private sidecars are not inputs.
      const current = await lstat(from);
      if (current.isSymbolicLink() || !current.isFile())
        throw new PreparationFailure("source_changed_during_preparation");
      await copyFile(from, to, constants.COPYFILE_EXCL);
      await chmod(to, 0o644);
    }
  }
}

function isolatedConfig(source) {
  const lines = [],
    experimental = [];
  let section = "",
    seenExperimental = false;
  for (const line of source.split(/\r?\n/)) {
    const header = /^\s*\[([^\]]+)\]\s*(?:#.*)?$/.exec(line);
    if (header) {
      section = header[1].trim().replace(/^(['"])(experimental)\1$/, "$2");
      if (section === "experimental") {
        if (seenExperimental)
          throw new PreparationFailure("duplicate_experimental_config");
        seenExperimental = true;
        continue;
      }
    }
    if (
      /^\s*(?:port|shadow_port|"port"|"shadow_port"|'port'|'shadow_port')\s*=/.test(
        line,
      )
    )
      continue;
    if (
      !section &&
      /^\s*(?:project_id|"project_id"|'project_id')\s*=/.test(line)
    )
      continue;
    if (section === "experimental") {
      if (!/^\s*(?:stack|"stack"|'stack')\s*=/.test(line))
        experimental.push(line);
    } else lines.push(line);
  }
  return `project_id = "${randomUUID()}"\n${lines.join("\n").trim()}\n\n[experimental]\n${experimental.join("\n").trim()}${experimental.some((line) => line.trim()) ? "\n" : ""}stack = true\n`;
}

/** All returned paths belong to a new private temporary parent; existing destinations are never reused. */
export async function prepareLocalStack({
  sourceSupabase = defaultSource,
  temporaryRoot = tmpdir(),
} = {}) {
  const source = resolve(sourceSupabase);
  await rejectSourceLinks(source);
  if (!(await lstat(source)).isDirectory())
    throw new PreparationFailure("source_directory_required");
  for (const name of ["migrations", "functions"]) {
    if (!(await lstat(join(source, name))).isDirectory())
      throw new PreparationFailure("source_directory_required");
  }
  const configPath = join(source, "config.toml");
  if (!(await lstat(configPath)).isFile())
    throw new PreparationFailure("source_config_required");
  const config = isolatedConfig(await readFile(configPath, "utf8"));
  const parent = await mkdtemp(
    join(resolve(temporaryRoot), "aim-local-stack-"),
  );
  try {
    await chmod(parent, 0o700);
    const project = join(parent, "project"),
      runtimeHome = join(parent, "runtime-home"),
      functionsEnv = join(parent, "functions.env");
    await mkdir(project, { mode: 0o700 });
    await mkdir(join(project, "supabase"), { mode: 0o700 });
    await copySources(
      join(source, "migrations"),
      join(project, "supabase", "migrations"),
      "migrations",
    );
    await copySources(
      join(source, "functions"),
      join(project, "supabase", "functions"),
      "functions",
    );
    await writeFile(join(project, "supabase", "config.toml"), config, {
      mode: 0o600,
      flag: "wx",
    });
    await mkdir(runtimeHome, { mode: 0o700 });
    await chmod(runtimeHome, 0o700);
    await writeFile(functionsEnv, "AIM_PUSH_ENABLED=false\n", {
      mode: 0o600,
      flag: "wx",
    });
    await chmod(functionsEnv, 0o600);
    return { parent, project, runtimeHome, functionsEnv };
  } catch (error) {
    await rm(parent, { recursive: true, force: true });
    throw error;
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  try {
    const args = process.argv.slice(2);
    if (args.length && (args.length !== 2 || args[0] !== "--source-supabase"))
      throw new PreparationFailure("invalid_arguments");
    const result = await prepareLocalStack(
      args.length ? { sourceSupabase: args[1] } : {},
    );
    process.stdout.write(result.parent + "\n");
  } catch (error) {
    process.stderr.write(
      (error instanceof PreparationFailure
        ? error.message
        : "local_stack_preparation_failed") + "\n",
    );
    process.exitCode = 1;
  }
}
