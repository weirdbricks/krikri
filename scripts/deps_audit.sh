#!/usr/bin/env bash
# Compare every shard.yml dependency with its upstream repository state.
#
# Exact pins are deliberate: this is not an update bot, just a report that
# answers "what are we pinned to, what exists now, and which pins are a
# commit rather than a tag". Run it when planning a dependency pass.
#
#   scripts/deps_audit.sh          # report (always exits 0)
#   scripts/deps_audit.sh --check  # exit 1 when a tag/version pin is behind
#
# Requires python3 + PyYAML and an authenticated `gh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

command -v gh >/dev/null 2>&1 || {
  echo "gh is required" >&2
  exit 1
}
gh auth status >/dev/null 2>&1 || {
  echo "gh is not authenticated (gh auth login)" >&2
  exit 1
}

python3 - "$ROOT/shard.yml" "$CHECK" <<'PY'
import json
import subprocess
import sys

import yaml

manifest, check = sys.argv[1], sys.argv[2] == "1"
with open(manifest) as fh:
    data = yaml.safe_load(fh)


def gh(path):
    try:
        out = subprocess.run(
            ["gh", "api", path], capture_output=True, text=True, timeout=30
        )
        if out.returncode != 0:
            return None
        return json.loads(out.stdout)
    except Exception:
        return None


rows = []
behind = []
for section in ("dependencies", "development_dependencies"):
    for name, spec in (data.get(section) or {}).items():
        repo = spec.get("github")
        if not repo:
            continue
        if "tag" in spec:
            pinned = f"tag {spec['tag']}"
        elif "commit" in spec:
            pinned = f"commit {spec['commit'][:12]}"
        elif "version" in spec:
            pinned = f"version {spec['version']}"
        elif "branch" in spec:
            pinned = f"branch {spec['branch']}"
        else:
            pinned = "default branch"

        meta = gh(f"repos/{repo}") or {}
        tags = gh(f"repos/{repo}/tags?per_page=100") or []
        latest_tag = tags[0]["name"] if tags else "-"

        pinned_ref = (
            spec.get("tag")
            or spec.get("version")
            or (spec.get("commit") or "")[:12]
            or spec.get("branch")
            or "-"
        )
        state = ""
        if "commit" not in spec and latest_tag != "-":
            def norm(value):
                return value[1:] if value.startswith("v") else value

            if norm(pinned_ref) != norm(latest_tag):
                state = "UPDATE?"
                behind.append(f"{name}: {pinned_ref} != {latest_tag}")

        rows.append(
            (
                name,
                repo,
                pinned,
                latest_tag,
                (meta.get("pushed_at") or "-")[:10],
                meta.get("open_issues_count", "-"),
                state,
            )
        )

widths = [max(len(str(r[i])) for r in rows + [("shard", "repo", "pinned", "latest tag", "pushed", "issues", "")]) for i in range(7)]
fmt = "  ".join("{:<%d}" % w for w in widths)
print(fmt.format("shard", "repo", "pinned", "latest tag", "pushed", "issues", ""))
print(fmt.format(*["-" * w for w in widths]))
for row in rows:
    print(fmt.format(*[str(c) for c in row]))

if behind:
    print("\nPins behind the newest upstream tag:")
    for line in behind:
        print("  " + line)
else:
    print("\nEvery tag/version pin matches the newest upstream tag.")

if check and behind:
    sys.exit(1)
PY
