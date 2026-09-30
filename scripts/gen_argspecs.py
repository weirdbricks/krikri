#!/usr/bin/env python3
"""Extract real Ansible argument specs for every module krikri ships a plugin for.

Ground truth = the installed ansible-core (+ installed collections): each
module's own ``AnsibleModule(argument_spec=...)`` call is captured by
importing the module with a patched ``AnsibleModule.__init__`` that records
its kwargs and aborts. The captured spec drives krikri's data-driven module
argument validation (see src/krikri/argspec_validator.cr).

Output: data/argspecs.json, keyed by the krikri plugin FQCN, plus
data/argspec_print_names.json (the module name real Ansible prints in
"Unsupported parameters for (...) module" - probed empirically with a real
ansible-playbook run per name spelling, since action plugins may delegate
under a different name, e.g. template -> ansible.legacy.copy).

Usage: python3 scripts/gen_argspecs.py [--skip-probe]
"""
import glob
import json
import os
import re

import subprocess
import sys

import ansible.module_utils.basic as ansible_basic

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = "/usr/lib/python3/dist-packages"
COLL_ROOTS = [
    os.path.expanduser("~/.ansible/collections/ansible_collections"),
    os.path.join(DIST, "ansible_collections"),
]

# Pseudo-modules with no real-Ansible module behind them: never validated.
NO_SPEC = {
    "ansible.builtin.py_module",
    "ansible.builtin.facts",
}


def krikri_modules():
    """Pull AVAILABLE_PLUGINS + MODULE_ALIASES targets out of module_registry.cr."""
    src = open(os.path.join(REPO, "src/krikri/module_registry.cr")).read()

    m = re.search(r"AVAILABLE_PLUGINS = Set\{(.*?)\n    \}", src, re.S)
    assert m, "AVAILABLE_PLUGINS block not found"
    block = m.group(1)
    plugins = set(re.findall(r'"([a-z0-9_]+\.[a-z0-9_.]+)"', block))

    aliases = {}
    am = re.search(r"MODULE_ALIASES = \{(.*?)\n    \}", src, re.S)
    if am:
        for k, v in re.findall(r'"([a-z0-9_.]+)"\s*=>\s*"([a-z0-9_.]+)"', am.group(1)):
            aliases[k] = v
    return plugins, aliases


def module_file(fqcn):
    ns, col, name = fqcn.split(".", 2)
    for root in COLL_ROOTS:
        p = os.path.join(root, ns, col, "plugins", "modules", name + ".py")
        if os.path.exists(p):
            return p
    if fqcn.startswith(("ansible.builtin.", "ansible.legacy.")):
        p = os.path.join(DIST, "ansible", "modules", fqcn.split(".")[-1]) + ".py"
        if os.path.exists(p):
            return p
        # ansible.builtin names that are redirects into collections
        # (ansible.posix.acl, community.general.timezone, ...) - follow
        # ansible_builtin_runtime.yml's own routing.
        redirect = builtin_redirect(fqcn.split(".")[-1])
        return module_file(redirect) if redirect else None
    p = os.path.join(DIST, "ansible", "modules", *fqcn.split(".")[1:]) + ".py"
    return p if os.path.exists(p) else None


_REDIRECT_CACHE = {}


def builtin_redirect(name):
    if not _REDIRECT_CACHE:
        import yaml

        rt = yaml.safe_load(open(os.path.join(DIST, "ansible/config/ansible_builtin_runtime.yml")))
        routing = rt["plugin_routing"]["modules"]
        for key, entry in routing.items():
            if isinstance(entry, dict) and entry.get("redirect"):
                _REDIRECT_CACHE[key] = entry["redirect"]
    return _REDIRECT_CACHE.get(name)


def import_module(path, fqcn):
    """Import the module file with full package context (relative imports
    like setup.py's `from ..module_utils.basic import ...` need it).

    ansible_collections is pre-registered as a namespace package spanning
    BOTH collection roots: the dist-packages copy is a namespace package
    whose auto-built __path__ only covers sys.path entries, so collections
    that only exist under ~/.ansible would be invisible to the module's
    own absolute `from ansible_collections...` imports."""
    import types

    ns = sys.modules.get("ansible_collections")
    if ns is None:
        ns = types.ModuleType("ansible_collections")
        ns.__path__ = []
        sys.modules["ansible_collections"] = ns
    for root in COLL_ROOTS:
        if root not in getattr(ns, "__path__", []):
            ns.__path__.append(root)

    if fqcn.startswith(("ansible.builtin.", "ansible.legacy.")):
        modname = "ansible.modules." + fqcn.split(".")[-1]
    else:
        parts = fqcn.split(".")
        modname = f"ansible_collections.{parts[0]}.{parts[1]}.plugins.modules.{parts[2]}"
    return __import__(modname, fromlist=["main"])


