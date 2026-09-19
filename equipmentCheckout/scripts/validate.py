"""
Validate the Equipment Checkout Extend app before uploading it.

Checks:
  1. Every app file parses as JSON. PMD script blocks contain raw newlines inside
     string literals, which strict JSON forbids but the Workday PMD parser accepts
     (every official Workday sample does it), so those files are parsed in a
     tolerant mode that escapes the newlines first.
  2. Every presentationLabels.<Key> referenced by a page exists in en-US.properties,
     and no label in the properties file is unused.
  3. Every taskReference taskId resolves to a task declared in the .amd.
  4. Every graphQuery queryId resolves to a .graphquery file.
  5. No unreplaced __APPID__ / __APPIDPASCAL__ placeholders remain outside graphQueries.

Run:  python scripts/validate.py
"""

import json
import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
PRES = APP / "presentation"
MODEL = APP / "model"

errors = []
warnings = []


def tolerant_json(text):
    """Escape raw newlines/tabs that sit inside JSON string literals."""
    out = []
    in_string = False
    escaped = False
    for ch in text:
        if in_string:
            if escaped:
                out.append(ch)
                escaped = False
                continue
            if ch == "\\":
                out.append(ch)
                escaped = True
                continue
            if ch == '"':
                in_string = False
                out.append(ch)
                continue
            if ch == "\n":
                out.append("\\n")
                continue
            if ch == "\r":
                continue
            if ch == "\t":
                out.append("\\t")
                continue
            out.append(ch)
        else:
            if ch == '"':
                in_string = True
            out.append(ch)
    return "".join(out)


def load(path):
    text = path.read_text(encoding="utf-8")
    try:
        return json.loads(text), "strict"
    except json.JSONDecodeError:
        pass
    try:
        return json.loads(tolerant_json(text)), "tolerant"
    except json.JSONDecodeError as e:
        errors.append(f"{path.relative_to(APP)}: does not parse even tolerantly -> {e}")
        return None, "failed"


# ---------------------------------------------------------------- 1. parse all
app_files = sorted(
    [p for p in APP.rglob("*") if p.is_file() and p.suffix in {
        ".amd", ".smd", ".pmd", ".card", ".graphquery", ".businessobject",
        ".securitydomain", ".task", ".report", ".json", ".businessprocess",
        ".wqlquery", ".orchestration"
    } and "scripts" not in p.parts]
)

parsed = {}
modes = {}
for p in app_files:
    doc, mode = load(p)
    if doc is not None:
        parsed[p] = doc
        modes[p] = mode

# ------------------------------------------------------------- 2. label checks
props = PRES / "presentationLabels" / "en-US.properties"
defined = set()
if props.exists():
    for line in props.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            defined.add(line.split("=", 1)[0].strip())
else:
    errors.append("presentationLabels/en-US.properties is missing")

used = set()
for p in app_files:
    if p.suffix in {".pmd", ".card", ".amd"}:
        used |= set(re.findall(r"presentationLabels\.([A-Za-z0-9_]+)", p.read_text(encoding="utf-8")))

for key in sorted(used - defined):
    errors.append(f"label used but not defined in en-US.properties: {key}")
for key in sorted(defined - used):
    warnings.append(f"label defined but never used: {key}")

# -------------------------------------------------------------- 3. task checks
amd_path = PRES / "equipmentCheckout.amd"
tasks = set()
if amd_path in parsed:
    tasks = {t["id"] for t in parsed[amd_path].get("tasks", [])}
    for t in parsed[amd_path].get("tasks", []):
        page_id = t.get("page", {}).get("id")
        if page_id and not (PRES / f"{page_id}.pmd").exists():
            errors.append(f"amd task '{t['id']}' points at missing page {page_id}.pmd")

for p in app_files:
    if p.suffix not in {".pmd", ".card"}:
        continue
    for tid in re.findall(r'"taskId"\s*:\s*"([^"]+)"', p.read_text(encoding="utf-8")):
        if tid not in tasks:
            errors.append(f"{p.relative_to(APP)}: taskReference '{tid}' is not a task in the .amd")

