#!/usr/bin/env python3
"""Probe ansible-playbook for the module-name each task spelling prints
in "Unsupported parameters for (...) module" - and capture the full fatal
dump - by running one typo'd task per krikri-supported module.

The printed name is controller behavior (an action plugin may delegate under
a different name, e.g. template -> ansible.legacy.copy), so it cannot be
derived from the module's own argument spec; this probe is the ground truth
that feeds data/argspec_print_names.json.

Usage: python3 scripts/gen_print_names.py [module ...]   (default: all
modules listed in data/argspecs.json plus the known action-only ones)
"""
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAL = "/usr/bin/ansible-playbook"
TYPO = "zznope"

# Minimal per-module task args that let the task reach MODULE-LEVEL
# validation. Everything else fails earlier, at the action-plugin layer
# (missing src/content/dest), which is exactly what Ansible does
# too - these are the only modules whose action plugin checks inputs
# before the module's own argspec validation runs.
ARGS = {
    "ansible.builtin.copy": {"content": "probe", "dest": "/tmp/argval-probe/copy.txt"},
    "ansible.builtin.template": {"src": "/tmp/argval-probe/src.j2", "dest": "/tmp/argval-probe/tpl.txt"},
    "ansible.builtin.fetch": {"src": "/etc/hostname", "dest": "/tmp/argval-probe/fetch/"},
    "ansible.builtin.slurp": {"src": "/etc/hostname"},
    "ansible.builtin.stat": {"path": "/etc/hostname"},
    "ansible.builtin.unarchive": {"src": "/tmp/argval-probe/a.tar", "dest": "/tmp/argval-probe/un/"},
    "ansible.builtin.assemble": {"src": "/tmp/argval-probe/parts", "dest": "/tmp/argval-probe/assembled"},
    "ansible.builtin.service": {"name": "ssh", "state": "reloaded"},
    "ansible.builtin.package": {"name": "ssh", "state": "present"},
    "ansible.builtin.command": {"argv": ["/bin/true"]},
    "ansible.builtin.shell": {"cmd": "/bin/true"},
    "ansible.builtin.script": {"cmd": "/bin/true"},
    "ansible.builtin.pause": {"seconds": 0},
    "ansible.builtin.reboot": {"reboot_timeout": 1},
    "ansible.builtin.get_url": {"url": "http://127.0.0.1:1/x", "dest": "/tmp/argval-probe/url"},
    "ansible.builtin.uri": {"url": "http://127.0.0.1:1/"},
    "ansible.builtin.synchronize": {"src": "/etc/hostname", "dest": "/tmp/argval-probe/sync/"},
    "ansible.builtin.service_facts": {},
    "ansible.builtin.wait_for": {"timeout": 1},
    "ansible.builtin.expect": {"command": "echo hi", "responses": {"hi": ""}},
    "community.general.timezone": {"name": "UTC"},
    "community.general.ufw": {"rule": "allow"},
    "community.crypto.openssl_privatekey": {"path": "/tmp/argval-probe/k.pem"},
    "community.crypto.openssl_csr": {"path": "/tmp/argval-probe/c.pem", "privatekey_path": "/tmp/argval-probe/k.pem"},
    "community.crypto.openssl_pkcs12": {"path": "/tmp/argval-probe/p.p12", "privatekey_path": "/tmp/argval-probe/k.pem"},
    "community.crypto.x509_certificate": {"path": "/tmp/argval-probe/c.pem", "privatekey_path": "/tmp/argval-probe/k.pem"},
    "community.crypto.openssl_dhparam": {"path": "/tmp/argval-probe/dh.pem"},
    "community.crypto.openssh_keypair": {"path": "/tmp/argval-probe/id_probe"},
    "community.crypto.get_certificate": {"host": "127.0.0.1", "port": 1},
    "community.general.java_cert": {"path": "/tmp/argval-probe/k.pem", "dest": "/tmp/argval-probe/js"},
    "containers.podman.podman_image": {"name": "probe"},
    "community.general.maven_artifact": {"group_id": "g", "artifact_id": "a", "dest": "/tmp/argval-probe/m"},
    "community.general.nsupdate": {"key_name": "k", "key_secret": "s", "key_algorithm": "hmac-md5"},
    "community.general.sudoers": {"name": "probe", "commands": ["/bin/true"]},
    "amazon.aws.ec2_instance": {"state": "absent"},
    "amazon.aws.ec2_ami_info": {},
    "amazon.aws.ec2_key": {"name": "probe"},
    "community.docker.docker_login": {},
}

# Spellings probed per module FQCN: [bare-name probe] only makes sense for
# names that resolve without a collection prefix; FQCN spelling is probed
# for everything.
def spellings(fqcn):
    out = [fqcn]
    parts = fqcn.split(".")
    if parts[0] == "ansible" and parts[1] in ("builtin", "legacy"):
        out.insert(0, parts[-1])
    return out