def capture_spec(path, fqcn):
    """Import the module and call main() with AnsibleModule.__init__
    patched to capture its kwargs."""
    captured = {}

    real_init = ansible_basic.AnsibleModule.__init__

    def patched(self, *args, **kwargs):
        spec = kwargs.get("argument_spec")
        if spec is None and args and isinstance(args[0], dict):
            spec = args[0]  # AnsibleModule(argument_spec) positional form
        captured["argument_spec"] = spec
        captured["mutually_exclusive"] = kwargs.get("mutually_exclusive")
        captured["required_together"] = kwargs.get("required_together")
        captured["required_one_of"] = kwargs.get("required_one_of")
        captured["required_if"] = kwargs.get("required_if")
        captured["required_by"] = kwargs.get("required_by")
        captured["add_file_common_args"] = kwargs.get("add_file_common_args", False)
        raise SystemExit(0)

    ansible_basic.AnsibleModule.__init__ = patched
    try:
        import io
        from contextlib import redirect_stderr, redirect_stdout

        mod = import_module(path, fqcn)
        main = getattr(mod, "main", None)
        if main is None:
            captured["error"] = "virtual/action-only module (no main)"
            return captured
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            main()
    except SystemExit:
        pass
    except BaseException as e:  # noqa: BLE001 - report and continue
        captured["error"] = repr(e)
    finally:
        ansible_basic.AnsibleModule.__init__ = real_init
    return captured


def clean_option(spec_entry):
    out = {}
    if spec_entry.get("aliases"):
        out["aliases"] = sorted(spec_entry["aliases"])
    t = spec_entry.get("type", "str")
    out["type"] = t if isinstance(t, str) else "str"
    if spec_entry.get("required"):
        out["required"] = True
    if spec_entry.get("choices") is not None:
        # Declaration order matters: real's choices error joins the spec's
        # own list order ("status, cleanup", not sorted).
        out["choices"] = spec_entry["choices"]
    if "default" in spec_entry:
        out["default"] = spec_entry["default"]
    if spec_entry.get("elements"):
        # Element type: drives the elements-level conversion checks (e.g.
        # elements=dict strings must parse as dicts - check_type_dict's
        # bare TypeError surfaces verbatim as the module failure msg).
        out["elements"] = spec_entry["elements"]
    if spec_entry.get("options") is not None:
        # Nested sub-spec (suboptions): presence alone decides whether
        # real's _list_no_log_values walk descends into the param's
        # elements (a list/dict option WITHOUT options= never raises the
        # dict-parse error); the sub-options themselves are captured
        # recursively so the walk can validate one level down.
        out["options"] = {
            name: clean_option(sub or {}) for name, sub in spec_entry["options"].items()
        }
    return out


def extract(fqcn):
    path = module_file(fqcn)
    if not path:
        return None
    # ansible.builtin names redirected into a collection (acl, timezone,
    # authorized_key, ...) share the target module's file, so the import
    # name must be the TARGET's, not the redirecting alias's.
    effective = fqcn
    if fqcn.startswith(("ansible.builtin.", "ansible.legacy.")) and not os.path.exists(
        os.path.join(DIST, "ansible", "modules", fqcn.split(".")[-1]) + ".py"
    ):
        redirect = builtin_redirect(fqcn.split(".")[-1])
        if redirect:
            effective = redirect
    cap = capture_spec(path, effective)
    if "error" in cap or cap.get("argument_spec") is None:
        return {"_error": cap.get("error", "no AnsibleModule init captured")}

    spec = dict(cap["argument_spec"])
    if cap.get("add_file_common_args"):
        from ansible.module_utils.basic import FILE_COMMON_ARGUMENTS

        for k, v in FILE_COMMON_ARGUMENTS.items():
            if k not in spec:
                spec[k] = v

    options = {}
    for name, entry in spec.items():
        entry = entry or {}
        options[name] = clean_option(entry)
    return {
        "options": options,
        "mutually_exclusive": cap.get("mutually_exclusive") or [],
        "required_together": cap.get("required_together") or [],
        "required_one_of": cap.get("required_one_of") or [],
        "required_if": cap.get("required_if") or [],
        "required_by": cap.get("required_by") or {},
    }


