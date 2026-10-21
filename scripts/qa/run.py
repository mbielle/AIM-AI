#!/usr/bin/env python3
"""Run local AIM checks, preserving the distinction between tests and owner gates.

Exit 0: all requested checks passed; 1: an observed failure; 2: preparation or
unexecuted checks remain. Reports never update the owner publication register.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from catalog import ROOT, REGISTRY, CORE_QUICK, MAC_QUICK, UI_TESTS, registry, render

PASS, FAIL, BLOCKED, NOT_RUN = "VALIDÉ", "ÉCHEC", "À PRÉPARER", "À TESTER"

PROCESS_CASES = {
    "sourcekit": {"original": "AIMMacPlatformTests.CodeIntelligenceTests/testSourceKitDiagnosticsSymbolsAndDefinition",
        "checks": {"diagnostic-line7", "symbols-greeter-greet", "definition-line2", "outside-scope-denied"}},
    "confinement": {"original": "AIMMacPlatformTests.ConfinementSecretsTests/testSecretFilesStayHiddenButPackageFoldersNamedCredentialsAreReadable",
        "checks": {"worker-started-package-list", "sdk-code-exact", "aws-denied-after-start", "env-denied-after-start"}},
}


def direct_qualification():
    spec = importlib.util.spec_from_file_location("direct_qualification", ROOT / "scripts/direct/qualify-controller.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_process_receipt(path, case, run_id, source_sha, binary_sha, namespace, started, finished):
    """Fail closed on stale, missing, partial or substituted native evidence."""
    value = json.loads(Path(path).read_text())
    expected = PROCESS_CASES[case]
    if not isinstance(value, dict):
        raise ValueError("Native receipt must be an object")
    if (value.get("schema") != 1 or value.get("runID") != run_id or value.get("caseID") != case
        or value.get("originalTest") != expected["original"] or value.get("sourceSHA256") != source_sha
        or value.get("binarySHA256") != binary_sha or value.get("namespace") != namespace
        or value.get("status") != "passed" or value.get("physicalDevicesQualified") is not False
        or type(value.get("pid")) is not int or value["pid"] <= 0):
        raise ValueError("Native receipt identity/status mismatch")
    times = [datetime.fromisoformat(value[key].replace("Z", "+00:00")).timestamp() for key in ("startedAt", "finishedAt")]
    if not started - 1 <= times[0] <= times[1] <= finished + 1 or Path(path).stat().st_mtime < started:
        raise ValueError("Native receipt is stale or time order invalid")
    checks = value.get("checks", [])
    if not isinstance(checks, list) or any(not isinstance(c, dict) for c in checks):
        raise ValueError("Native checks must be objects in an array")
    required = expected["checks"] | {"startup-no-discovery", "finish-no-discovery"}
    if len(checks) != len(required) or {c.get("id") for c in checks} != required:
        raise ValueError("Native check omitted, duplicated or unexpected")
    if any(c.get("passed") is not True or not isinstance(c.get("expected"), str) or not c["expected"]
           or not isinstance(c.get("observed"), str) for c in checks):
        raise ValueError("Native checks incomplete or failed")
    return value


def xctest_bundle_counts(output):
    bundles = {}
    pattern = (r"Test Suite '([^']+[.]xctest)' (?:passed|failed)[^\n]*\n\s*"
        r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?")
    for name, selected, skipped, failures in re.findall(pattern, output):
        counts = dict(selected=int(selected), skipped=int(skipped or 0), failures=int(failures))
        if name in bundles and bundles[name] != counts:
            raise ValueError("Ambiguous duplicate XCTest bundle summaries")
        bundles[name] = counts
    return dict(bundles=bundles, selected=sum(c["selected"] for c in bundles.values()),
        skipped=sum(c["skipped"] for c in bundles.values()),
        executed=sum(c["selected"] - c["skipped"] for c in bundles.values()),
        failures=sum(c["failures"] for c in bundles.values()))


def validate_initialization_trace(output):
    active = len(re.findall(r"INITIALIZE:.*calling \+\[", output))
    if not active:
        raise ValueError("Objective-C initialization trace missing")
    if re.search(r"INITIALIZE:.*(?:\+\[(?:CN|ABAddress|ABPerson|ABGroup|ABRecord|XCTest)|ContactsUI|XCTest)", output, re.I):
        raise ValueError("Unexpected Contacts/XCTest initialization")
    return active


def now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def redact(value):
    # Decode quoted field names and complete JSON values, including nested
    # objects/arrays. Regex-only bare assignments miss camelCase and JSON quotes.
    sensitive = {"authorization", "apikey", "accesstoken", "refreshtoken",
                 "password", "secret", "clientsecret", "privatekey", "invitation", "token"}
    decoder = json.JSONDecoder()
    pieces, cursor = [], 0
    for match in re.finditer(r'"(?:\\.|[^"\\])*"\s*:\s*', value):
        if match.start() < cursor:
            continue
        key = decoder.raw_decode(match.group())[0]
        if re.sub(r"[^a-z0-9]", "", key.lower()) not in sensitive:
            continue
        try:
            _, length = decoder.raw_decode(value[match.end():])
        except ValueError:
            continue  # malformed/bare assignments are handled below
        pieces.extend([value[cursor:match.end()], '"[REDACTED]"'])
        cursor = match.end() + length
    pieces.append(value[cursor:])
    value = "".join(pieces)
    value = re.sub(r"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,\"}]+", r"\1[REDACTED]", value)
    value = re.sub(r"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[=:]\s*)[^\s,\"}]+", r"\1[REDACTED]", value)
    value = re.sub(r"(?:sk-[A-Za-z0-9_-]{12,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)", "[REDACTED]", value)
    value = re.sub(r"aim[^\s:]*://[^\s\"<>]+", "[PRIVATE INVITATION]", value, flags=re.I)
    return value


def macos_test_profile(home):
    # XCTest class discovery can initialize ContactsUICore before any test runs.
    # Deny its real service and local database, while keeping other OS adapters
    # available for explicit synthetic tests (codecs, temporary file operations).
    addressbook = str(Path(home) / "Library/Application Support/AddressBook")
    return ('(version 1)\n(allow default)\n'
        '(deny mach-lookup (global-name "com.apple.contactsd") (global-name "com.apple.contactsd.persistence"))\n'
        '(deny file-read* file-write* (subpath ' + json.dumps(addressbook) + '))\n')


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("x") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    temporary.replace(path)


@contextmanager
def resource_lock(name):
    path = Path(tempfile.gettempdir()) / ("aim-qa-" + hashlib.sha256(name.encode()).hexdigest()[:24] + ".lock")
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def aggregate(steps):
    statuses = {step["status"] for step in steps}
    if FAIL in statuses:
        return FAIL
    if BLOCKED in statuses or NOT_RUN in statuses or not steps:
        return BLOCKED
    return PASS


def classify(returncode, output, timed_out=False, tests=False):
    executed_failure = re.search(
        r"(?:with|and) [1-9]\d* failures?|Test run with \d+ tests.*failed|"
        r"Test Case .+ failed|(?:XCTAssert\w*|XCTFail).*failed|AssertionError|assertion failed",
        output, re.I)
    if executed_failure:
        return FAIL, "Échec de test/assertion exécuté ; les diagnostics réseau éventuels ne sont pas un prérequis manquant."
    # Known infrastructure refusals are not app failures. Everything else with
    # an executed test failure remains an observed failure, including a timeout.
    infrastructure = ("device is locked", "CoreDeviceError", "Unable to locate device set",
        "Failed to initialize simulator device set", "Unable to find a destination",
        "No signing certificate", "No profiles for", "Operation not permitted",
        "could not find module", "Failed to clone repository", "network is unreachable")
    execution_started = bool(re.search(r"Test Case .+ started|Executed [1-9]\d* tests?|Test run with [1-9]\d* tests", output))
    if returncode and not timed_out and not execution_started and any(item.lower() in output.lower() for item in infrastructure):
        return BLOCKED, "Prérequis outil/appareil/réseau indisponible ; consulter le journal expurgé."
    if timed_out:
        return FAIL, "Délai dépassé pendant une opération démarrée ; résultat incomplet conservé."
    if returncode:
        return FAIL, "La commande a échoué ; consulter le journal expurgé."
    if tests:
        if re.search(r"(?:with|and) [1-9]\d* failures?|Test run with \d+ tests.*failed", output):
            return FAIL, "Le journal indique des tests en échec malgré le code de sortie."
        counts = [int(total) - int(skipped or 0) for total, skipped in
            re.findall(r"Executed\s+(\d+)\s+tests?(?:, with (\d+) tests? skipped)?", output)]
        counts += [int(n) for n in re.findall(r"Test run with (\d+) tests", output)]
        if not counts or max(counts) <= 0:
            return BLOCKED, "Aucune exécution de test prouvée ; un code de sortie 0 ne suffit pas."
    return PASS, "Commande terminée et résultat contrôlé."


class Run:
    def __init__(self, args):
        self.args = args
        self.id = uuid.uuid4().hex
        self.started = time.monotonic()
        self.deadline = self.started + args.minutes * 60
        self.output = Path(args.report_dir).expanduser().absolute() if args.report_dir else ROOT / "build/qa-runs" / self.id
        # An existing report must never be overwritten or reused as fresh proof.
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        os.chmod(self.output, 0o700)
        self.home = self.output / "home"
        self.home.mkdir(mode=0o700)
        self.environment = dict(os.environ, CFFIXED_USER_HOME=str(self.home),
            AIM_TEST_INSTALLATION_ID=self.id, MOBILEBUILDMCP_SENTRY_DISABLED="true",
            CLANG_MODULE_CACHE_PATH=str(ROOT / "build/qa-cache/modules"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(ROOT / "build/qa-cache/modules"))
        self.report = {"schema": 1, "run_id": self.id, "started_at": now(), "suite": args.suite,
            "target": args.target, "dry_run": args.dry_run, "steps": [], "artifacts": [],
            "publication_qualified": False, "owner_gate_modified": False,
            "metrics": {"human_minutes": args.human_minutes, "approval_interruptions": args.interruptions,
                        "reproduction_to_verification_seconds": None},
            "limits": {"minutes": args.minutes, "maximum_correction_attempts": 3, "paid_calls": False},
            "source": self.source_identity(), "binaries": [], "environment": {"platform": sys.platform}}

    def source_identity(self):
        def git(*arguments):
            result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, timeout=15)
            return result.stdout
        # Include dirty and untracked source bytes, not merely HEAD. Never copy
        # their contents into evidence. Read only source/config/test inputs.
        paths = sorted(set(git("ls-files", "-co", "--exclude-standard", "-z").decode().split("\0")) - {""})
        manifest = hashlib.sha256()
        for relative in paths:
            path = ROOT / relative
            if path.suffix not in {".swift", ".py", ".sh", ".plist", ".json", ".yml", ".yaml", ".pbxproj", ".xcconfig", ".md", ".resolved", ".cpp", ".c", ".h", ".mm", ".m", ".toml"}:
                continue
            if path.is_file() and not path.is_symlink():
                manifest.update(relative.encode() + b"\0" + hashlib.sha256(path.read_bytes()).digest())
        return {"head": git("rev-parse", "HEAD").decode().strip(),
            "dirty": bool(git("status", "--porcelain")), "inputs_sha256": manifest.hexdigest()}

    def checkpoint(self):
        self.report["status"] = aggregate(self.report["steps"])
        self.report["duration_seconds"] = round(time.monotonic() - self.started, 3)
        # Keep reproduction-to-verification unknown until its actual start has
        # been observed; command duration is not a substitute for human latency.
        atomic_json(self.output / "report.json", self.report)
        lines = ["# AIM — qualification", "", f"Run : `{self.id}` — {self.report['status']}",
            "", "Ces résultats sont des preuves de support. Aucun contrôle propriétaire ni publication n'est validé automatiquement.",
            "", "| Étape | Niveau | Statut | Résultat / prochaine action |", "|---|---|---|---|"]
        for step in self.report["steps"]:
            message = step["observed"].replace("|", "/").replace("\n", " ")
            lines.append(f"| {step['id']} | {step['evidence_level']} | {step['status']} | {message} |")
        (self.output / "report.md").write_text("\n".join(lines) + "\n")
        os.chmod(self.output / "report.md", 0o600)

    def note(self, name, message, status=BLOCKED, level="preflight", controls=()):
        self.report["steps"].append({"id": name, "status": status, "evidence_level": level,
            "controls": list(controls), "expected": "Prérequis et preuve du scénario disponibles", "observed": message,
            "duration_seconds": 0, "artifacts": []})
        self.checkpoint()

    def command(self, name, command, level, controls=(), timeout=900, tests=False, env=None, preparation_exit_codes=(), cleanup_group=False):
        step = {"id": name, "controls": list(controls), "command": command, "evidence_level": level,
                "expected": "Exécution complète sans échec" + (" et tests non vides" if tests else ""), "artifacts": []}
        if self.args.dry_run:
            step.update(status=NOT_RUN, observed="Prévisualisation uniquement ; aucune commande exécutée.", duration_seconds=0)
            self.report["steps"].append(step)
            self.checkpoint()
            return False
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            self.note(name, "Créneau de qualification expiré. Reprendre dans un nouveau créneau.", controls=controls)
            return False
        started = time.monotonic()
        log = self.output / (re.sub(r"[^a-zA-Z0-9_-]", "-", name) + ".log")
        private = tempfile.TemporaryFile()
        process = None
        expired = False
        try:
            process = subprocess.Popen(command, cwd=ROOT, env=env or self.environment,
                stdout=private, stderr=subprocess.STDOUT, start_new_session=True)
            command_deadline = time.monotonic() + min(timeout, remaining)
            try:
                while True:
                    left = command_deadline - time.monotonic()
                    if left <= 0:
                        raise subprocess.TimeoutExpired(command, timeout)
                    try:
                        code = process.wait(timeout=min(2, left))
                        break
                    except subprocess.TimeoutExpired:
                        # pread does not move the file offset shared with the
                        # child. Expose current sanitized progress to the agent.
                        size = os.fstat(private.fileno()).st_size
                        snapshot = os.pread(private.fileno(), size, 0).decode(errors="replace")
                        log.write_text(redact(snapshot))
                        os.chmod(log, 0o600)
            except subprocess.TimeoutExpired:
                expired = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = process.returncode
            private.seek(0)
            output = private.read().decode(errors="replace")
            log.write_text(redact(output))
            os.chmod(log, 0o600)
            status, observed = classify(code, output, expired, tests)
            if not expired and code in preparation_exit_codes:
                status, observed = BLOCKED, "Préparation requise ; consulter le rapport du pilote."
            step.update(status=status, observed=observed, exit_code=code,
                prerequisite_missing=status == BLOCKED,
                diagnostics=[name for name, pattern in [("network", r"network is unreachable|connection refused|CoreSimulatorService connection"),
                    ("permission", r"Operation not permitted|not authorized"), ("timeout", r"timed out|timeout")]
                    if re.search(pattern, output, re.I)])
        except OSError as error:
            step.update(status=BLOCKED, observed=f"Outil non disponible : {error.strerror}")
        except BaseException:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise
        finally:
            if cleanup_group and process is not None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            private.close()
        step["duration_seconds"] = round(time.monotonic() - started, 3)
        if log.exists():
            step["artifacts"].append({"path": log.name, "sha256": sha256(log)})
        self.report["steps"].append(step)
        self.checkpoint()
        print(f"{name}: {step['status']}", flush=True)
        return step["status"] == PASS

    def software(self, controls):
        if self.args.controls:
            components = {}
            for control in controls:
                for selector in control["supporting_selectors"]:
                    components.setdefault(selector["package"], set()).update(selector["suites"])
        else:
            components = {"core": {CORE_QUICK if self.args.suite != "release" else ".*"}}
            if self.args.component in {"macos", "all"}:
                components["macos"] = {MAC_QUICK if self.args.suite != "release" else ".*"}
            if self.args.component == "macos":
                components.pop("core", None)
        if not components:
            self.note("no-supporting-test", "Aucune suite de support identifiée pour cette sélection. Suivre les préparations du registre.")
        for component, names in components.items():
            if component == "ios":
                self.note("ios-support", "Ces contrôles nécessitent --target simulator ; aucune preuve iOS produite ici.")
                continue
            package = "packages/AIMCore" if component == "core" else "apps/macos"
            command = ["swift", "test", "--disable-sandbox", "--disable-automatic-resolution", "--package-path", str(ROOT / package),
                "--scratch-path", str(ROOT / f"build/qa-cache/{component}"), "--filter", "|".join(sorted(names))]
            native_cases = [key for key, case in PROCESS_CASES.items() if component == "macos" and (
                self.args.suite == "release" or re.search("|".join(sorted(names)), case["original"]))]
            if native_cases:
                for key in native_cases:
                    command += ["--skip", "^" + re.escape(PROCESS_CASES[key]["original"]) + "$"]
                self.report["process_integration_routing"] = {key: PROCESS_CASES[key]["original"] for key in native_cases}
            if component == "macos" and sys.platform == "darwin":
                profile = self.output / "macos-system-data.sb"
                profile.write_text(macos_test_profile(Path.home()))
                os.chmod(profile, 0o600)
                command = ["sandbox-exec", "-f", str(profile), *command]
                self.report["environment"]["macos_system_data_fence"] = "Contacts service + real AddressBook reads/writes denied; other services not globally isolated"
                self.report["artifacts"].append({"path": profile.name, "sha256": sha256(profile)})
            # Native replacements are mandatory in this same run, with separate counts.
            if native_cases:
                self.process_integrations(native_cases)
            self.command(component + "-tests", command, "software", [c["id"] for c in controls], tests=True)
            log = self.output / (component + "-tests.log")
            if log.exists():
                self.report.setdefault("test_counts", {})[component + "_xctest"] = xctest_bundle_counts(log.read_text())
                self.checkpoint()

    def process_integrations(self, cases=None):
        cases = list(PROCESS_CASES) if cases is None else list(cases)
        if not cases or len(cases) != len(set(cases)) or any(case not in PROCESS_CASES for case in cases):
            self.note("process-integration-selection", "Empty or invalid native case selection.", status=FAIL)
            return
        if sys.platform != "darwin":
            self.note("process-integration-platform", "Native Mac integration requires macOS.")
            return
        build = ROOT / "build/qa-cache/macos"
        if not self.command("process-integration-build", ["swift", "build", "--disable-sandbox", "--disable-automatic-resolution",
                "--package-path", str(ROOT / "apps/macos"), "--scratch-path", str(build),
                "--product", "AIMProcessIntegrationQA"], "build", timeout=900):
            return
        original = build / "debug/AIMProcessIntegrationQA"
        if not original.is_file():
            self.note("process-integration-binary", "Current helper binary absent.", status=FAIL)
            return
        if self.source_identity()["inputs_sha256"] != self.report["source"]["inputs_sha256"]:
            self.note("process-integration-source-drift", "Source changed during helper build.", status=FAIL)
            return
        source_sha = self.report["source"]["inputs_sha256"]
        count = 0
        case_base = self.output / self.id
        case_base.mkdir(mode=0o700)
        for case in cases:
            root = case_base / case
            home = root / "home"
            home.mkdir(parents=True, mode=0o700)
            temporary = root / "tmp"; temporary.mkdir(mode=0o700)
            installation = uuid.uuid4().hex
            namespace = "com.aimai.macos.qualification." + installation
            app = root / "AIMProcessIntegrationQA.app"
            executable = app / "Contents/MacOS/AIMProcessIntegrationQA"
            executable.parent.mkdir(parents=True)
            shutil.copy2(original, executable)
            info = dict(CFBundleIdentifier=namespace, AIMQualificationNamespace=namespace,
                CFBundleExecutable="AIMProcessIntegrationQA", CFBundlePackageType="APPL", CFBundleVersion="1")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            # SwiftPM's framework rpath is relative to its build directory.
            if not self.command("process-" + case + "-rpath", ["install_name_tool", "-add_rpath", str(original.parent.resolve()), str(executable)], "build"):
                continue
            if not self.command("process-" + case + "-sign", ["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], "build"):
                continue
            if not self.command("process-" + case + "-signature", ["codesign", "--verify", "--deep", "--strict", str(app)], "build"):
                continue
            binary_sha = sha256(executable)
            self.report["binaries"].append({"role": "process-integration-" + case, "executable_sha256": binary_sha,
                "source_inputs_sha256": source_sha, "bundle_id": namespace, "built_in_run": self.id})
            receipt = root / "receipt.json"
            # Stock LanguageServerClient inherits this strict synthetic environment.
            env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "CFFIXED_USER_HOME": str(home),
                "TMPDIR": str(temporary), "OBJC_PRINT_INITIALIZE_METHODS": "YES",
                "CLANG_MODULE_CACHE_PATH": str(root / "module-cache"),
                "SWIFTPM_MODULECACHE_OVERRIDE": str(root / "module-cache")}
            start = time.time()
            ok = self.command("process-integration-" + case, [str(executable), "--case", case, "--run-id", self.id,
                "--installation-id", installation, "--source-sha256", source_sha, "--root", str(root),
                "--receipt", str(receipt)], "native-process-integration", timeout=180, env=env, cleanup_group=True)
            finish = time.time()
            log = self.output / ("process-integration-" + case + ".log")
            # A loaded framework alone does not prove class initialization. The
            # runtime trace starts before main, including class initializers.
            try:
                trace_count = validate_initialization_trace(log.read_text())
            except (OSError, ValueError):
                self.note("process-integration-initialization-trace", "Missing runtime trace or unexpected Contacts/XCTest initialization; stopped native cases.", status=FAIL)
                return
            self.report.setdefault("process_initialization_observation", {})[case] = {
                "objc_initializers_observed": trace_count, "contacts_or_xctest_initialization_observed": False,
                "loaded_frameworks_are_not_initialization_evidence": True}
            try:
                value = validate_process_receipt(receipt, case, self.id, source_sha, binary_sha, namespace, start, finish)
                if not ok:
                    raise ValueError("Native process failed despite receipt")
                if sha256(executable) != binary_sha or self.source_identity()["inputs_sha256"] != source_sha:
                    raise ValueError("Source or binary drift")
            except (OSError, ValueError, KeyError, TypeError):
                self.note("process-" + case + "-receipt", "Missing, stale, failed or inconsistent native receipt; no replacement accepted.", status=FAIL)
                continue
            count += 1
            self.report["artifacts"].append({"path": str(receipt.relative_to(self.output)), "sha256": sha256(receipt)})
            self.report.setdefault("test_counts", {})["native_cases_passed"] = count
            self.report["test_counts"]["native_checks_passed"] = count * 6
            self.note("process-" + case + "-receipt", "Native case and six named checks verified for this source/binary/run; " + value["originalTest"], status=PASS, level="native-process-integration")
        self.report.setdefault("test_counts", {})["native_cases_required"] = len(cases)
        if count != len(cases):
            self.note("process-integration-coverage", "Mandatory native replacement case missing or failed.", status=FAIL)

    def simulator(self):
        # Never erase/reset a simulator or implicitly use the owner's existing one.
        simulator = self.args.simulator
        if not simulator:
            if self.args.dry_run:
                simulator = "<isolated-simulator>"
            else:
                try:
                    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"], stderr=subprocess.PIPE, timeout=30))
                    available = [d for devices in inventory["devices"].values() for d in devices
                        if d.get("isAvailable") and d["name"] == "AIM QA Autonomy"]
                    if available:
                        simulator = available[0]["udid"]
                    else:
                        runtimes = sorted([r for r in inventory["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]], key=lambda r: tuple(map(int, r["version"].split("."))))
                        phone = next(d for d in inventory["devicetypes"] if d["name"] == "iPhone 17 Pro")
                        simulator = subprocess.check_output(["xcrun", "simctl", "create", "AIM QA Autonomy", phone["identifier"], runtimes[-1]["identifier"]], stderr=subprocess.PIPE, text=True, timeout=60).strip()
                except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, StopIteration):
                    self.note("simulator-preflight", "CoreSimulator inaccessible ou runtime absent. Autoriser l'accès à CoreSimulator puis relancer ; aucun appareil existant réinitialisé.")
                    return
        if not re.fullmatch(r"[A-Fa-f0-9-]{36}|<isolated-simulator>", simulator):
            self.note("simulator-preflight", "Identifiant simulateur invalide.")
            return
        self.report["environment"]["simulator"] = simulator
        command = ["xcodebuild", "test", "-project", str(ROOT / "apps/ios/AIM.xcodeproj"), "-scheme", "AIM",
            "-destination", "platform=iOS Simulator,id=" + simulator,
            "-derivedDataPath", str(ROOT / "build/qa-cache/ios"), "-resultBundlePath", str(self.output / "ios.xcresult"),
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "120", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=",
            "AIM_APP_BUNDLE_IDENTIFIER=com.aimai.ios.qa.autonomy"]
        selected_tests = (self.args.ios_test_filter or ["AIMTests"]) if self.args.ios_tests == "unit" else UI_TESTS
        for test in selected_tests:
            command += ["-only-testing:" + test]
        self.command("ios-" + self.args.ios_tests, command, "simulator", ["P01"] if self.args.ios_tests == "unit" else ["D05", "D06", "D08", "L07"], timeout=1800, tests=True)
        self.capture_binaries(ROOT / "build/qa-cache/ios/Build/Products/Debug-iphonesimulator/AIM.app")
        if (self.output / "ios.xcresult").exists():
            self.report["artifacts"].append({"path": "ios.xcresult", "kind": "xcresult-directory"})

    def capture_binaries(self, app):
        info_path = app / "Info.plist"
        executable_root = app
        if not info_path.exists():
            info_path = app / "Contents/Info.plist"
            executable_root = app / "Contents/MacOS"
        if info_path.exists():
            info = plistlib.loads(info_path.read_bytes())
            binary = executable_root / info["CFBundleExecutable"]
            if binary.exists():
                self.report["binaries"].append({"bundle_id": info.get("CFBundleIdentifier"),
                    "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
                    "executable_sha256": sha256(binary)})

    def native(self):
        if not self.args.probe or not Path(self.args.probe).is_file():
            self.note("native-preflight", "Fournir --probe avec une sonde de qualification reconstruite depuis les sources actuelles. Voir scripts/direct/build-swift-probe.py.")
            return
        probe = Path(self.args.probe).resolve()
        direct = direct_qualification()
        try:
            provenance = direct.build.verify_probe(probe)
        except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
            self.note("native-identity", "Sonde QA isolée et provenance complète des sources/binaires courants requises. Aucun processus lancé.")
            return
        source_sha, binary_sha = provenance["sourceSHA256"], provenance["binarySHA256"]
        namespace = provenance["namespace"]
        self.report["binaries"].append({"role": "supplied-native-probe", "executable_sha256": binary_sha,
            "source_provenance_verified": True, "source_sha256": source_sha, "namespace": namespace})
        for scenario, flags in [("lifecycle", ["--lifecycle"]), ("permissions", ["--permission-edit"])]:
            receipt = self.output / (scenario + ".json")
            started = time.time()
            if self.command("native-" + scenario, [sys.executable, str(ROOT / "scripts/direct/qualify-controller.py"),
                "--probe", str(probe), "--receipt", str(receipt), "--run-id", self.id, *flags],
                "native-process-integration", ["L03", "L04", "R01", "R03"], timeout=240,
                preparation_exit_codes=(2,), cleanup_group=True):
                try:
                    direct.build.verify_probe(probe)
                    direct.validate_receipt(receipt, scenario, self.id, source_sha, binary_sha, namespace, started, time.time())
                except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
                    self.note("native-" + scenario + "-receipt", "Reçu Direct absent, ancien, incohérent ou incomplet ; aucune preuve acceptée.", status=FAIL)
                    continue
                self.report["artifacts"].append({"path": receipt.name, "sha256": sha256(receipt)})
                self.note("native-" + scenario + "-receipt", "Contrat Direct vérifié pour ce scénario/run/source/binaire ; apps et appareils exclus.", status=PASS, level="native-process-integration")

    def device(self):
        if not self.args.session or not self.args.device_test_run:
            self.note("physical-session", "Fournir un créneau réel --session et une définition signée --device-test-run pour une nouvelle app iOS .qa. Aucun accès aux apps installées sans cette préparation.")
            return
        from session import validate
        try:
            session = validate(json.loads(Path(self.args.session).read_text()))
            if not {"install", "launch", "control", "close"} <= set(session["allowed_actions"]):
                raise ValueError("Créneau sans installation/lancement/contrôle")
            if not session["ios_bundle_id"].startswith("com.aimai.ios.qa."):
                raise ValueError("Le pilote physique utilise une nouvelle app .qa. ; l'app existante attend la procédure de sauvegarde")
            definition = Path(self.args.device_test_run).resolve()
            value = plistlib.loads(definition.read_bytes())
            targets = []
            def collect(item):
                if isinstance(item, dict):
                    if item.get("BlueprintName") == "AIMUITests":
                        targets.append(item)
                    for child in item.values():
                        collect(child)
                elif isinstance(item, list):
                    for child in item:
                        collect(child)
            collect(value)
            if len(targets) != 1:
                raise ValueError("Cible UI absente ou ambiguë")
            target = targets[0]
            app = Path(target["UITargetAppPath"].replace("__TESTROOT__", str(definition.parent)))
            info = plistlib.loads((app / "Info.plist").read_bytes())
            if info["CFBundleIdentifier"] != session["ios_bundle_id"] or "iphonesimulator" in str(app).lower():
                raise ValueError("Identité ou plateforme du candidat non conforme au créneau")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True, timeout=30)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            self.note("physical-preflight", "Créneau, signature, identité ou définition physique invalide. Préparer une app .qa. distincte et signée, sans remplacer la paire existante.")
            return
        if self.args.dry_run:
            self.note("physical-preview", "Prévisualisation : aucune interrogation ni installation sur l'iPhone.", status=NOT_RUN)
            return
        inventory = self.output / "device-inventory.private.json"
        try:
            subprocess.run(["xcrun", "devicectl", "device", "info", "apps", "--device", session["device_id"],
                "--json-output", str(inventory)], check=True, capture_output=True, timeout=30)
            apps = json.loads(inventory.read_text()).get("result", {}).get("apps")
            if not isinstance(apps, list):
                raise ValueError("Inventaire non attesté")
            if any(a.get("bundleIdentifier") == session["ios_bundle_id"] for a in apps):
                self.note("existing-physical-app", "Cette app QA existe déjà. Préparer une nouvelle identité ou utiliser la procédure propriétaire de sauvegarde ; aucune mise à jour automatique.")
                return
            validate(session)  # expiry immediately before the installation/test
        except (OSError, ValueError, subprocess.SubprocessError):
            self.note("physical-device-unavailable", "iPhone indisponible/verrouillé ou inventaire incomplet. Déverrouiller et vérifier la confiance, puis reprendre sans réinitialiser.")
            return
        target.setdefault("EnvironmentVariables", {})["AIM_QA_PHYSICAL_SCANNER"] = "1"
        private_definition = definition.with_name("aim-qa-physical-" + self.id + ".xctestrun")
        private_definition.write_bytes(plistlib.dumps(value))
        os.chmod(private_definition, 0o600)
        try:
            self.deadline = min(self.deadline, time.monotonic() + max(0,
                (datetime.fromisoformat(session["expires_at"]) - datetime.now(timezone.utc)).total_seconds()))
            self.command("physical-scanner", ["xcodebuild", "test-without-building", "-xctestrun", str(private_definition),
                "-destination", "platform=iOS,id=" + session["device_id"], "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180",
                "-resultBundlePath", str(self.output / "physical-scanner.xcresult"),
                "-only-testing:AIMUITests/AIMPhysicalScannerUITests/testRealScannerTenOpenCloseCyclesAndForegroundReturn"],
                "physical-device", ["D04"], timeout=240, tests=True)
            self.capture_binaries(app)
            self.note("physical-camera-stop-observation", "Les cycles/UI sont distincts de la preuve d'arrêt caméra : vérifier ses diagnostics ou l'indicateur physique. Aucun nouveau QR scanné.", controls=["D04"])
        finally:
            private_definition.unlink(missing_ok=True)

    def execute(self):
        controls = registry()["controls"]
        selected = set(self.args.controls.split(",")) if self.args.controls else set()
        unknown = selected - {c["id"] for c in controls}
        if unknown:
            self.note("selection", "Contrôles inconnus : " + ", ".join(sorted(unknown)), status=FAIL)
            return
        if selected:
            controls = [c for c in controls if c["id"] in selected]
        self.report["requested_controls"] = [c["id"] for c in controls] if selected or self.args.suite == "release" else []
        if not REGISTRY.exists() or REGISTRY.read_text() != render(registry()):
            self.note("registry", "Registre modifié depuis sa génération. Revoir les correspondances puis exécuter catalog.py.")
            return
        if self.args.target == "software":
            self.software(controls if selected else [])
        elif self.args.target == "simulator":
            self.simulator()
        elif self.args.target == "native":
            self.native()
        elif self.args.target == "apps":
            self.command("app-pilot", [sys.executable, str(ROOT / "scripts/qa/app_pilot.py"),
                "--report-dir", str(self.output / "app-pilot"), *(["--prepare-only"] if self.args.prepare_only else [])], "simulator-app-integration", timeout=2700, preparation_exit_codes=(2,))
            child = self.output / "app-pilot/report.json"
            if child.is_file():
                result = json.loads(child.read_text())
                self.report["steps"][-1]["status"] = result["status"]
                self.report["steps"][-1]["observed"] = "Voir le rapport du pilote : " + result["status"]
                self.report["artifacts"].append({"path": "app-pilot/report.json", "sha256": sha256(child)})
        else:
            self.device()
        if self.args.suite in {"smoke", "remote"} and self.args.target not in {"apps", "device"}:
            self.note("app-pilot-required", "Ces tests de support ne traversent pas les deux apps. Exécuter --target apps ; les appareils physiques restent distincts.")
        if self.args.suite == "release":
            self.note("owner-release-gate", "Revue des 71 contrôles et preuves sur les binaires finaux requise. Aucune publication autorisée par ce résultat.", controls=[c["id"] for c in controls])
        if self.source_identity()["inputs_sha256"] != self.report["source"]["inputs_sha256"]:
            self.note("source-drift", "Sources modifiées pendant les essais. Rejouer les vérifications concernées sur un état stable.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["quick", "smoke", "remote", "release"], default="quick")
    parser.add_argument("--target", choices=["software", "simulator", "native", "apps", "device"], default="software")
    parser.add_argument("--component", choices=["core", "macos", "all"], default="core")
    parser.add_argument("--controls", default="", help="Comma-separated owner IDs; supporting tests only")
    parser.add_argument("--report-dir")
    parser.add_argument("--ios-test-filter", action="append", default=[], help="Targeted unit selector, must start with AIMTests/")
    parser.add_argument("--ios-tests", choices=["ui", "unit"], default="ui", help="Explicit iPhone test target; unit executes AIMTests, UI does not")
    parser.add_argument("--simulator", help="Explicit simulator UUID; default is separate AIM QA Autonomy")
    parser.add_argument("--probe", help="Explicit native qualification probe; never the AIM app executable")
    parser.add_argument("--session", help="Recorded current owner authorization for physical testing")
    parser.add_argument("--device-test-run", help="Prebuilt signed physical xctestrun; separate new .qa. installation only")
    parser.add_argument("--minutes", type=int, default=45)
    parser.add_argument("--human-minutes", type=float, default=None, help="Observed time only; null until measured")
    parser.add_argument("--interruptions", type=int, default=None, help="Observed count only; null until measured")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--prepare-only", action="store_true", help="For --target apps, build without launching the Mac pilot")
    args = parser.parse_args(argv)
    if args.ios_test_filter and (args.ios_tests != "unit" or any(not s.startswith("AIMTests/") for s in args.ios_test_filter)):
        parser.error("Unit filters must use --ios-tests unit and AIMTests/ selectors")
    if not 1 <= args.minutes <= 45:
        parser.error("Session duration must be between 1 and 45 minutes")
    run = Run(args)
    try:
        with resource_lock("aim-qa-build-cache" if args.target in {"software", "simulator"} else "aim-qa-" + args.target):
            run.execute()
    except BlockingIOError:
        run.note("resource-busy", "Une qualification utilise déjà cette cible. Reprendre après sa fin.")
    except KeyboardInterrupt:
        run.note("interrupted", "Qualification interrompue ; aucune réussite déduite.")
    except Exception as error:
        run.note("runner-error", "Erreur du lanceur : " + type(error).__name__ + ". Examiner les prérequis ; résultat non certifié.", status=FAIL)
    run.report["finished_at"] = now()
    run.checkpoint()
    print(run.output / "report.md")
    return 0 if run.report["status"] == PASS else 1 if run.report["status"] == FAIL else 2


if __name__ == "__main__":
    sys.exit(main())