def probe(modules):
    work = tempfile.mkdtemp(prefix="argval-probe-")
    os.makedirs(os.path.join(work, "parts"), exist_ok=True)
    open(os.path.join(work, "src.j2"), "w").write("probe\n")
    subprocess.run(["tar", "cf", os.path.join(work, "a.tar"), "-C", work, "src.j2"], check=True)

    results = {}
    chunk = []
    chunk_size = 25
    all_mods = list(modules)
    for idx, mod in enumerate(all_mods):
        for spelling in spellings(mod):
            entry = {"module": mod, "spelling": spelling}
            args = dict(ARGS.get(mod, {}))
            args[TYPO] = "1"
            entry["args"] = args
            chunk.append(entry)
        if len(chunk) >= chunk_size or idx == len(all_mods) - 1:
            results.update(run_chunk(chunk, work))
            chunk = []
    return results


def run_chunk(entries, work):
    tasks = []
    for i, e in enumerate(entries):
        args_lines = "\n".join(f"        {k}: {json.dumps(v)}" for k, v in e["args"].items())
        tasks.append(
            f'  - name: "P{i}"\n'
            f"    {e['spelling']}:\n"
            f"{args_lines}\n"
            f"    ignore_errors: true\n"
        )
    pb = os.path.join(work, "probe.yml")
    open(pb, "w").write(
        "---\n- hosts: localhost\n  gather_facts: false\n  tasks:\n" + "".join(tasks)
    )
    env = dict(os.environ)
    env.update(ANSIBLE_NOCOLOR="1", ANSIBLE_GATHERING="explicit")
    for k in ("ANSIBLE_CACHE_PLUGIN", "ANSIBLE_CACHE_PLUGIN_CONNECTION"):
        env.pop(k, None)
    proc = subprocess.run(
        ["/usr/bin/timeout", "120", REAL, "-i", "localhost,", "-c", local_flag(work), pb],
        capture_output=True, text=True, stdin=subprocess.DEVNULL, env=env, cwd=work,
    )
    return parse_output(proc.stdout, entries)


def local_flag(work):
    return "local"


UNSUPPORTED_RE = re.compile(
    r"Unsupported parameters for \((?P<name>[^)]+)\) module: (?P<unsupported>[^.]+)\. "
    r"Supported parameters include: (?P<supported>.+?)\.?$"
)


def parse_output(out, entries):
    # Split stdout into per-task blocks on the "TASK [Pn]" banners.
    blocks = re.split(r"\nTASK \[P(\d+)\]", out)
    results = {}
    for i in range(1, len(blocks) - 1, 2):
        idx = int(blocks[i])
        body = blocks[i + 1]
        entry = entries[idx]
        unsupported = UNSUPPORTED_RE.search(body)
        dump = re.search(r"fatal: \[localhost\]: FAILED! => (\{.*\})", body)
        rec = {
            "printed_name": unsupported.group("name") if unsupported else None,
            "unsupported": unsupported.group("unsupported").strip() if unsupported else None,
            "supported": unsupported.group("supported").rstrip(".") if unsupported else None,
            "dump": json.loads(dump.group(1)) if dump else None,
            "error_line": next(
                (l for l in body.splitlines() if l.startswith("[ERROR]:")), None
            ),
        }
        results[f"{entry['module']}|{entry['spelling']}"] = rec
    return results


def main():
    argspecs = json.load(open(os.path.join(REPO, "data/argspecs.json")))
    modules = sorted(argspecs)
    # Also probe action-only spellings with no extracted spec.
    extra = [
        "ansible.builtin.add_host", "ansible.builtin.assert", "ansible.builtin.debug",
        "ansible.builtin.fail", "ansible.builtin.fetch", "ansible.builtin.gather_facts",
        "ansible.builtin.group_by", "ansible.builtin.package", "ansible.builtin.pause",
        "ansible.builtin.reboot", "ansible.builtin.script", "ansible.builtin.set_fact",
        "ansible.builtin.set_stats", "ansible.builtin.shell", "ansible.builtin.template",
        "ansible.builtin.wait_for_connection", "ansible.builtin.yum",
        "community.docker.current_container_facts",
    ]
    for m in extra:
        if m not in modules:
            modules.append(m)
    if len(sys.argv) > 1:
        modules = sys.argv[1:]

    results = probe(modules)
    out = os.path.join(REPO, "data/argspec_print_names.json")
    existing = {}
    if os.path.exists(out):
        existing = json.load(open(out))
    existing.update(results)
    with open(out, "w") as f:
        json.dump(existing, f, indent=1, sort_keys=True)
    for key, rec in sorted(results.items()):
        status = rec["printed_name"] or "NO-VALIDATION"
        print(f"{key}: {status}" + ("" if rec["printed_name"] else f"  [{rec['error_line']}]" if rec["error_line"] else ""))


if __name__ == "__main__":
    main()