# Modules whose real-Ansible validation runs under a DIFFERENT module's
# argument spec because an action plugin delegates the actual module run
# (all live-verified against ansible-core 2.19.11 via a typo'd task on
# both engines - see the probes in scripts/gen_print_names.py):
#   template  -> copy's spec, printed as "ansible.legacy.copy"
#   shell     -> command's spec (incl. _uses_shell), "ansible.legacy.command"
#   service   -> the ansible_service_mgr module's spec (systemd on every
#                host this engine's own service plugin targets with
#                systemctl); package -> the ansible_pkg_mgr module's spec
#                (apt likewise). Both resolved from the host's facts at
#                validation time, falling back to no validation when the
#                fact is absent (real Ansible would run setup to detect).
DELEGATES = {
    "ansible.builtin.template": ("ansible.builtin.copy", "ansible.legacy.copy"),
    "ansible.builtin.shell": ("ansible.builtin.command", "ansible.legacy.command"),
    "ansible.builtin.assemble": (None, "ansible.legacy.assemble"),
    "ansible.builtin.command": (None, "ansible.legacy.command"),
    "ansible.builtin.uri": (None, "ansible.legacy.uri"),
    "ansible.builtin.copy": (None, "ansible.legacy.copy"),
    # the unarchive action plugin runs the module as ansible.legacy.unarchive
    "ansible.builtin.unarchive": (None, "ansible.legacy.unarchive"),
}

# Modules whose action plugin delegates per-host to another module; the
# spec target is resolved at validation time from the host's own facts.
FACT_DELEGATES = {
    "ansible.builtin.service": ("ansible_service_mgr", {"systemd": "ansible.builtin.systemd"}),
    "ansible.builtin.package": ("ansible_pkg_mgr", {"apt": "ansible.builtin.apt"}),
}

# Modules whose failure result carries extra keys real merges into the
# fatal dump from the action plugin's own result (copy/template compute
# the SHA1 of the source content before the module runs).
DUMP_EXTRA = {
    "ansible.builtin.copy": ["checksum"],
    "ansible.builtin.template": ["checksum"],
}

# Options the action plugin consumes itself and never forwards to the
# module (template's Jinja-rendering knobs - ansible-core's
# plugins/action/template.py removes exactly this list).
CONSUMED_BY_ACTION = {
    "ansible.builtin.template": [
        "newline_sequence", "block_start_string", "block_end_string",
        "variable_start_string", "variable_end_string",
        "comment_start_string", "comment_end_string",
        "trim_blocks", "lstrip_blocks", "output_encoding",
    ],
    # the service action plugin consumes `use:` (module selection) itself
    "ansible.builtin.service": ["use"],
}

