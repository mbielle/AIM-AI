#!/usr/bin/env python3
"""Drive a fresh debug Mac app and an isolated iOS Simulator app through real RPC.

Never launches/replaces an installed owner app. Mac pairing confirmation is a
real button click in the newly created process, via Accessibility or the agent.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import time

from run import Run, PASS, FAIL, BLOCKED, aggregate, atomic_json, resource_lock
from catalog import ROOT


def create_mac_bundle(run, binary):
    app = run.output / "AIM QA Host.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    frameworks = contents / "Frameworks"
    frameworks.mkdir()
    shutil.copy2(binary, contents / "MacOS/AIMMac")
    for item in binary.parent.glob("*.bundle"):
        shutil.copytree(item, resources / item.name)
    for item in binary.parent.glob("*.dylib"):
        shutil.copy2(item, frameworks / item.name)
    # SwiftPM's Sparkle binary is not always next to the executable.
    for item in (ROOT / "build/qa-cache/macos/artifacts").rglob("Sparkle.framework"):
        shutil.copytree(item, frameworks / item.name, symlinks=True)
        break
    if not (frameworks / "Sparkle.framework").is_dir():
        run.note("host-framework", "Sparkle absent du bundle QA.", status=FAIL)
        return None
    executable = contents / "MacOS/AIMMac"
    loads = subprocess.check_output(["otool", "-l", str(executable)], text=True, timeout=30)
    if "path @executable_path/../Frameworks (offset" not in loads:
        if not run.command("host-framework-rpath", ["install_name_tool", "-add_rpath",
            "@executable_path/../Frameworks", str(executable)], "build-only", timeout=30):
            return None
    info = plistlib.loads((ROOT / "apps/macos/Config/Info.plist").read_bytes())
    namespace = "com.aimai.macos.qualification." + run.id
    info.update(CFBundleIdentifier=namespace, AIMQualificationNamespace=namespace,
        CFBundleExecutable="AIMMac", CFBundleName="AIM QA Host", CFBundleDisplayName="AIM QA Host",
        CFBundleVersion="1", CFBundleShortVersionString="0.1.0", CFBundlePackageType="APPL",
        AIMSupabaseURL="", AIMSupabasePublicKey="", SUEnableAutomaticChecks=False)
    # The pilot never starts model.start(), the embedded helper, Sparkle or cloud.
    for key in ["SMPrivilegedExecutables", "SUFeedURL", "SUPublicEDKey", "CFBundleURLTypes"]:
        info.pop(key, None)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    if not run.command("sign-isolated-host", ["codesign", "--force", "--deep", "--sign", "-", str(app)], "build-only", timeout=60):
        return None
    if not run.command("verify-isolated-host", ["codesign", "--verify", "--deep", "--strict", str(app)], "build-only", timeout=30):
        return None
    run.capture_binaries(app)
    return app


def simulator(run, explicit=None):
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"], stderr=subprocess.PIPE, timeout=30))
    devices = [d for group in inventory["devices"].values() for d in group if d.get("isAvailable")]
    if explicit:
        selected = next((d for d in devices if d["udid"] == explicit and d["name"].startswith("AIM QA")), None)
        if not selected:
            raise ValueError("Only a separate AIM QA simulator is admitted")
        return selected["udid"]
    existing = next((d for d in devices if d["name"] == "AIM QA App Pilot"), None)
    if existing:
        return existing["udid"]
    runtimes = sorted([r for r in inventory["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]], key=lambda r: tuple(map(int, r["version"].split("."))))
    phone = next(d for d in inventory["devicetypes"] if d["name"] == "iPhone 17 Pro")
    return subprocess.check_output(["xcrun", "simctl", "create", "AIM QA App Pilot", phone["identifier"], runtimes[-1]["identifier"]], stderr=subprocess.PIPE, text=True, timeout=60).strip()


def inject_test_environment(value, environment):
    count = 0
    if isinstance(value, dict):
        # The modern format and older dictionary format both identify the UI
        # target. Restrict injected secrets to that private test-run definition.
        if value.get("BlueprintName") == "AIMUITests" or value.get("ProductModuleName") == "AIMUITests":
            value.setdefault("EnvironmentVariables", {}).update(environment)
            count += 1
        for child in value.values():
            count += inject_test_environment(child, environment)
    elif isinstance(value, list):
        for child in value:
            count += inject_test_environment(child, environment)
    return count


def collect_client_receipt(run, device):
    # Read one known receipt from the isolated simulator app, never its keys,
    # profiles, invitation or entire container. Validate the run before copying.
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True, stderr=subprocess.PIPE, timeout=30))
    selected = next((d for group in inventory["devices"].values() for d in group if d["udid"] == device and d["name"].startswith("AIM QA")), None)
    if selected is None:
        raise ValueError("Receipt requires the isolated QA simulator")
    if selected["state"] == "Shutdown":
        subprocess.run(["xcrun", "simctl", "boot", device], check=True, capture_output=True, timeout=30)
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, capture_output=True, timeout=90)
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device,
        "com.aimai.ios.qa.pilot", "data"], text=True, stderr=subprocess.PIPE, timeout=30).strip())
    if not container.is_absolute():
        raise ValueError("Invalid QA container")
    source = container / "Library/Application Support/AIM-QA" / run.id / "client-result.json"
    value = json.loads(source.read_text())
    if value.get("run_id") != run.id:
        raise ValueError("Stale QA receipt")
    allowed = {"run_id", "status", "read_matches", "catalog_matches", "models_sha256", "pair_id",
        "execution_device", "stage", "physical_devices_qualified", "real_inference_qualified", "observed_transport"}
    if set(value) - allowed:
        raise ValueError("Unexpected receipt fields")
    atomic_json(run.output / "client-result.json", value)
    return value


def pilot(run, args):
    products = ROOT / "build/qa-cache/macos"
    if not run.command("build-isolated-mac", ["swift", "build", "--disable-sandbox", "--package-path", str(ROOT / "apps/macos"),
        "--scratch-path", str(products), "--product", "AIMMac"], "build-only", timeout=1200):
        return
    binary = products / "debug/AIMMac"
    if not binary.is_file():
        run.note("mac-product", "Produit Mac absent ou ambigu après compilation.")
        return
    app = create_mac_bundle(run, binary.resolve())
    if not app:
        return
    try:
        device = simulator(run, args.simulator)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, StopIteration, IndexError):
        run.note("simulator", "Runtime ou simulateur isolé indisponible. Aucun simulateur existant effacé.")
        return
    run.report["environment"]["simulator"] = device
    derived = ROOT / "build/qa-cache/ios-pilot"
    build = ["xcodebuild", "build-for-testing", "-project", str(ROOT / "apps/ios/AIM.xcodeproj"), "-scheme", "AIM",
        "-destination", "platform=iOS Simulator,id=" + device, "-derivedDataPath", str(derived),
        "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=", "AIM_APP_BUNDLE_IDENTIFIER=com.aimai.ios.qa.pilot"]
    if not run.command("build-isolated-ios", build, "build-only", timeout=1200):
        return
    run.capture_binaries(derived / "Build/Products/Debug-iphonesimulator/AIM.app")
    if args.prepare_only:
        run.note("app-session-deferred", "Binaires préparés. Lancement Mac et contrôle UI différés jusqu'à disponibilité du créneau propriétaire.")
        return
    # Fresh Mac namespace, in-memory DB, no installed application or Keychain.
    host_environment = dict(run.environment, AIM_QA_RUN_ID=run.id, AIM_QA_DIRECTORY=str(run.output))
    private_log = (run.output / "host.private.log").open("x")
    os.chmod(private_log.name, 0o600)
    host = subprocess.Popen([str(app / "Contents/MacOS/AIMMac")], cwd=run.output,
        env=host_environment, stdout=private_log, stderr=subprocess.STDOUT)
    try:
        ready_file = run.output / "host-ready.json"
        until = min(time.monotonic() + 40, run.deadline)
        while time.monotonic() < until and host.poll() is None and not ready_file.exists():
            time.sleep(.2)
        if not ready_file.exists() or json.loads(ready_file.read_text()).get("status") != "ready":
            run.note("host-ready", "Le nouvel hôte n'a pas préparé sa session ; consulter le journal privé local, sans le partager.")
            return
        ready = json.loads(ready_file.read_text())
        invitation = (run.output / "invite.private").read_text()
        definition = next((p for p in (derived / "Build/Products").glob("*.xctestrun") if not p.name.startswith("aim-qa-")), None)
        if definition is None:
            run.note("test-definition", "Définition xctestrun absente.")
            return
        definition_value = plistlib.loads(definition.read_bytes())
        injected = inject_test_environment(definition_value, {"AIM_QA_RUN_ID": run.id,
            "AIM_QA_INVITE": invitation, "AIM_QA_EXPECTED_CATALOG": ready["models_sha256"]})
        if injected == 0:
            run.note("test-definition", "Cible UI introuvable ; aucune invitation injectée dans une autre cible.")
            return
        # __TESTROOT__ depends on the xctestrun location. Keep the original
        # location, but a distinct private filename; never modify shared input.
        private_definition = definition.with_name("aim-qa-" + run.id + ".xctestrun")
        private_definition.write_bytes(plistlib.dumps(definition_value))
        os.chmod(private_definition, 0o600)
        run.note("mac-driver-prepared", "Agent CUA : appuyer sur Confirm QA iPhone dans le seul nouvel hôte QA, PID " + str(host.pid) + ".", status=PASS, level="driver-preparation")
        try:
            for iteration in range(1, args.iterations + 1):
                test = "AIMUITests/AIMQAPilotUITests/testReadCatalogAndReconnectAcrossLaunches"
                if not run.command(f"app-pass-{iteration}", ["xcodebuild", "test-without-building", "-xctestrun", str(private_definition),
                    "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
                    "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180",
                    "-resultBundlePath", str(run.output / f"app-pass-{iteration}.xcresult"), "-only-testing:" + test],
                    "simulator-app-integration", ["L01", "L02", "D05", "R03"], timeout=240, tests=True):
                    return
                collect_client_receipt(run, device)
                client = run.output / "client-result.json"
                if not client.is_file():
                    run.note("client-receipt", "Passage sans reçu client.", status=FAIL); return
                facts = json.loads(client.read_text())
                if facts.get("status") != "passed" or facts.get("models_sha256") != ready["models_sha256"] or facts.get("read_matches") != "true":
                    run.note("client-receipt", "Le reçu client ne confirme pas lecture/catalogue.", status=FAIL); return
                for name in ["client-result.json", "host-confirmation.json"]:
                    receipt = run.output / name
                    if receipt.is_file():
                        snapshot = run.output / (f"pass-{iteration}-" + name)
                        shutil.copy2(receipt, snapshot)
                        from run import sha256
                        run.report["artifacts"].append({"path": snapshot.name, "sha256": sha256(snapshot)})
            confirmation = run.output / "host-confirmation.json"
            if not confirmation.is_file() or json.loads(confirmation.read_text()).get("status") != "confirmed":
                run.note("mac-confirmation", "Aucune confirmation effective attestée par l'hôte ; préparation/clic seuls insuffisants.", status=FAIL)
                return
            run.note("mac-confirmation", "Confirmation réelle et paire enregistrée par le nouvel hôte QA.", status=PASS, level="simulator-app-integration")
            if not run.command("injected-catalog-fault", ["xcodebuild", "test-without-building", "-xctestrun", str(private_definition),
                "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "120",
                "-resultBundlePath", str(run.output / "injected-fault.xcresult"),
                "-only-testing:AIMUITests/AIMQAPilotUITests/testInjectedCatalogMismatchIsDiagnosed"],
                "simulator-app-integration", ["L02"], timeout=180, tests=True):
                return
            incident = collect_client_receipt(run, device)
            if incident.get("stage") != "catalog" or incident.get("read_matches") != "true" or incident.get("catalog_matches") != "false":
                run.note("incident-receipt", "Le reçu ne diagnostique pas l'incident catalogue attendu.", status=FAIL); return
            from run import sha256
            incident_receipt = run.output / "injected-catalog-receipt.json"
            atomic_json(incident_receipt, incident)
            run.report["artifacts"].append({"path": incident_receipt.name, "sha256": sha256(incident_receipt)})
            run.report["pilot_acceptance"] = {"consecutive_passes": args.iterations,
                "expected_injected_failure": "catalog-mismatch", "diagnosed_by_ui": True,
                "physical_devices_qualified": False, "real_inference_qualified": False,
                "ordinary_connection_ui_qualified": False, "driver": "XCTest + agent CUA confirmation + existing connection stores + actual encrypted RPC"}
        finally:
            private_definition.unlink(missing_ok=True)
    finally:
        if host.poll() is None:
            host.terminate()
            try:
                host.wait(timeout=15)
            except subprocess.TimeoutExpired:
                host.kill(); host.wait()
        private_log.close()
        (run.output / "invite.private").unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-dir")
    parser.add_argument("--simulator")
    parser.add_argument("--iterations", type=int, default=3, choices=[3])
    parser.add_argument("--prepare-only", action="store_true", help="Build only; never launch or control a Mac window")
    args = parser.parse_args()
    def terminate(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    run = Run(argparse.Namespace(report_dir=args.report_dir, suite="smoke", target="apps", dry_run=False,
        minutes=45, human_minutes=None, interruptions=None))
    try:
        with resource_lock("aim-qa-build-cache"), resource_lock("aim-qa-app-pilot"):
            pilot(run, args)
    except BlockingIOError:
        run.note("busy", "Une session utilise déjà le pilote isolé.")
    except KeyboardInterrupt:
        run.note("interrupted", "Pilote interrompu, qualification incomplète.")
    except Exception as error:
        run.note("pilot-error", "Erreur du pilote : " + type(error).__name__ + ". Résultat non certifié.", status=FAIL)
    if "pilot_acceptance" not in run.report:
        run.note("pilot-incomplete", "Les trois passages et le contrôle d'incident ne sont pas tous prouvés.")
    run.checkpoint()
    print(run.output / "report.md")
    return 0 if aggregate(run.report["steps"]) == PASS else 1 if aggregate(run.report["steps"]) == FAIL else 2


if __name__ == "__main__":
    sys.exit(main())