# ------------------------------------------------------------- 4. query checks
queries = {p.stem for p in (PRES / "graphQueries").glob("*.graphquery")}
for p in app_files:
    if p.suffix != ".pmd":
        continue
    text = p.read_text(encoding="utf-8")
    # only queryIds inside a "graphQuery" block — "wqlQuery" blocks are checked separately
    for qid in re.findall(r'"graphQuery"\s*:\s*\{\s*"queryId"\s*:\s*"([^"]+)"', text):
        if qid not in queries:
            errors.append(f"{p.relative_to(APP)}: queryId '{qid}' has no matching .graphquery file")

for p in (PRES / "graphQueries").glob("*.graphquery"):
    doc = parsed.get(p)
    if doc and doc.get("id") != p.stem:
        errors.append(f"{p.relative_to(APP)}: id '{doc.get('id')}' does not match filename")

# WQL queries: ids match filenames, and every wqlQuery reference resolves
wql_dir = PRES / "wqlQueries"
wql_queries = {p.stem for p in wql_dir.glob("*.wqlquery")} if wql_dir.exists() else set()
for p in wql_dir.glob("*.wqlquery") if wql_dir.exists() else []:
    doc = parsed.get(p)
    if doc and doc.get("id") != p.stem:
        errors.append(f"{p.relative_to(APP)}: id '{doc.get('id')}' does not match filename")

for p in app_files:
    if p.suffix != ".pmd":
        continue
    text = p.read_text(encoding="utf-8")
    block = re.findall(r'"wqlQuery"\s*:\s*\{.*?"queryId"\s*:\s*"([^"]+)"', text, re.DOTALL)
    for qid in block:
        if qid not in wql_queries:
            errors.append(f"{p.relative_to(APP)}: wql queryId '{qid}' has no matching .wqlquery file")

# ------------------------------------------- 4b. business process route checks
routes = set()
if amd_path in parsed:
    routes = {t.get("routingPattern") for t in parsed[amd_path].get("tasks", [])}

for p in MODEL.glob("*.businessprocess"):
    doc = parsed.get(p)
    if not doc:
        continue
    declared = []
    if isinstance(doc.get("approvalStep"), dict):
        declared.append(doc["approvalStep"].get("pageRoute"))
    if isinstance(doc.get("details"), dict):
        declared.append(doc["details"].get("pageRoute"))
    if doc.get("revisePageRoute"):
        declared.append(doc["revisePageRoute"])
    for step in doc.get("actionSteps", []) or []:
        declared.append(step.get("pageRoute"))
    for route in [r for r in declared if r]:
        if route not in routes:
            errors.append(
                f"{p.relative_to(APP)}: pageRoute '{route}' has no matching routingPattern in the .amd"
            )
    target = doc.get("targetBusinessObject")
    if target and not (MODEL / f"{target}.businessobject").exists():
        errors.append(f"{p.relative_to(APP)}: targetBusinessObject '{target}' has no .businessobject file")
    for domain in doc.get("securityDomains", []) or []:
        if not (MODEL / f"{domain}.securitydomain").exists():
            errors.append(f"{p.relative_to(APP)}: securityDomain '{domain}' has no .securitydomain file")

# --------------------------------------------------------- 5. placeholder scan
for p in app_files:
    if p.suffix == ".graphquery":
        continue
    text = p.read_text(encoding="utf-8")
    if "__APPID__" in text or "__APPIDPASCAL__" in text:
        errors.append(f"{p.relative_to(APP)}: contains an app-id placeholder outside graphQueries")

remaining = [p for p in (PRES / "graphQueries").glob("*.graphquery")
             if "__APPID__" in p.read_text(encoding="utf-8")]
if remaining:
    warnings.append(
        f"{len(remaining)} graphQuery files still hold __APPID__ placeholders - "
        "run scripts/Set-AppId.ps1 with your deployed app id before uploading"
    )

# ---------------------------------------------------------------------- report
print(f"parsed {len(parsed)}/{len(app_files)} app files "
      f"({sum(1 for m in modes.values() if m == 'strict')} strict, "
      f"{sum(1 for m in modes.values() if m == 'tolerant')} tolerant)")
print(f"labels: {len(used)} used, {len(defined)} defined")
print(f"tasks: {len(tasks)}   graphQueries: {len(queries)}")
print()

for w in warnings:
    print(f"  warn  {w}")
for e in errors:
    print(f"  FAIL  {e}")

if errors:
    print(f"\n{len(errors)} error(s)")
    sys.exit(1)
print("\nAll checks passed.")