# Action-only directives: there is no module binary, so validation is
# whatever the action plugin itself does (probed live; wordings and the
# supported lists below are copied from real 2.19.11 output). action_level
# selects the error-block chain shape (no "Module failed." middle segment).
VIRTUAL = {
    "ansible.builtin.debug": {
        "action_level": True,
        "unsupported_kind": "module",
        # Real's debug action validates its OWN spec (plugins/action/
        # debug.py validate_argument_spec) - msg raw / var
        # _check_type_str_no_conversion / verbosity int, mutually
        # exclusive (msg, var) - through the same ArgumentSpecValidator
        # the module path uses, so the check order is mutually_exclusive
        # -> types in declaration order -> unsupported parameters LAST,
        # and only errors[0] is ever reported: a wrong-typed verbosity
        # beats a typo'd key, a msg+var pair beats both (live-verified
        # vs 2.19.11).
        "options": {
            "msg": {"type": "raw", "default": "Hello world!"},
            "var": {"type": "str_no_conversion"},
            "verbosity": {"type": "int", "default": 0},
        },
        "mutually_exclusive": [["msg", "var"]],
        # debug's fatal dump carries ONLY msg (real's callback shape).
        "result_keys": ["msg"],
        "print": {
            "ansible.builtin.debug": "ansible_collections.ansible.builtin.plugins.action.debug",
        },
    },
    "ansible.builtin.pause": {
        "action_level": True,
        "unsupported_kind": "module",
        # Real's pause action validates its OWN spec (plugins/action/
        # pause.py validate_argument_spec): mutually exclusive first, then
        # types in declaration order, unsupported parameters LAST - a
        # wrong-typed seconds/minutes beats a typo'd param (live-verified
        # vs 2.19.11). minutes/seconds are the int CALLABLE, not the 'int'
        # string type: native floats/bools pass (int(1.5) == 1), while a
        # string goes through int(str) directly - "1.5" fails with the raw
        # ValueError "invalid literal for int() with base 10: '1.5'".
        "options": {
            "echo": {"type": "bool", "default": True},
            "minutes": {"type": "int_callable"},
            "seconds": {"type": "int_callable"},
            "prompt": {"type": "str"},
        },
        "mutually_exclusive": [["minutes", "seconds"]],
        # Real's UnsupportedError names the action plugin's RESOLVED fqcn
        # (self._load_name) whatever spelling the task used - fixed, not
        # spelling-keyed.
        "print": {"fixed": "ansible_collections.ansible.builtin.plugins.action.pause"},
    },
    "ansible.builtin.script": {
        # The script action plugin runs its own validate_argument_spec
        # (ansible-core plugins/action/script.py) - same message shapes,
        # action-level chain, FQCN-spelling name quirk.
        "action_level": True,
        "unsupported_kind": "module",
        "options": {
            "_raw_params": {},
            "cmd": {"type": "str"},
            "creates": {"type": "str"},
            "removes": {"type": "str"},
            "chdir": {"type": "str"},
            "executable": {"type": "str"},
        },
        "required_one_of": [["_raw_params", "cmd"]],
        "mutually_exclusive": [["_raw_params", "cmd"]],
        "print": {
            "ansible.builtin.script": "ansible_collections.ansible.builtin.plugins.action.script",
        },
    },
    "ansible.builtin.assert": {
        "action_level": True,
        "unsupported_kind": "module",
        "options": {
            # str_or_list_of_str is the action's own custom callable type
            # (plugins/action/assert.py): a natively-typed int/bool fails
            # "argument 'x' is of type int and we were unable to convert
            # to str_or_list_of_str: a string or list of strings is
            # required" BEFORE the unsupported-params error.
            "fail_msg": {"aliases": ["msg"], "type": "str_or_list_of_str"},
            "success_msg": {"type": "str_or_list_of_str"},
            "quiet": {"type": "bool"},
            "that": {"required": True},
        },
        "print": {
            "ansible.builtin.assert": "ansible_collections.ansible.builtin.plugins.action.assert",
        },
    },
    "ansible.builtin.fail": {
        "action_level": True,
        "unsupported_kind": "invalid_options",
        # option names the action plugin accepts; anything else is reported
        "valid": ["msg"],
    },
    "ansible.builtin.group_by": {
        "action_level": True,
        "unsupported_kind": "invalid_options",
        # option names the action plugin accepts; anything else is reported
        "valid": ["key", "parents"],
    },
    "ansible.builtin.wait_for_connection": {
        "action_level": True,
        "unsupported_kind": "invalid_options",
        # option names the action plugin accepts; anything else is reported
        "valid": ["connect_timeout", "delay", "sleep", "timeout"],
    },
    "ansible.builtin.async_status": {
        # The action plugin validates a REDUCED spec (jid + mode; it
        # supplies _async_dir itself) - probed wordings.
        "action_level": True,
        "options": {
            "jid": {"required": True, "type": "str"},
            "mode": {"type": "str", "choices": ["status", "cleanup"], "default": "status"},
        },
            },
}

# Modules real Ansible never argspec-validates on this class of host:
# action-only directives that ignore unknown keys entirely (fetch's typo'd
# options are silently dropped - probed), and the yum/dnf family whose
# action plugin fails at the backend-detection stage before any module
# runs on a non-RPM host.
NO_VALIDATE = {
    "ansible.builtin.fetch",
    "ansible.builtin.set_fact",
    "ansible.builtin.set_stats",
    "ansible.builtin.add_host",
    "ansible.builtin.gather_facts",
    "ansible.builtin.reboot",
    "ansible.builtin.yum",
    "ansible.builtin.dnf",
}


