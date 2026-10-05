#!/usr/bin/env python3
"""Compare registered-result KEY ORDER of krikri-playbook vs ansible-playbook.

One call replaces the usual write-play / run-real / run-krikri / parse / diff loop:

    scripts/key_order_diff.py tasks.yml            # tasks every `register:`ed
    scripts/key_order_diff.py tasks.yml --values   # also show differing values' types
    scripts/key_order_diff.py tasks.yml --keep     # keep the temp dir (prints path)

tasks.yml is a plain YAML *list of tasks* (no play wrapper). Every task whose
result you want compared needs `register: <name>`. The script wraps the tasks
in a localhost play, appends a `debug: msg="{{ <name> | to_json }}"` per
registered name, runs both engines (Ansible with the cache/gathering env
vars unset), and prints per-name key lists plus SAME/DIFF. `$TMP` inside
tasks.yml expands to a fresh per-run scratch directory shared by both runs
(re-created between the engines so state does not leak).

Exit 0 when every registered result has the same key order, 1 otherwise.
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KRIKRI = os.path.join(HERE, "..", "bin", "krikri-playbook")
SKIP_KEYS = {"invocation"}  # stripped before register on both sides, but be safe


def run_engine(cmd, play, tmp, env):
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    r = subprocess.run(cmd + [play], capture_output=True, text=True, env=env, timeout=900, cwd=tmp)
    return r.stdout + r.stderr


def parse(out, names):
    """name -> ordered key list (or the string 'MISSING')."""
    res = {}
    pat = re.compile(r'"msg": "(\{.*?\})"\n', re.S)
    found = pat.findall(out)
    # debug tasks run in name order, one JSON dump each; map by TASK header
    blocks = re.split(r"\nTASK \[", out)
    for blk in blocks:
        m = re.match(r"debug__(\w+)\]", blk)
        if not m:
            continue
        mm = pat.search(blk)
        if not mm:
            res[m.group(1)] = "MISSING"
            continue
        raw = mm.group(1).replace('\\"', '"').replace("\\\\", "\\")
        try:
            d = json.loads(raw, object_pairs_hook=lambda p: p)
            res[m.group(1)] = [(k, v) for k, v in d if k not in SKIP_KEYS]
        except Exception as e:  # noqa: BLE001
            res[m.group(1)] = "UNPARSEABLE: %s" % e
    for n in names:
        res.setdefault(n, "MISSING")
    return res


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) != 1:
        sys.exit(__doc__)
    tasks_text = open(args[0]).read()
    names = re.findall(r"^\s*register:\s*(\w+)\s*$", tasks_text, re.M)
    if not names:
        sys.exit("no `register:` names found in %s" % args[0])

    work = tempfile.mkdtemp(prefix="keydiff-")
    tmp = os.path.join(work, "scratch")
    tasks_text = tasks_text.replace("$TMP", tmp)
    indented = "\n".join(("    " + l) if l.strip() else l for l in tasks_text.splitlines())
    dbg = "\n".join('    - name: debug__%s\n      debug: {msg: "{{ %s | to_json }}"}' % (n, n) for n in names)
    play = os.path.join(work, "play.yml")
    open(play, "w").write(
        "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n%s\n%s\n" % (indented, dbg))

    env = {k: v for k, v in os.environ.items()
           if k not in ("ANSIBLE_GATHERING", "ANSIBLE_CACHE_PLUGIN", "ANSIBLE_CACHE_PLUGIN_CONNECTION")}
    real = parse(run_engine(["ansible-playbook"], play, tmp, env), names)
    kr = parse(run_engine([KRIKRI], play, tmp, env), names)

    bad = 0
    for n in names:
        r, k = real[n], kr[n]
        rk = [x[0] for x in r] if isinstance(r, list) else r
        kk = [x[0] for x in k] if isinstance(k, list) else k
        same = rk == kk
        bad += 0 if same else 1
        print("%s  %s" % ("SAME" if same else "DIFF", n))
        if not same:
            print("  real  :", rk)
            print("  krikri:", kk)
            if isinstance(rk, list) and isinstance(kk, list):
                print("  only-real  :", [x for x in rk if x not in kk])
                print("  only-krikri:", [x for x in kk if x not in rk])
        elif "--values" in flags:
            print("  keys:", rk)
    if "--keep" in flags:
        print("kept:", work)
    else:
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
