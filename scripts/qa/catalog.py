"""The owner gate remains authoritative; these are reproducible supporting checks."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "docs/VALIDATION_AVANT_PUBLICATION_FR.md"
RUNBOOK = ROOT / "docs/PARCOURS_TESTS_PROPRIETAIRE_FR.md"
REGISTRY = ROOT / "docs/qa/controls.json"
FOLLOWUP = ROOT / "docs/qa/suivi-2026-10-19.json"

# A scenario can cover only part of a gate. Never promote a supporting test to
# owner acceptance, or silently make an omitted gate non-applicable.
SCENARIOS = {
    "T01": "D03", "T02": "L01 L02 D05", "T03": "D05 R03",
    "T04": "D04 L07", "T05": "L03 L04 L05", "T06": "D06 D07 D08",
    "T07": "D07", "T08": "D08 D09", "T09": "D08 L02", "T10": "D08",
    "T11": "I01 I02 L02", "T12": "I03 I04", "T13": "I05",
    "T14": "I06 I07 I08", "T15": "I09", "T16": "I10 I12",
    "T17": "D06 F05", "T18": "F01 F02 L04", "T19": "R01 R03",
    "T20": "R02", "T21": "R04 R05", "T22": "R07", "T23": "L06 L07 L08 R06",
    "T24": "L09 L10", "T25": "N02 N03", "T26": "N04 N05", "T27": "N06 N07 N08 N09",
}
SUPPLEMENTS = {
    "D01 D02": "Préparation des candidats et conservation",
    "D09 F06": "Profils, synchronisation et imports isolés",
    "I07 I08 F08 F09 F10": "Fixtures de sécurité et de coûts",
    "I11": "Comparaison de recherche avec budgets autorisés",
    "F03": "Contrôle d'applications et navigateur de qualification",
    "F04": "Connecteurs et skills de qualification",
    "F05": "Voix, dictée, médias et génération image",
    "F07": "Serveur Supabase isolé et clients natifs",
    "F11": "Mode privé",
    "N01": "Préparation du service Internet et du devis",
    "P01 P02": "Reproductibilité et CI sur candidat final",
    "P03": "Droits et licences",
    "P04 P05": "Distribution Mac et mise à jour Sparkle",
    "P06": "Distribution iPhone",
    "P07": "Migration répétée hors production",
    "P08 P09": "Guides et preview de publication",
    "P10": "Essai indépendant par une autre personne",
    "G01 G02 G03": "Régression finale et accord de publication",
}

# Names reference real suites; only the relevant paths are expanded into the
# generated register. The absence of a supporting suite is made explicit.
TEST_GROUPS = {
    "D03 D09 F06": "MacLocalProfileStoreTests ProfileScopedCredentialStoreTests AccountChatSyncTests",
    "D04": "AIMUITests",  # physical scanner class is explicit opt-in in this source
    "D05 R03": "DirectRemoteTests DirectConnectionLifecycleTests",
    "D06": "AIMUITests",
    "D07 D08": "ModelCatalogPresentationTests RemoteModelSelectionTests ProjectPresentationTests",
    "L01 L05 L06 L07 L08 L09 L10 R02 R06 F10": "DirectRemoteTests DirectRemoteClientServiceTests DirectRemoteAccessTests",
    "L02": "DirectRemoteClientServiceTests RemoteModelSelectionTests",
    "L03 L04": "DirectRemoteTests DirectRemoteAccessTests DirectRemoteRuntimeAuthorizationTests",
    "I01 I02 I03 I04 I05": "ModelRoutingTests RemoteModelSelectionTests",
    "I06 R01 R05": "DirectRemoteTests DirectRemoteClientServiceTests",
    "I07 I08": "DeviceBudgetAdmissionTests ProjectBudgetTests ExecutionScopedSpendTests",
    "I08": "GlobalSpendLedgerTests UncappedProviderPolicyTests NativeMemoryCaptureTests",
    "I09": "ProjectSourceRetrievalTests ProjectSourceToolTests SourceCitationTests",
    "I10 I11": "HybridResearchConversationTests HybridResearchStoreTests",
    "I12 F09": "StaticSVGIconRendererTests SourceFaviconStoreTests",
    "R04 F03": "RemoteLockRulesTests ToolVisionNavigationTests",
    "R07": "DirectRemoteClientServiceTests RemoteTransferCryptoTests DirectRemoteAccessTests",
    "F01 F02": "DirectRemoteRuntimeAuthorizationTests RuntimeRemoteControlTests",
    "F04": "ConnectorRegistryTests NativeSkillsTests",
    "F05": "ImageGenerationModelTests",
    "F07": "RemoteEnvelopeCryptoTests RemoteSecurityTransportTests",
    "F08": "NativeSkillsTests",
    "F11": "ActivityPrivacyPolicyTests",
}
UI_TESTS = [
    "AIMUITests/AIMUITests/testDirectConnectionUsesFocusedPairingAndKeepsInvalidManualLinkLocal",
    "AIMUITests/AIMUITests/testDirectConnectionFrenchDarkLargeText",
]
CORE_QUICK = "DirectRemoteTests|DirectRemoteClientServiceTests|RemoteObservedActionTests|QAIsolationTests"
MAC_QUICK = "DirectRemoteAccessTests|DirectRemoteRuntimeAuthorizationTests|RemoteModelSelectionTests|ModelCatalogPresentationTests"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def gate_rows():
    rows = []
    for line in GATE.read_text().splitlines():
        match = re.match(r"^\| ([A-Z]\d{2}) \| (.*?) \| (.*?) \|$", line)
        if match:
            rows.append(dict(id=match[1], expected=match[2], owner_status=match[3]))
    if len(rows) != 71 or len({r["id"] for r in rows}) != len(rows):
        raise ValueError("Owner register changed: review mappings, do not drop or invent controls")
    return rows


def registry():
    sources = list((ROOT / "packages/AIMCore/Tests").rglob("*.swift"))
    sources += list((ROOT / "apps/ios/AIMTests").rglob("*.swift"))
    sources += list((ROOT / "apps/macos/Tests").rglob("*.swift"))
    sources += list((ROOT / "apps/ios/AIMUITests").rglob("*.swift"))
    by_name = {}
    for source in sources:
        relative = source.relative_to(ROOT).as_posix()
        by_name.setdefault(source.stem, []).append(relative)
        for name in re.findall(r"(?:class|struct)\s+([A-Za-z0-9_]+)", source.read_text()):
            if relative not in by_name.setdefault(name, []):
                by_name[name].append(relative)
    followups = {c["id"]: c for c in json.loads(FOLLOWUP.read_text())["controls"]}
    if set(followups) != {r["id"] for r in gate_rows()}:
        raise ValueError("Review all 71 follow-up entries")
    controls = []
    for row in gate_rows():
        key = row["id"]
        scenarios = [s for s, ids in SCENARIOS.items() if key in ids.split()]
        prep = [title for ids, title in SUPPLEMENTS.items() if key in ids.split()]
        names = {name for ids, suites in TEST_GROUPS.items() if key in ids.split() for name in suites.split()}
        unknown = names - by_name.keys()
        if unknown:
            raise ValueError("Missing supporting suites: " + ", ".join(sorted(unknown)))
        paths = sorted({p for name in names for p in by_name.get(name, [])})
        required = "physical-device"
        prerequisites = ["Identités et données de qualification isolées", "Versions/binaires et environnement relevés"]
        if key.startswith("I") and key not in {"I07", "I08", "I12"}:
            prerequisites += ["Route/modèle réellement disponible", "Autorisation fournisseur/budget si appel payant"]
        if key.startswith("N"):
            prerequisites += ["N01 préparé", "Deux réseaux réels pour la preuve Internet", "Aucun nouvel hébergement sans devis autorisé"]
        if key.startswith(("P", "G")) or key == "N01":
            required = "owner-review"
            prerequisites += ["Candidat final exact et prérequis du registre propriétaire"]
        if key == "D04":
            prerequisites += ["iPhone physique, caméra autorisée, dix ouvertures/fermetures"]
        commands = []
        for package, prefix in [("core", "packages/AIMCore/"), ("macos", "apps/macos/"), ("ios", "apps/ios/")]:
            suites = sorted({name for name in names if any(p.startswith(prefix) for p in by_name[name])})
            if suites:
                commands.append({"package": package, "suites": suites})
        controls.append({**row, "followup": followups[key], "owner_scenarios": scenarios, "developer_preparations": prep,
            "prerequisites": prerequisites, "supporting_tests": paths,
            "supporting_selectors": commands, "required_acceptance_evidence": required,
            "execution": "assisted-device" if required == "physical-device" else "owner-review",
            "physical_test_selector": "AIMUITests/AIMPhysicalScannerUITests/testRealScannerTenOpenCloseCyclesAndForegroundReturn" if key == "D04" else None,
            "command": f"python3 scripts/qa/run.py --suite quick --target software --controls {key}",
            "missing_evidence": "Le support automatisé ne clôture pas ce contrôle. Exécuter les scénarios/préparations sur le candidat requis et revoir les preuves.",
            "next_action": followups[key]["next_action"]})
    return {"schema": 1, "owner_gate": GATE.relative_to(ROOT).as_posix(),
        "gate_sha256": digest(GATE), "runbook_sha256": digest(RUNBOOK), "followup_sha256": digest(FOLLOWUP),
        "publication_qualified": False, "controls": controls}


def render(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    content = render(registry())
    if args.check:
        if not REGISTRY.exists() or REGISTRY.read_text() != content:
            raise SystemExit("Registry drift: review mappings then run python3 scripts/qa/catalog.py")
        print("71 controls and source references verified")
    else:
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        REGISTRY.write_text(content)
        print("Generated", REGISTRY)