def ordered_table(table):
    """Serialize deterministically WITHOUT sorting each module's options.

    ``json.dump(sort_keys=True)`` flattened every module's options into
    alphabetical order, but real ansible-core's own validation walks the
    argument_spec dict in DECLARATION order
    (``_validate_argument_types``/``_validate_argument_values``: ``for
    param, spec in argument_spec.items()``), so the FIRST type/choices
    error real reports is the first failing option in that order
    (live-verified against 2.19.11: apt with both a wrong ``force`` bool
    and a wrong ``update_cache_retry_max_delay`` int reports the int,
    which is declared 4th vs force's 11th). Everything else stays sorted
    like before; only the ``options`` maps (and their nested sub-specs)
    keep their captured insertion order.
    """
    out = {}
    for fqcn in sorted(table):
        body = table[fqcn]
        out[fqcn] = {k: body[k] for k in sorted(body)}
    return out


def main():
    plugins, aliases = krikri_modules()
    table = {}
    errors = []
    for fqcn in sorted(plugins):
        if fqcn in NO_SPEC or fqcn in NO_VALIDATE:
            continue
        spec_of, fixed_print = DELEGATES.get(fqcn, (None, None))
        if spec_of:
            src = table.get(spec_of) or extract(spec_of)
            if not src or "_error" in src:
                errors.append(f"{fqcn}: delegate spec {spec_of} unavailable")
                continue
            data = dict(src)
        elif fqcn in VIRTUAL and ("options" in VIRTUAL[fqcn] or "supported" in VIRTUAL[fqcn]):
            data = dict(VIRTUAL[fqcn])
        else:
            data = extract(fqcn)
            if data is None or "_error" in data:
                # A fact-delegated module with no module file of its own
                # (package) still gets an entry: the spec comes from the
                # fact-resolved target module at validation time. An
                # action-only probe module (fail/group_by/...) keeps its
                # hand-authored virtual flags only.
                if fqcn in FACT_DELEGATES:
                    fact, mapping = FACT_DELEGATES[fqcn]
                    table[fqcn] = {"fact_delegate": {"fact": fact, "map": mapping}}
                    continue
                if fqcn in VIRTUAL:
                    table[fqcn] = dict(VIRTUAL[fqcn])
                    continue
                errors.append(f"{fqcn}: module file not found" if data is None else f"{fqcn}: {data['_error']}")
                continue
            data.update(VIRTUAL.get(fqcn, {}))
        spec_of, fixed_print = DELEGATES.get(fqcn, (None, None))
        if spec_of:
            src = table.get(spec_of) or extract(spec_of)
            if src and "_error" not in src:
                data = dict(src)
        if fixed_print:
            data["print"] = {"fixed": fixed_print}
        if fqcn in DUMP_EXTRA:
            data["dump_extra"] = DUMP_EXTRA[fqcn]
        if fqcn in CONSUMED_BY_ACTION:
            data["consumed_by_action"] = CONSUMED_BY_ACTION[fqcn]
        if fqcn in FACT_DELEGATES:
            fact, mapping = FACT_DELEGATES[fqcn]
            data["fact_delegate"] = {"fact": fact, "map": mapping}
        table[fqcn] = data

    for fqcn, body in VIRTUAL.items():
        if fqcn not in table and ("options" in body or "supported" in body):
            table[fqcn] = dict(body)
    for fqcn in NO_VALIDATE:
        if fqcn in plugins:
            table[fqcn] = {"no_validate": True}
    for fqcn in NO_SPEC:
        if fqcn in plugins:
            table[fqcn] = {"no_validate": True}

    os.makedirs(os.path.join(REPO, "data"), exist_ok=True)
    out = os.path.join(REPO, "data/argspecs.json")
    with open(out, "w") as f:
        json.dump(ordered_table(table), f, indent=1)
    print(f"wrote {out}: {len(table)} modules")
    for e in errors:
        print("ERROR", e)
    if not os.environ.get("SKIP_PROBE") and "--skip-probe" not in sys.argv:
        subprocess.call([sys.executable, os.path.join(REPO, "scripts/gen_print_names.py")])


if __name__ == "__main__":
    main()
