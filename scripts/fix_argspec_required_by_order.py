#!/usr/bin/env python3
"""Re-order data/argspecs.json's required_by entries into Ansible's spec order.

gen_argspecs.py dumps with sort_keys=True, which alphabetizes the required_by dict;
Ansible's check_required_by iterates it in spec order, so the FIRST failing key differs
(systemd reports 'state' before 'enabled'). Run after gen_argspecs.py.
"""
import json
import importlib.util

spec = importlib.util.spec_from_file_location("gen", "scripts/gen_argspecs.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

raw = open("data/argspecs.json").read()
table = json.loads(raw)
for fqcn, entry in table.items():
    required_by = entry.get("required_by")
    if not required_by or len(required_by) < 2:
        continue
    try:
        captured = gen.capture_spec(gen.module_file(fqcn), fqcn)
    except Exception as exc:  # module not importable here: leave as is
        print("skip", fqcn, type(exc).__name__)
        continue
    real = (captured or {}).get("required_by") or {}
    ordered = {k: required_by[k] for k in real if k in required_by}
    ordered.update({k: v for k, v in required_by.items() if k not in ordered})
    if list(ordered) != list(required_by):
        entry["required_by"] = ordered
        print("reordered", fqcn, list(ordered))
open("data/argspecs.json", "w").write(json.dumps(table, indent=1, ensure_ascii=False) + ("\n" if raw.endswith("\n") else ""))
