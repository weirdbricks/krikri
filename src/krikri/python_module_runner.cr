require "json"
require "base64"
require "./collection_index"
require "./bigint_json"
require "./version"

# Runner for role-private custom modules - a role's own `library/*.py`,
# outside the plugin set this engine ships as native binaries.
# Ansible executes these as ordinary Python on the target; the previous
# scope cut skipped them with a parse-time "uses unimplemented plugin"
# warning (exit 4 via reachable_unavailable_modules since 0.9.558),
# which diverged on every role leaning on its own library/ - seen
# repeatedly benchmarking linux-system-roles (sr_fingerprint,
# timesync_provider, kernel_settings_get_config, blivet).
#
# The runner delegates to the TARGET's own python3, the same way
# Ansible does - no Python is embedded or reimplemented here. The
# module source is uploaded and executed through the same plugin-binary
# transport everything else uses (see plugins/py_module.cr), so local
# and SSH connections both work without any new plumbing.
#
# Deliberately scoped to role-private `library/` directories and the
# playbook-adjacent `library/` (Ansible's two most common search
# roots); third-party COLLECTION modules (bodsch.*, community.*) are
# still the unchanged scope cut - those live inside installed
# collections on the comparison side, not in the playbook tree this
# runner can see.
module Krikri
  module PythonModuleRunner
    extend self

    # Short module name for the FQCN spellings a task can write
    # (`sr_fingerprint`, `linux_system_roles.sr_fingerprint`, ...).
    def short_name(module_name : String) : String
      module_name.rpartition('.')[2]
    end

    # Finds a role-private module source for *module_name*, or nil.
    # Search roots mirror Ansible's two most-used locations: the
    # current role's own `library/` and the playbook-adjacent
    # `library/`. First match wins (Ansible's own nearest-first
    # order).
    #
    # Takes the role's ROOT directory directly (`task.role_path`, always
    # set - see role_loader.cr's `task.role_path = role_dir`), not
    # `role_files_dir` (only set when the role actually ships a `files/`
    # subdirectory - `existing_dir` returns nil otherwise). A role with
    # no `files/` dir at all (linux-system-roles.storage/.logging/
    # .timesync, none of them ship one) could never resolve its own
    # `library/*.py` modules through the old files/-derived path, so
    # `sr_fingerprint`/`blivet`/`timesync_provider` fell straight back
    # to "unavailable modules" - the exact scope cut 0.9.819 was
    # supposed to have already closed for role-private modules. Found
    # re-testing linux-system-roles.storage/logging/timesync.
    # Extensions Ansible's legacy module finder never matches a
    # module name against (ansible-core's MODULE_IGNORE_EXTS). A role
    # shipping a DOCUMENTATION stub next to its script -
    # linux-system-roles.timesync's library/timesync_provider.yml beside
    # timesync_provider.sh - must resolve to the script, never the stub.
    MODULE_IGNORE_EXTS = %w[.pyc .pyo .swp .bak ~ .rpm .md .txt .rst .yaml .yml .ini]

    # Between the role's own library/ and the playbook's sit the
    # library/ dirs of every role loaded so far: ansible adds a role's
    # library/ to the module path at Role.load and keeps it for the rest
    # of the run, so a role pulled in through include_role: still sees
    # its ancestors' custom modules.
    def find_source(module_name : String, role_path : String?, playbook_dir : String?) : String?
      short = short_name(module_name)
      return nil if short.empty?

      roots = [] of String
      roots << File.join(role_path, "library") if role_path
      roots.concat(PythonFilterRunner.loaded_role_roots("library"))
      roots << File.join(playbook_dir, "library") if playbook_dir && !playbook_dir.empty?

      roots.each do |root|
        candidate = File.join(root, "#{short}.py")
        return candidate if File.file?(candidate)
        # Extensionless module file - Ansible's own action-plugin
        # module finder accepts any file in library/ regardless of
        # extension (the shebang line determines the interpreter;
        # kunik.deploy-metadata's own library/deployment_facts has no
        # .py extension and ansible-playbook ran it fine).
        extensionless = File.join(root, short)
        return extensionless if File.file?(extensionless)
        # Any OTHER extension: Ansible's legacy module finder indexes
        # every file in the search dir by its basename-minus-extension,
        # excluding only MODULE_IGNORE_EXTS (ansible-core loader.py
        # _find_plugin) - so library/timesync_provider.sh IS the
        # timesync_provider module. Round 970350: ansible-playbook
        # ran linux-system-roles.timesync's shell module fine while this
        # engine - matching only .py or extensionless - found no source
        # and skipped the task ("Determine current NTP provider": ok on
        # the real side, skipped here, cold and warm).
        Dir.glob(File.join(root, "#{short}.*")).sort.each do |other|
          next if MODULE_IGNORE_EXTS.any? { |ext| other.ends_with?(ext) }
          return other
        end
      end
      nil
    end

    # A role (or the playbook tree) shipping its OWN custom module_utils
    # packages - e.g. linux-system-roles.storage's the Ansible module
    # beside its library/blivet.py, which does `from
    # ansible.module_utils.storage_lsr.argument_validator import
    # validate_parameters`. Ansible's AnsiballZ wrapper bundles the
    # role's own module_utils tree into the zipapp alongside the module
    # source so the import resolves; this runner previously uploaded only
    # the ONE module source file, so the import died with a plain Python
    # ModuleNotFoundError. The convention mirrors find_source's own two
    # search roots: `<role_root>/module_utils/` (sibling of the role's
    # `library/`) and the playbook-adjacent `module_utils/`, nearest-first
    # - a relative path found under an earlier root shadows the same
    # relative path under a later one. Collections are NOT part of this
    # surface: a collection module importing its own utils uses the
    # `ansible_collections.<ns>.<coll>.plugins.module_utils.*` namespace
    # (not `ansible.module_utils.*`), and third-party collection modules
    # remain the unchanged scope cut above.
    #
    # Returns RELATIVE path (under module_utils/) -> absolute source path,
    # empty when neither root exists (the common case - zero overhead, the
    # caller sends no extra payload at all). Only regular files travel;
    # .pyc/.pyo caches are skipped the way MODULE_IGNORE_EXTS skips junk
    # in find_source.
    def collect_module_utils_files(role_path : String?, playbook_dir : String?) : Hash(String, String)
      roots = [] of String
      roots << File.join(role_path, "module_utils") if role_path
      roots << File.join(playbook_dir, "module_utils") if playbook_dir && !playbook_dir.empty?

      files = Hash(String, String).new
      roots.each do |root|
        next unless Dir.exists?(root)
        Dir.glob(File.join(root, "**", "*")).sort.each do |path|
          next unless File.file?(path)
          next if path.ends_with?(".pyc") || path.ends_with?(".pyo")
          rel = Path.new(path).relative_to?(Path.new(root))
          next unless rel
          key = rel.to_s
          files[key] = path unless files.has_key?(key)
        end
      end
      files
    end

    # Directories to put on a custom module's PYTHONPATH so an
    # `ansible_collections.*` import resolves the way real ansible's
    # module payload provides it. Real ansible never needs the
    # collections importable on the target: its AnsiballZ wrapper
    # bundles every ansible.module_utils.* AND
    # ansible_collections.<ns>.<coll>.plugins.module_utils.* import INTO
    # the zipapp it ships (ansible-core remaps collection module_utils
    # into the payload), so a module doing `from
    # ansible_collections.amazon.aws.plugins.module_utils.retries
    # import AWSRetry` runs on a python that cannot import the
    # collection at all. This runner executes the raw script with the
    # target's python instead, so when that python is not the one the
    # collections were installed into (Homebrew's isolated Cellar
    # interpreter, issue #692; an ansible-galaxy user install under
    # ~/.ansible/collections, which no python has on sys.path) the
    # import died with ModuleNotFoundError where ansible-playbook ran
    # the module fine. The roots are the same ones CollectionIndex
    # already enumerates for module-name resolution (ANSIBLE_COLLECTIONS_PATH,
    # the default install locations, the ansible-playbook shebang's
    # virtualenv site-packages). A root may name either a collections
    # ROOT (a directory CONTAINING an ansible_collections/ tree) or a
    # path pointing directly AT an ansible_collections dir - Python
    # needs the PARENT of ansible_collections on sys.path either way.
    # Roots whose tree is absent are dropped (CollectionIndex keeps the
    # two default locations even when they don't exist); `roots` is a
    # test seam so a spec can pin the mapping without touching the
    # process-wide collection env.
    def self.collection_import_roots(roots : Array(String)? = nil) : Array(String)
      mapped = (roots || CollectionIndex.roots).flat_map do |root|
        trimmed = root.chomp('/')
        # A collections root IS the PYTHONPATH entry; a path pointing AT
        # the ansible_collections dir contributes its parent instead.
        File.basename(trimmed) == "ansible_collections" ? [File.dirname(trimmed)] : [trimmed]
      end
      existing = mapped.select { |dir| Dir.exists?(File.join(dir, "ansible_collections")) }
      existing.uniq
    end

    # The legacy module-boilerplate marker: a module leaving
    # `#<<INCLUDE_ANSIBLE_MODULE_COMMON>>` in its source expects the
    # controller to splice the module_utils bundle in at that spot.
    # Real ansible-core's modularizer (executor/module_common.py
    # _find_module_utils) replaces the marker with
    # `from ansible.module_utils.basic import *` and then classifies
    # the module as NEW-style - so kunik.deploy-metadata's
    # library/deployment_facts (which calls AnsibleModule(argument_spec
    # = dict()) without ever importing it) ran fine under
    # ansible-playbook while this engine - shipping the raw source -
    # died with "name 'AnsibleModule' is not defined" (issue #543).
    MODULE_COMMON_MARKER = "#<<INCLUDE_ANSIBLE_MODULE_COMMON>>"

    # Ansible's own new-style detection (module_common.py
    # _find_module_utils): a module importing ansible.module_utils - or
    # one carrying the legacy INCLUDE marker, which the modularizer
    # rewrites into `from ansible.module_utils.basic import *` - gets
    # its args as a JSON dict (via the ANSIBLE_MODULE_ARGS env var its
    # basic.py reads when no argv is given); everything else is
    # old-style key=value argv.
    #
    # NEW_STYLE_PYTHON_MODULE_RE in the same file ALSO counts a
    # collection module_utils import (`from|import
    # ansible_collections.<ns>.<coll>.plugins.module_utils...`) as
    # new-style - such a module (a custom `library/` module built on
    # amazon.aws' AnsibleAWSModule, which wraps AnsibleModule) gets its
    # args on stdin JSON like any module_utils importer, because ansible
    # bundles the collection's module_utils into the AnsiballZ payload.
    # Missing this form classified the module old-style, and the shim
    # AnsibleModule (argv is never read) then saw no args at all:
    # "missing required arguments: tags" for a dict arg the task passed
    # (issue #955).
    COLLECTION_MODULE_UTILS_IMPORT =
      /\b(?:from|import)\s+ansible_collections\.[^.\s]+\.[^.\s]+\.plugins\.module_utils\b/

    def new_style?(source : String) : Bool
      source.includes?("from ansible.module_utils") ||
        source.includes?("import ansible.module_utils") ||
        source.includes?("ansible.module_utils.basic") ||
        source.includes?(MODULE_COMMON_MARKER) ||
        source.matches?(COLLECTION_MODULE_UTILS_IMPORT)
    end

    # The modularizer step itself: swap the legacy marker for the
    # import the marker stood for, exactly as _find_module_utils does
    # before anything else looks at the source. A module without the
    # marker comes back untouched.
    def modularize(source : String) : String
      source.includes?(MODULE_COMMON_MARKER) ? source.gsub(MODULE_COMMON_MARKER, "from ansible.module_utils.basic import *") : source
    end

    # Ansible refuses to ship a module payload whose first line is
    # not a `#!` interpreter line: ActionBase._execute_module's
    # `if not module_shebang and module_style != 'binary'` guard raises
    # "module (name) is missing interpreter line" as a controller-side
    # AnsibleError (failed task, nothing executed on the target).
    # New-style modules are exempt in practice - the AnsiballZ wrapper
    # embeds its own shebang. This engine runs the raw script with the
    # target's python3 instead of honoring the file's own line, so
    # without this guard a shebangless old-style module - which
    # ansible-playbook FAILS - silently succeeded (found by the
    # py_module podman-diff edge cases: only the new-style fixture
    # survived the real side without a shebang).
    def missing_interpreter_line?(source : String, new_style : Bool) : Bool
      !new_style && !source.lines.first?.try(&.starts_with?("#!"))
    end

    # The module's argument dict: the substituted task params (already
    # stringified by the parser) re-typed as JSON where they parse -
    # the parser JSON-encodes list/dict-valued params verbatim, so
    # `"['a','b']"` becomes a real array for the module, the way
    # Ansible passes typed args. Plus Ansible's own reserved
    # `_ansible_*` keys a new-style module's AnsibleModule reads.
    def build_module_args(params : Hash(String, String), check_mode : Bool, module_name : String) : String
      args = Hash(String, JSON::Any).new
      args["_ansible_check_mode"] = JSON::Any.new(check_mode)
      args["_ansible_diff"] = JSON::Any.new(false)
      args["_ansible_verbosity"] = JSON::Any.new(0_i64)
      # Ansible's action base adds the invoked module's short name to the
      # args (plugins/action/__init__.py: "module_args['_ansible_module_name']
      # = module_name"), and real basic.py promotes it into self._name
      # (PASS_VARS 'module_name') - the name its own messages, including
      # the "remote module (name) does not support check mode" skip,
      # carry. Without it, a target WITH ansible-core reported the literal
      # "(basic.py)" where real named the module.
      args["_ansible_module_name"] = JSON::Any.new(module_name)
      params.each do |key, value|
        next if key.in?("check_mode", "diff_mode", "_verbosity", "_environment")
        # A parser-marked non-string YAML literal (NON_STRING_PARAM_PREFIX)
        # decodes straight to its native JSON value - exactly what
        # typed_value would re-infer from the demoted text, so a role
        # module sees the same typed arg either way.
        if native = Krikri.non_string_scalar(value)
          args[key] = native
        elsif members = typed_member_list(value)
          args[key] = members
        else
          args[key] = typed_value(value)
        end
      end
      # A bigint marker inside the args (a container param carrying a
      # wide int) must reach the module as a bare Python int, not the
      # marked string - unquote_bigint_json rewrites ONLY the exact
      # marked form, so a genuine user string is never altered.
      Krikri.unquote_bigint_json(args.to_json)
    end

    # The old-style key=value argv line (one entry per param).
    def build_kv_argv(params : Hash(String, String)) : Array(String)
      params.reject { |key, _| key.in?("check_mode", "diff_mode", "_verbosity", "_environment") }
        .map do |key, value|
          # A parser-marked non-string YAML literal serializes the way
          # Ansible's str() would (bools as True/False) - see
          # NON_STRING_PARAM_PREFIX.
          if native = Krikri.non_string_scalar(value)
            "#{key}=#{Krikri.python_str_scalar(native)}"
          else
            # A comma-joined list param's marked members must never reach
            # an old-style module's argv - Ansible stringifies a list k=v
            # arg to plain member text, and the sentinel is engine-internal
            # bookkeeping no module should ever see.
            "#{key}=#{Krikri.strip_non_string_markers_in_value(value)}"
          end
        end
    end

    # A parser comma-joined list param carrying NON_STRING_MEMBER_PREFIX-
    # marked members (see param_sentinels.cr) reconstructs to a real JSON
    # array here: real Ansible hands a module a YAML list arg as a list
    # whose members keep their types (live-verified vs 2.19.11 -
    # `r: ["{{ x }}", 1]` with an int x reaches a role-local module as
    # [5, 1], r_type "list"), where this engine used to ship the
    # comma-joined wire TEXT with the sentinel still inside it
    # (issue #696: the module saw the string "5,\u{E000}nonmember:1").
    # Marked members decode to their native YAML scalar; unmarked ones
    # re-infer from text exactly the way typed_value re-infers a whole
    # value - the engine's established py-module convention. nil when the
    # value carries no member marker at all: a plain string arg (a list
    # of only-string members is indistinguishable from one on the
    # strings-only wire and stays a string, as before) or a whole-value
    # JSON container, both unchanged.
    def typed_member_list(value : String) : JSON::Any?
      return nil unless value.includes?(Krikri::NON_STRING_MEMBER_PREFIX)
      members = value.split(',').map do |part|
        native = Krikri.non_string_member_scalar(part) || Krikri.non_string_scalar(part)
        native || typed_value(part)
      end
      JSON::Any.new(members)
    end

    def typed_value(value : String) : JSON::Any
      stripped = value.strip
      if stripped.starts_with?('{') || stripped.starts_with?('[')
        # A whole-value `{{ list_var }}`/`{{ dict_var }}` container arg
        # arrives as the double-quoted JSON the wire serialized it to
        # (see substitute_task_params's whole-single-span comment) - a
        # Ansible module arg keeps the referenced value's native
        # type for a whole-span template (live-verified vs
        # ansible-playbook 2.19.11: `apt: name: "{{ pkg_list }}"` with a
        # real list var looks up the clean elements), so parse it back
        # into a real container here the same way. ONLY valid JSON,
        # though - never a Python-repr repair pass: a value that merely
        # LOOKS like a container is a plain STRING in ansible-core
        # (live-verified, see apt.cr's parse_package_names).
        # BigJson, not JSON.parse: a container holding an integer wider
        # than Int64 must keep it (as a bigint marker) instead of the
        # whole parse raising and the whole arg degrading to a string.
        parsed = begin
          Krikri::BigJson.parse(stripped)
        rescue
          nil
        end
        return parsed if parsed
      end
      return JSON::Any.new(true) if stripped == "true" || stripped == "True"
      return JSON::Any.new(false) if stripped == "false" || stripped == "False"
      return JSON::Any.new(nil) if stripped == "None" || stripped == "null"
      if int = stripped.to_i64?
        return JSON::Any.new(int)
      end
      # A BIGINT_SENTINEL_PREFIX-marked wide int (a whole-span
      # `{{ big_var }}` arg the executor re-marked - see
      # bigint_typed_param_text) falls through to the string branch below
      # and ships AS the marked string: build_module_args and the action
      # payload serialize through Krikri.unquote_bigint_json, so the
      # module/plugin receives a bare Python int the way Ansible passes
      # its own. There is deliberately NO bare-digits rule here: the
      # substituted text of a wide-int span and a LITERAL wide-digit
      # string param are the same bytes on this wire, and ansible-core
      # keeps the literal a str - only the marker (provenance the
      # executor carries) may promote to an int.
      JSON::Any.new(value)
    end

    # The `ansible/module_utils` bundle a new-style module's
    # `from ansible.module_utils.basic import AnsibleModule` import needs.
    # Ansible never relies on ansible-core being installed on the
    # target - the AnsiballZ wrapper bundles module_utils INTO the module
    # payload it ships - so every new-style role-private module runs on
    # any target with a python3. This engine runs the raw module script
    # instead, so on a target with no ansible-core installed the import
    # died with ModuleNotFoundError and the module printed no result JSON
    # ("MODULE FAILURE") - hard-FAILING the task where Ansible ran
    # it successfully (found via newrelic.newrelic-infra's own
    # "Setup agent config *NIX" task: the role ships its own
    # library/merge_yaml.py, which took the py_module path and failed on
    # every fresh target while ansible-playbook succeeded). The shim
    # covers what corpus role-private modules actually use - params
    # parsing/validation against argument_spec (with type coercion,
    # defaults, aliases, required), check_mode, exit_json/fail_json,
    # warn/run_command, log, get_bin_path - plus the
    # ansible/module_utils/_text helpers modules import directly; not
    # the whole real basic.py surface; anything beyond that fails
    # exactly as before this shim existed.
    BASIC_PY_SHIM = <<-PYTHON
      import json
      import os
      import platform
      import shlex
      import subprocess
      import sys
      import tempfile


      # Real basic.py ships this import-gate helper beside AnsibleModule,
      # and role-private modules import both names in one line
      # (linux-system-roles.selinux's library/selinux_modules_facts.py on
      # a target without python3-libsemanage, issue #557): without it
      # here the import itself raised ImportError, the module printed no
      # result JSON and the task died as MODULE FAILURE where real's
      # bundled basic.py lets the module fail through fail_json. Verbatim
      # from ansible-core 2.19's basic.py so the composed text - library,
      # hostname, interpreter path, fixed advice - matches the [ERROR]
      # block real prints for the same failure.
      def missing_required_lib(library, reason=None, url=None):
          hostname = platform.node()
          msg = "Failed to import the required Python library (%s) on %s's Python %s." % (library, hostname, sys.executable)
          if reason:
              msg += " This is required %s." % reason
          if url:
              msg += " See %s for more info." % url
          msg += (" Please read the module documentation and install it in the appropriate location."
                  " If the required library is installed, but Ansible is using the wrong Python interpreter,"
                  " please consult the documentation on ansible_python_interpreter")
          return msg


      # Real basic.py re-exports env_fallback from common.parameters beside
      # AnsibleModule, and modules import both names in one line to declare
      # argument-spec fallbacks (fallback=(env_fallback, ['MY_REGION'])) -
      # custom modules that declare env-var fallbacks the way the Ansible
      # docs teach fail at this very import otherwise (issue #752).
      class AnsibleFallbackNotFound(Exception):
          pass

      def env_fallback(*args, **kwargs):
          """Load value from environment variable"""

          for arg in args:
              if arg in os.environ:
                  return os.environ[arg]
          raise AnsibleFallbackNotFound

      class AnsibleModule(object):
          def __init__(self, argument_spec=None, bypass_checks=False, no_log=False,
                       supports_check_mode=False, **kwargs):
              self.argument_spec = argument_spec or {}
              self.supports_check_mode = supports_check_mode
              self._warnings = []
              self.tmpdir = tempfile.gettempdir()
              self.check_mode = False
              self.params = {}
              self._name = os.path.splitext(os.path.basename(sys.argv[0]))[0]
              raw_args = self._read_args()
              self.check_mode = bool(
                  raw_args.pop('_ansible_check_mode', False)
                  or os.environ.get('ANSIBLE_CHECK_MODE') == '1')
              # Real 2.21's action layer passes the INJECT_INVOCATION config
              # resolution with every module run and _return_formatted
              # injects or pops `invocation` off it (basic.py:
              # "_ansible_inject_invocation"); the shim mirrors that
              # instead of the pre-2.21 always-inject.
              self._inject_invocation = bool(raw_args.pop('_ansible_inject_invocation', False))
              # Real basic.py's PASS_VARS always exposes `_diff` (from
              # `_ansible_diff`, default False) on the instance, and
              # amazon.aws' AnsibleAWSModule copies `self._module._diff`
              # right after constructing its AnsibleModule - without the
              # attribute a collection-backed custom module died with
              # "'AnsibleModule' object has no attribute '_diff'" before
              # it ever looked at its params (issue #955).
              self._diff = bool(raw_args.pop('_ansible_diff', False))
              self._apply_argument_spec(raw_args)
              # Real basic.py closes __init__ with this same gate
              # (basic.py: "if self.check_mode and not
              # self.supports_check_mode: self.exit_json(skipped=True, ...)"),
              # placed AFTER argument validation: a module that never
              # declared supports_check_mode must never reach its own body
              # under --check - a check-mode run must not make real
              # changes, and this shim previously let the body run
              # (issue #693: the module's side effects happened during a
              # dry run).
              if self.check_mode and not self.supports_check_mode:
                  self.exit_json(skipped=True, msg='remote module (%s) does not support check mode' % self._name)

          def _read_args(self):
              env_args = os.environ.get('ANSIBLE_MODULE_ARGS')
              if env_args:
                  try:
                      return json.loads(env_args)
                  except ValueError:
                      self.fail_json(msg='ANSIBLE_MODULE_ARGS env var is not valid JSON')
              raw = ''
              try:
                  if not sys.stdin.isatty():
                      raw = sys.stdin.read()
              except Exception:
                  raw = ''
              raw = raw.strip()
              if not raw:
                  return {}
              try:
                  parsed = json.loads(raw)
              except ValueError:
                  self.fail_json(msg='Failed to decode JSON module parameters.')
              if isinstance(parsed, dict) and 'ANSIBLE_MODULE_ARGS' in parsed:
                  parsed = parsed['ANSIBLE_MODULE_ARGS']
              if not isinstance(parsed, dict):
                  self.fail_json(msg='Module parameters must be a JSON object.')
              return parsed

          def _cast(self, name, value, spec):
              kind = spec.get('type', 'str')
              if kind == 'bool':
                  if isinstance(value, bool):
                      return value
                  text = str(value).strip().lower()
                  if text in ('yes', 'on', '1', 'true'):
                      return True
                  if text in ('no', 'off', '0', 'false', ''):
                      return False
                  self.fail_json(msg="argument '%s' is not a valid boolean" % name)
              if kind == 'int':
                  try:
                      return int(value)
                  except (TypeError, ValueError):
                      self.fail_json(msg="argument '%s' is not a valid integer" % name)
              if kind == 'float':
                  try:
                      return float(value)
                  except (TypeError, ValueError):
                      self.fail_json(msg="argument '%s' is not a valid float" % name)
              if kind in ('dict', 'json'):
                  if isinstance(value, dict):
                      return value
                  try:
                      parsed = json.loads(value)
                  except (TypeError, ValueError):
                      self.fail_json(msg="argument '%s' is not valid JSON" % name)
                  if not isinstance(parsed, dict):
                      self.fail_json(msg="argument '%s' is not a dict" % name)
                  return parsed
              if kind == 'list':
                  if isinstance(value, list):
                      return value
                  try:
                      parsed = json.loads(value)
                  except (TypeError, ValueError):
                      parsed = str(value).split(',')
                  return parsed
              if kind == 'path':
                  return os.path.expanduser(os.path.expandvars(str(value)))
              # Real check_type_str (common/validation.py): a str passes
              # through unchanged, None becomes '' ("approximate pre-2.19
              # templating None->empty str equivalency"), and anything else
              # - a real int included, which is exactly what a wide-int
              # param arrives as after the args' bigint marker unquoting -
              # is to_native()'d into its str(). Returning the value
              # unchanged instead left a str-typed param holding the int
              # the caller sent, diverging from real's coerced echo
              # (issue #915: this shim now serves targets that used to
              # reach their own real basic.py, where the coercion ran).
              # 'raw' deliberately falls through to the unchanged value -
              # real's raw type never converts.
              if kind == 'str':
                  if isinstance(value, str):
                      return value
                  if value is None:
                      return ''
                  if isinstance(value, bytes):
                      try:
                          return value.decode('utf-8')
                      except UnicodeDecodeError:
                          return value.decode('utf-8', 'surrogateescape')
                  return str(value)
              return value

          def _apply_argument_spec(self, raw_args):
              for key, spec in self.argument_spec.items():
                  for alias in spec.get('aliases', []) or []:
                      if alias in raw_args and key not in raw_args:
                          raw_args[key] = raw_args[alias]
              # Real validates args through ModuleArgumentSpecValidator,
              # which runs set_fallbacks (common/parameters.py) BEFORE
              # _set_defaults: a param the caller did not pass gets its
              # fallback strategy's value (env_fallback reads the named
              # env vars), a not-found fallback leaves the param to the
              # default/None path, and an explicitly passed value never
              # consults the fallback at all - so basic.py's own
              # unsafe_writes takes ANSIBLE_UNSAFE_WRITES over its
              # default=False only when the env var is set (issue #752).
              for key, spec in self.argument_spec.items():
                  if key in raw_args or 'fallback' not in spec:
                      continue
                  fallback = spec['fallback']
                  if not fallback:
                      continue
                  fallback_args = []
                  fallback_kwargs = {}
                  for item in fallback[1:]:
                      if isinstance(item, dict):
                          fallback_kwargs = item
                      else:
                          fallback_args = item
                  try:
                      fallback_value = fallback[0](*fallback_args, **fallback_kwargs)
                  except AnsibleFallbackNotFound:
                      continue
                  raw_args[key] = fallback_value
              missing = []
              for key, spec in self.argument_spec.items():
                  if key in raw_args:
                      value = self._cast(key, raw_args[key], spec)
                      if spec.get('type') == 'list' and spec.get('elements'):
                          element_spec = {'type': spec['elements']}
                          value = [self._cast(key, element, element_spec)
                                   for element in value]
                      self.params[key] = value
                  elif 'default' in spec:
                      self.params[key] = spec['default']
                  elif spec.get('required'):
                      missing.append(key)
                  else:
                      self.params[key] = None
              if missing:
                  self.fail_json(msg='missing required arguments: %s'
                                 % ', '.join(sorted(missing)))
              for key, value in raw_args.items():
                  if key.startswith('_ansible_') or key in self.params:
                      continue
                  self.params[key] = value

          def _pull_global_warnings(self):
              try:
                  from ansible.module_utils.common.warnings import get_warning_messages
                  for text in get_warning_messages():
                      if str(text) not in self._warnings:
                          self._warnings.append(str(text))
              except Exception:
                  pass

          def warn(self, message):
              self._warnings.append(str(message))

          def deprecate(self, message, **kwargs):
              self._warnings.append('DEPRECATED: %s' % message)

          # Real basic.py logs to the systemd journal (when the target has
          # python-systemd) or syslog with the ident
          # 'ansible-<module_name>' at LOG_INFO; where neither is reachable
          # (containers, sandboxed exec contexts) python's syslog module
          # itself silently no-ops. Real basic.py only raises when *msg*
          # isn't a string; the actual syslog write never fails the module
          # - so here a swallowed exception is the documented worst case,
          # never an AttributeError like before (sr_fingerprint via
          # linux-system-roles.firewall/.kdump).
          def log(self, msg, log_args=None):
              if isinstance(msg, bytes):
                  msg = msg.decode('utf-8', 'replace')
              try:
                  import syslog
                  syslog.openlog('ansible-%s' % self._name, 0, syslog.LOG_USER)
                  syslog.syslog(syslog.LOG_INFO, str(msg))
              except Exception:
                  pass

          def run_command(self, args, check_rc=False, cwd=None,
                          environ_update=None, **kwargs):
              # A string command is shlex.split (not str.split) in real
              # basic.py, so quoting survives; the split tokens are what
              # _clean_args re-quotes into the cmd: key of a failure.
              if isinstance(args, str):
                  argv = shlex.split(args)
              else:
                  argv = [str(a) for a in args]
              clean_args = ' '.join(shlex.quote(a) for a in argv)
              env = os.environ.copy()
              if environ_update:
                  env.update({k: str(v) for k, v in environ_update.items()})
              # Real basic.py runs with ignore_invalid_cwd=True: a cwd that
              # is not an existing directory is silently dropped (effectively
              # cwd=None) instead of killing Popen - the manageiq role calls
              # run_command(['rails', ...], cwd='/var/www/miq/vmdb') before
              # that checkout exists (issue #384).
              if cwd and os.path.isdir(cwd):
                  cwd = os.path.abspath(cwd)
              else:
                  cwd = None
              # Real Popen gets a bytes argv (to_bytes per element), so its
              # OSError text names the missing binary as b'rails' - the
              # exact spelling the composed error text must carry.
              b_args = [str(a).encode('utf-8', 'surrogateescape') for a in argv]
              try:
                  proc = subprocess.Popen(b_args, cwd=cwd, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, env=env)
              except OSError as ex:
                  self.fail_json(rc=ex.errno, stdout='', stderr='',
                                 msg='Error executing command.', cmd=clean_args,
                                 exception=ex)
              except Exception as ex:
                  self.fail_json(rc=257, stdout='', stderr='',
                                 msg='Error executing command.', cmd=clean_args,
                                 exception=ex)
              out, err = proc.communicate()
              rc = proc.returncode
              if check_rc and rc != 0:
                  self.fail_json(msg='Command failed with rc %d: %s'
                                 % (rc, err.decode('utf-8', 'replace')))
              return (rc, out.decode('utf-8', 'replace'),
                      err.decode('utf-8', 'replace'))

          # Mirrors real basic.py's AnsibleModule.get_bin_path
          # (delegate to module_utils.common.process.get_bin_path):
          # absolute paths pass through, then opt_dirs, then PATH. Not
          # found + required fails via fail_json like real basic.py;
          # not required raises ValueError for the caller to catch
          # (systemd_units via linux-system-roles.systemd calls it
          # with neither, and ansible-playbook still succeeds
          # there because systemctl is found).
          def get_bin_path(self, arg, required=False, opt_dirs=None):
              paths = []
              if os.path.isabs(arg):
                  paths.append(arg)
              for d in (opt_dirs or []):
                  paths.append(d)
              paths.extend(os.environ.get('PATH', os.defpath).split(os.pathsep))
              for d in paths:
                  candidate = os.path.join(d, arg)
                  if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                      return candidate
              msg = ('Failed to find required executable "%s" in paths: %s'
                     % (arg, ':'.join(paths)))
              if required:
                  self.fail_json(msg=msg)
              raise ValueError(msg)

          def exit_json(self, **kwargs):
              self._pull_global_warnings()
              result = dict(kwargs)
              result.setdefault('changed', False)
              # Real _return_formatted (2.21) injects `invocation` only when
              # the action layer passed `_ansible_inject_invocation`, and
              # pops it otherwise - before the derived *_lines and warnings
              # keys are added, so `invocation` sits before those in the
              # dumped dict when present.
              if self._inject_invocation:
                  if 'invocation' not in result:
                      result['invocation'] = {'module_args': self.params}
              else:
                  result.pop('invocation', None)
              # Real _return_formatted adds the <key>_lines companions for
              # stdout/stderr whenever those keys exist (empty list for an
              # empty string) - a result carrying stdout without them
              # diverges from real's dumped result shape.
              if 'stdout' in result:
                  result['stdout_lines'] = str(result['stdout']).splitlines()
              if 'stderr' in result:
                  result['stderr_lines'] = str(result['stderr']).splitlines()
              if self._warnings:
                  result['warnings'] = self._warnings
              sys.stdout.write(json.dumps(result) + '\\n')
              sys.exit(0)

          def fail_json(self, msg='Module failed', **kwargs):
              self._pull_global_warnings()
              # Real fail_json accepts an exception kwarg (run_command's
              # Popen OSError, issue #384): ansible-core 2.19 composes the
              # task error header as "<msg>: <exception str>" from the
              # ErrorSummary chain while the dumped result keeps the bare
              # msg and drops the exception key entirely. The exception str
              # rides the internal _ansible_error_exception key instead -
              # the py_module runner forwards _ansible_* keys and the
              # controller composes from it without ever dumping it.
              exception = kwargs.pop('exception', None)
              result = dict(kwargs)
              result['failed'] = True
              result['msg'] = msg
              # Same inject-or-pop gate as exit_json above (real
              # _return_formatted runs for both exits).
              if self._inject_invocation:
                  if 'invocation' not in result:
                      result['invocation'] = {'module_args': self.params}
              else:
                  result.pop('invocation', None)
              # Only a real exception object builds an ErrorSummary chain in
              # real fail_json; a plain-string traceback is just hidden
              # (issue #557) and must not reach the error header.
              if isinstance(exception, BaseException):
                  result['_ansible_error_exception'] = str(exception)
              if 'stdout' in result:
                  result['stdout_lines'] = str(result['stdout']).splitlines()
              if 'stderr' in result:
                  result['stderr_lines'] = str(result['stderr']).splitlines()
              if self._warnings:
                  result['warnings'] = self._warnings
              sys.stdout.write(json.dumps(result) + '\\n')
              sys.exit(1)
      PYTHON

    # Writes the shim bundle above into *work_dir* as a
    # ansible/module_utils package tree. The module script itself sits in
    # work_dir too, and Python puts the script's own directory first on
    # sys.path - so the shim shadows any installed ansible-core exactly
    # when it's written, and the import resolves to it instead of dying
    # with ModuleNotFoundError. Written for EVERY new-style python
    # module run (see py_module.cr): shadowing the target's own
    # ansible-core unconditionally is what real's AnsiballZ payload
    # does (it bundles the controller's module_utils), and it keeps the
    # invocation echo independent of which ansible-core version the
    # target happens to carry (issue #915).
    def self.write_module_utils_bundle(work_dir : String) : Nil
      package_init = File.join(work_dir, "ansible", "__init__.py")
      module_utils_init = File.join(work_dir, "ansible", "module_utils", "__init__.py")
      basic_py = File.join(work_dir, "ansible", "module_utils", "basic.py")
      Dir.mkdir_p(File.dirname(package_init))
      Dir.mkdir_p(File.dirname(module_utils_init))
      File.write(package_init, "")
      File.write(module_utils_init, "")
      File.write(basic_py, BASIC_PY_SHIM)
      File.write(File.join(work_dir, "ansible", "module_utils", "distro.py"), DISTRO_PY_SHIM)
      File.write(File.join(work_dir, "ansible", "module_utils", "_text.py"), TEXT_PY_SHIM)
      File.write(File.join(work_dir, "ansible", "module_utils", "urls.py"), URLS_PY_SHIM)
      common_init = File.join(work_dir, "ansible", "module_utils", "common", "__init__.py")
      text_init = File.join(work_dir, "ansible", "module_utils", "common", "text", "__init__.py")
      Dir.mkdir_p(File.dirname(common_init))
      Dir.mkdir_p(File.dirname(text_init))
      File.write(common_init, "")
      File.write(text_init, "")
      six_init = File.join(work_dir, "ansible", "module_utils", "six", "__init__.py")
      Dir.mkdir_p(File.dirname(six_init))
      File.write(six_init, SIX_PY_SHIM)
      File.write(File.join(work_dir, "ansible", "module_utils", "common", "text", "converters.py"), CONVERTERS_PY_SHIM)
      File.write(File.join(work_dir, "ansible", "module_utils", "common", "dict_transformations.py"), DICT_TRANSFORMATIONS_PY_SHIM)
      File.write(File.join(work_dir, "ansible", "module_utils", "common", "warnings.py"), WARNINGS_PY_SHIM)
      parsing_init = File.join(work_dir, "ansible", "module_utils", "parsing", "__init__.py")
      Dir.mkdir_p(File.dirname(parsing_init))
      File.write(parsing_init, "")
      File.write(File.join(work_dir, "ansible", "module_utils", "parsing", "convert_bool.py"), CONVERT_BOOL_PY_SHIM)
      File.write(File.join(work_dir, "ansible", "module_utils", "ansible_release.py"), ANSIBLE_RELEASE_PY_SHIM)
    end

    # ansible-core vendors the python-distro project inside module_utils
    # (`ansible/module_utils/distro/`) and ships it in every module
    # payload, so role-private modules detect the target distribution
    # without python3-distro being installed on it. This engine runs the
    # raw module script instead, so on a target without ansible-core the
    # `from ansible.module_utils import distro` import died with
    # "cannot import name 'distro' from 'ansible.module_utils'" and the
    # module printed no result JSON - hard-FAILING the task where
    # ansible ran it successfully (found via bodsch.php: both of its own
    # library/php_version.py and library/php_modules.py import distro and
    # gate their package-manager search on the returned distribution id,
    # so the role died at its very first custom-module task). The shim
    # covers python-distro's documented surface over the same files
    # upstream python-distro reads - /etc/os-release, then
    # /usr/lib/os-release, then /etc/lsb-release - including the
    # `linux_distribution(full_distribution_name=...)` compatibility
    # tuple both bodsch modules call - the shim always wins over the
    # target's own ansible-core now (issue #915), so this surface is
    # what every target sees.
    DISTRO_PY_SHIM = <<-PYTHON
      def _os_release():
          for path in ("/etc/os-release", "/usr/lib/os-release"):
              try:
                  with open(path, "r", encoding="utf-8", errors="replace") as fh:
                      data = {}
                      for line in fh:
                          line = line.strip()
                          if not line or line.startswith("#") or "=" not in line:
                              continue
                          key, _, value = line.partition("=")
                          value = value.strip()
                          if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                              value = value[1:-1]
                          data[key.strip()] = value
                      return data
              except OSError:
                  continue
          return {}


      def _lsb_release():
          try:
              with open("/etc/lsb-release", "r", encoding="utf-8", errors="replace") as fh:
                  data = {}
                  for line in fh:
                      line = line.strip()
                      if not line or line.startswith("#") or "=" not in line:
                          continue
                      key, _, value = line.partition("=")
                      data[key.strip()] = value.strip()
                  return data
          except OSError:
              return {}


      def id():
          return _os_release().get("ID", "").lower()


      def name(pretty=False):
          info = _os_release()
          if pretty:
              return info.get("PRETTY_NAME", "") or info.get("NAME", "")
          return info.get("NAME", "")


      def version(best=False):
          info = _os_release()
          version_id = info.get("VERSION_ID", "")
          if version_id:
              return version_id
          version_text = info.get("VERSION", "")
          if version_text:
              text = version_text.split("(", 1)[0].strip()
              return text.split(" ")[0] if text else ""
          return ""


      def codename():
          info = _os_release()
          result = info.get("VERSION_CODENAME", "")
          if not result:
              result = _lsb_release().get("DISTRIB_CODENAME", "")
          if not result:
              version_text = info.get("VERSION", "")
              if "(" in version_text and ")" in version_text:
                  result = version_text.split("(", 1)[1].split(")", 1)[0].strip()
          return result


      def like():
          return _os_release().get("ID_LIKE", "")


      def version_parts(best=False):
          text = version(best)
          parts = (text.split(".") + ["", "", ""])[:3]
          return tuple(parts)


      def major_version(best=False):
          return version_parts(best)[0]


      def minor_version(best=False):
          return version_parts(best)[1]


      def build_number(best=False):
          return version_parts(best)[2]


      def linux_distribution(full_distribution_name=True):
          # Upstream python-distro's compat shim calls name() WITHOUT
          # pretty=True here, so the full name is os-release NAME
          # ("Ubuntu"), not PRETTY_NAME ("Ubuntu 22.04.4 LTS").
          distro_name = name() if full_distribution_name else id()
          return (distro_name, version(), codename())


      def info(best=False):
          return {
              "id": id(),
              "version": version(best),
              "like": like(),
              "codename": codename(),
          }


      def os_release_attr(attribute):
          return _os_release().get(attribute, "")


      def lsb_release_attr(attribute):
          return _lsb_release().get(attribute, "")


      def best_version():
          return version(best=True)


      def main():
          pass
      PYTHON

    # The `ansible/module_utils/_text` helpers a new-style module can
    # import DIRECTLY alongside basic (nbde_server_tang via
    # linux-system-roles.nbde_server does
    # `from ansible.module_utils._text import to_native`) - without
    # this file the import dies with ModuleNotFoundError at module top
    # level, before AnsibleModule is ever constructed. Only the
    # to_bytes/to_text/to_native surface modules actually import; the
    # error-handler spellings real _text.py maps (surrogate_or_strict
    # et al) become surrogateescape on py3 like the real code.
    TEXT_PY_SHIM = <<-PYTHON
      def to_bytes(value, errors='surrogate_or_strict', encoding='utf-8'):
          if isinstance(value, bytes):
              return value
          if errors in ('surrogate_or_strict', 'surrogate_or_replace',
                        'surrogate_or_xmltext', 'surrogate_then_replace'):
              errors = 'surrogateescape'
          try:
              return str(value).encode(encoding, errors)
          except (UnicodeEncodeError, LookupError):
              return str(value).encode(encoding, 'replace')

      def to_text(value, errors='surrogate_or_strict', encoding='utf-8'):
          if isinstance(value, bytes):
              if errors in ('surrogate_or_strict', 'surrogate_or_replace',
                            'surrogate_or_xmltext', 'surrogate_then_replace'):
                  errors = 'surrogateescape'
              try:
                  return value.decode(encoding, errors)
              except (UnicodeDecodeError, LookupError):
                  return value.decode(encoding, 'replace')
          if isinstance(value, str):
              return value
          return str(value)

      def to_native(value, errors='surrogate_or_strict', encoding='utf-8'):
          return to_text(value, errors, encoding)

      def to_basestring(value):
          return to_text(value)
      PYTHON

    # `ansible.module_utils.urls` - role-private modules fetch URLs with
    # `open_url` (kazoo-ansible.common's own library/publicip.py does
    # `from ansible.module_utils.urls import *` and then open_url, issue
    # #826: on a target without ansible-core the import died with
    # "No module named 'ansible.module_utils.urls'", hard-failing the
    # task where ansible - whose AnsiballZ payload bundles the real
    # urls.py - ran the same module past the import, into its own
    # bytes-JSON failure). Only the open_url surface such modules call
    # is covered, over python's own urllib: the real call signature and
    # defaults (timeout=10, validate_certs=True), a .read() that returns
    # bytes like the real response, and 'urllib2' redirect semantics
    # that are urllib's own. Client certificates, cookies and
    # unix-socket transports stay uncovered - no shim-covered module
    # uses them, and a wrong guess would mask real behavior.
    URLS_PY_SHIM = <<-PYTHON
      import urllib.request as _urllib_request
      import ssl as _ssl


      def open_url(url, data=None, headers=None, method=None, use_proxy=True,
                   force=False, timeout=10, validate_certs=True,
                   url_username=None, url_password=None, http_agent=None,
                   force_basic_auth=False, follow_redirects='urllib2',
                   client_cert=None, client_key=None, cookies=None,
                   unix_socket=None, ca_path=None, unredirected_headers=None,
                   **kwargs):
          req = _urllib_request.Request(url, data=data, headers=headers or {}, method=method)
          if http_agent:
              req.add_header('User-agent', http_agent)
          context = None
          if url.lower().startswith('https'):
              context = _ssl.create_default_context(cafile=ca_path)
              if not validate_certs:
                  context.check_hostname = False
                  context.verify_mode = _ssl.CERT_NONE
          return _urllib_request.urlopen(req, timeout=timeout, context=context)
      PYTHON

    # `ansible.module_utils.six` - ansible-core's own vendored copy of the
    # six compatibility library, bundled into every AnsiballZ module
    # payload. Custom modules and collections import it directly
    # (`from ansible.module_utils.six import string_types`, and amazon.aws'
    # own module_utils do the same, issue #903), so it resolves under
    # ansible-playbook on a target that has no ansible-core installed at
    # all. This bundle is written both for an ansible-core-less target and
    # unconditionally whenever a role ships its own module_utils tree - and
    # in that second case it SHADOWS an installed ansible-core (the module
    # file's own directory is sys.path[0]), which made the import fail
    # exactly where ansible-playbook succeeded. six ships as a PACKAGE
    # (`six/__init__.py`), the same shape ansible-core uses, because
    # modules also import its `six.moves` submodules
    # (`from ansible.module_utils.six.moves import ...`,
    # `...six.moves.urllib.parse`). Python-3 targets are all this shim has
    # to cover - the py2 branches of six 1.16 are dead code there - but
    # the public surface (type aliases, iterator/view helpers, moves,
    # with_metaclass/add_metaclass, ensure_*, reraise/raise_from) is
    # complete so a module behaves exactly as it does against the real one.
    SIX_PY_SHIM = <<-PYTHON
      """Vendored `six` (its Python 3 surface, six 1.16 API)."""

      import functools
      import importlib
      import importlib.util
      import io
      import operator
      import sys
      import types
      import unittest
      from collections import abc as _collections_abc

      __version__ = "1.16.0"
      __author__ = "Benjamin Peterson <benjamin@python.org>"

      PY2 = False
      PY3 = True
      PY34 = True
      PY35 = True
      PY36 = True
      PY37 = True
      PY38 = True
      PY39 = True

      string_types = (str,)
      integer_types = (int,)
      class_types = (type,)
      text_type = str
      binary_type = bytes
      MAXSIZE = sys.maxsize
      Iterator = _collections_abc.Iterator
      Iterable = _collections_abc.Iterable

      advance_iterator = next
      next = next
      callable = callable
      print_ = print
      wraps = functools.wraps


      def add_move(move):
          """Add an item to six.moves."""
          setattr(moves, move.name, move)


      def remove_move(name):
          try:
              delattr(moves, name)
          except AttributeError:
              raise AttributeError("no such move, %r" % (name,))


      def get_unbound_function(unbound):
          return unbound


      create_bound_method = types.MethodType


      def create_unbound_method(func, cls):
          return func


      def iterkeys(d, **kw):
          return iter(d.keys(**kw))


      def itervalues(d, **kw):
          return iter(d.values(**kw))


      def iteritems(d, **kw):
          return iter(d.items(**kw))


      def iterlists(d, **kw):
          return iter(d.lists(**kw))


      def keys(d, **kw):
          return d.keys(**kw)


      def values(d, **kw):
          return d.values(**kw)


      def items(d, **kw):
          return d.items(**kw)


      def lists(d, **kw):
          return d.lists(**kw)


      viewkeys = keys
      viewvalues = values
      viewitems = items
      viewlists = lists

      get_method_function = operator.attrgetter("__func__")
      get_method_self = operator.attrgetter("__self__")
      get_function_closure = operator.attrgetter("__closure__")
      get_function_code = operator.attrgetter("__code__")
      get_function_defaults = operator.attrgetter("__defaults__")
      get_function_globals = operator.attrgetter("__globals__")

      StringIO = io.StringIO
      BytesIO = io.BytesIO

      assertCountEqual = unittest.TestCase.assertCountEqual
      assertRaisesRegex = unittest.TestCase.assertRaisesRegex
      assertRegex = unittest.TestCase.assertRegex
      assertNotRegex = unittest.TestCase.assertNotRegex


      def b(s):
          return s.encode("latin-1")


      def u(s):
          return s


      def int2byte(i):
          return bytes((i,))


      def byte2int(bs):
          return bs[0]


      def indexbytes(buf, i):
          return buf[i]


      def iterbytes(buf):
          return iter(buf)


      def with_metaclass(meta, *bases):
          class metaclass(type):
              def __new__(cls, name, this_bases, d):
                  if sys.version_info[:2] >= (3, 7):
                      resolved_bases = types.resolve_bases(bases)
                      if resolved_bases is not bases:
                          d["__orig_bases__"] = bases
                  else:
                      resolved_bases = bases
                  return meta(name, resolved_bases, d)

              @classmethod
              def __prepare__(cls, name, this_bases):
                  return meta.__prepare__(name, bases)

          return type.__new__(metaclass, "temporary_class", (), {})


      def add_metaclass(metaclass):
          def wrapper(cls):
              orig_vars = cls.__dict__.copy()
              slots = orig_vars.get("__slots__")
              if slots is not None:
                  if isinstance(slots, str):
                      slots = [slots]
                  for slots_var in slots:
                      orig_vars.pop(slots_var)
              orig_vars.pop("__dict__", None)
              orig_vars.pop("__weakref__", None)
              if hasattr(cls, "__qualname__"):
                  orig_vars["__qualname__"] = cls.__qualname__
              return metaclass(cls.__name__, cls.__bases__, orig_vars)

          return wrapper


      def ensure_binary(s, encoding="utf-8", errors="strict"):
          if isinstance(s, binary_type):
              return s
          if isinstance(s, text_type):
              return s.encode(encoding, errors)
          raise TypeError("not expecting type '%s'" % type(s))


      def ensure_str(s, encoding="utf-8", errors="strict"):
          if not isinstance(s, (text_type, binary_type)):
              raise TypeError("not expecting type '%s'" % type(s))
          if isinstance(s, binary_type):
              s = s.decode(encoding, errors)
          return s


      def ensure_text(s, encoding="utf-8", errors="strict"):
          if isinstance(s, binary_type):
              return s.decode(encoding, errors)
          elif isinstance(s, text_type):
              return s
          else:
              raise TypeError("not expecting type '%s'" % type(s))


      def python_2_unicode_compatible(klass):
          return klass


      def reraise(tp, value, tb=None):
          try:
              if value is None:
                  value = tp()
              if value.__traceback__ is not tb:
                  raise value.with_traceback(tb)
              raise value
          finally:
              value = None
              tb = None


      def raise_from(value, from_value):
          raise value from from_value


      _MOVES = {
          "cStringIO": ("io", "StringIO"),
          "filter": ("builtins", "filter"),
          "filterfalse": ("itertools", "filterfalse"),
          "input": ("builtins", "input"),
          "intern": ("sys", "intern"),
          "map": ("builtins", "map"),
          "getcwd": ("os", "getcwd"),
          "getcwdb": ("os", "getcwdb"),
          "getoutput": ("subprocess", "getoutput"),
          "range": ("builtins", "range"),
          "reload_module": ("importlib", "reload"),
          "reduce": ("functools", "reduce"),
          "shlex_quote": ("shlex", "quote"),
          "StringIO": ("io", "StringIO"),
          "UserDict": ("collections", "UserDict"),
          "UserList": ("collections", "UserList"),
          "UserString": ("collections", "UserString"),
          "xrange": ("builtins", "range"),
          "zip": ("builtins", "zip"),
          "zip_longest": ("itertools", "zip_longest"),
          "builtins": ("builtins", None),
          "configparser": ("configparser", None),
          "collections_abc": ("collections.abc", None),
          "copyreg": ("copyreg", None),
          "dbm_gnu": ("dbm.gnu", None),
          "dbm_ndbm": ("dbm.ndbm", None),
          "_dummy_thread": ("_thread", None),
          "http_cookiejar": ("http.cookiejar", None),
          "http_cookies": ("http.cookies", None),
          "html_entities": ("html.entities", None),
          "html_parser": ("html.parser", None),
          "http_client": ("http.client", None),
          "email_mime_base": ("email.mime.base", None),
          "email_mime_image": ("email.mime.image", None),
          "email_mime_multipart": ("email.mime.multipart", None),
          "email_mime_nonmultipart": ("email.mime.nonmultipart", None),
          "email_mime_text": ("email.mime.text", None),
          "BaseHTTPServer": ("http.server", None),
          "CGIHTTPServer": ("http.server", None),
          "SimpleHTTPServer": ("http.server", None),
          "cPickle": ("pickle", None),
          "queue": ("queue", None),
          "reprlib": ("reprlib", None),
          "socketserver": ("socketserver", None),
          "_thread": ("_thread", None),
          "tkinter": ("tkinter", None),
          "tkinter_dialog": ("tkinter.dialog", None),
          "tkinter_filedialog": ("tkinter.filedialog", None),
          "tkinter_scrolledtext": ("tkinter.scrolledtext", None),
          "tkinter_simpledialog": ("tkinter.simpledialog", None),
          "tkinter_tix": ("tkinter.tix", None),
          "tkinter_ttk": ("tkinter.ttk", None),
          "tkinter_constants": ("tkinter.constants", None),
          "tkinter_dnd": ("tkinter.dnd", None),
          "tkinter_colorchooser": ("tkinter.colorchooser", None),
          "tkinter_commondialog": ("tkinter.commondialog", None),
          "tkinter_tkfiledialog": ("tkinter.filedialog", None),
          "tkinter_font": ("tkinter.font", None),
          "tkinter_messagebox": ("tkinter.messagebox", None),
          "tkinter_tksimpledialog": ("tkinter.simpledialog", None),
          "xmlrpc_client": ("xmlrpc.client", None),
          "xmlrpc_server": ("xmlrpc.server", None),
      }

      if sys.platform == "win32":
          _MOVES["winreg"] = ("winreg", None)

      _MOVES_PREFIX = __name__ + ".moves."


      class _AliasLoader:
          def __init__(self, module):
              self._module = module

          def create_module(self, spec):
              return self._module

          def exec_module(self, module):
              pass


      class _MovesFinder:
          @staticmethod
          def find_spec(fullname, path=None, target=None):
              if not fullname.startswith(_MOVES_PREFIX):
                  return None
              entry = _MOVES.get(fullname[len(_MOVES_PREFIX):])
              if entry is None or entry[1] is not None:
                  return None
              try:
                  module = importlib.import_module(entry[0])
              except ImportError:
                  return None
              return importlib.util.spec_from_loader(fullname, _AliasLoader(module))


      class _MovesModule(types.ModuleType):
          def __getattr__(self, name):
              entry = _MOVES.get(name)
              if entry is None:
                  raise AttributeError("module %r has no attribute %r" % (self.__name__, name))
              target = importlib.import_module(entry[0])
              return target if entry[1] is None else getattr(target, entry[1])


      moves = _MovesModule(_MOVES_PREFIX[:-1])
      moves.__path__ = []

      _urllib = types.ModuleType(_MOVES_PREFIX + "urllib")
      _urllib.__path__ = []
      for _suffix in ("parse", "error", "request", "response", "robotparser"):
          _real = importlib.import_module("urllib." + _suffix)
          setattr(_urllib, _suffix, _real)
          sys.modules[_MOVES_PREFIX + "urllib." + _suffix] = _real
          sys.modules[_MOVES_PREFIX + "urllib_" + _suffix] = _real
      setattr(moves, "urllib", _urllib)
      sys.modules[_MOVES_PREFIX + "urllib"] = _urllib
      sys.modules[_MOVES_PREFIX[:-1]] = moves
      sys.meta_path.append(_MovesFinder)
      PYTHON

    # In modern ansible-core the real text-conversion implementation
    # moved from `the Ansible module` to
    # `the Ansible module` - `_text` remains
    # only as a deprecated re-export shim - and newer roles import the
    # new path directly. bodsch.users' own library/multi_users.py does
    # exactly that (`from ansible.module_utils.common.text.converters
    # import to_native`, round 813275) and died with
    # ModuleNotFoundError: No module named 'ansible.module_utils.common'
    # on a target without ansible-core, while Ansible - which ships
    # both paths - succeeded on the same task. So this file ships
    # alongside _text.py, self-contained rather than importing from it,
    # since role code may import either path (or both) and Ansible
    # keeps both importable. Same to_bytes/to_text/to_native surface and
    # the same surrogateescape mapping of the Ansible error-handler
    # spellings as the _text shim above.
    CONVERTERS_PY_SHIM = <<-PYTHON
      def to_bytes(value, errors='surrogate_or_strict', encoding='utf-8'):
          if isinstance(value, bytes):
              return value
          if errors in ('surrogate_or_strict', 'surrogate_or_replace',
                        'surrogate_or_xmltext', 'surrogate_then_replace'):
              errors = 'surrogateescape'
          try:
              return str(value).encode(encoding, errors)
          except (UnicodeEncodeError, LookupError):
              return str(value).encode(encoding, 'replace')

      def to_text(value, errors='surrogate_or_strict', encoding='utf-8'):
          if isinstance(value, bytes):
              if errors in ('surrogate_or_strict', 'surrogate_or_replace',
                            'surrogate_or_xmltext', 'surrogate_then_replace'):
                  errors = 'surrogateescape'
              try:
                  return value.decode(encoding, errors)
              except (UnicodeDecodeError, LookupError):
                  return value.decode(encoding, 'replace')
          if isinstance(value, str):
              return value
          return str(value)

      def to_native(value, errors='surrogate_or_strict', encoding='utf-8'):
          return to_text(value, errors, encoding)

      def to_basestring(value):
          return to_text(value)
      PYTHON

    # The dict-conversion helpers ansible-core ships at
    # ansible/module_utils/common/dict_transformations - the camel/snake
    # dict converters most amazon.aws-style modules run their facts
    # through. A custom module importing it at top level (issue #779)
    # died with ModuleNotFoundError: No module named
    # 'ansible.module_utils.common.dict_transformations' on a target
    # where the shim bundle stood in for ansible-core, while Ansible -
    # which bundles every module_utils import into the AnsiballZ
    # payload - ran the module fine. Adopted from ansible-core's own
    # file (same GPL-3.0 family) so the conversion semantics - the
    # ARNs-pluralization case in _camel_to_snake, the reversible flag,
    # recursive_diff's TypeError shape - match exactly rather than
    # approximately.
    DICT_TRANSFORMATIONS_PY_SHIM = <<-PYTHON
      import re
      from collections.abc import MutableMapping
      from copy import deepcopy


      def camel_dict_to_snake_dict(camel_dict, reversible=False, ignore_list=()):
          def value_is_list(camel_list):
              checked_list = []
              for item in camel_list:
                  if isinstance(item, dict):
                      checked_list.append(camel_dict_to_snake_dict(item, reversible))
                  elif isinstance(item, list):
                      checked_list.append(value_is_list(item))
                  else:
                      checked_list.append(item)
              return checked_list

          snake_dict = {}
          for k, v in camel_dict.items():
              if isinstance(v, dict) and k not in ignore_list:
                  snake_dict[_camel_to_snake(k, reversible=reversible)] = camel_dict_to_snake_dict(v, reversible)
              elif isinstance(v, list) and k not in ignore_list:
                  snake_dict[_camel_to_snake(k, reversible=reversible)] = value_is_list(v)
              else:
                  snake_dict[_camel_to_snake(k, reversible=reversible)] = v
          return snake_dict


      def snake_dict_to_camel_dict(snake_dict, capitalize_first=False):
          def camelize(complex_type, capitalize_first=False):
              if complex_type is None:
                  return
              new_type = type(complex_type)()
              if isinstance(complex_type, dict):
                  for key in complex_type:
                      new_type[_snake_to_camel(key, capitalize_first)] = camelize(complex_type[key], capitalize_first)
              elif isinstance(complex_type, list):
                  for i in range(len(complex_type)):
                      new_type.append(camelize(complex_type[i], capitalize_first))
              else:
                  return complex_type
              return new_type

          return camelize(snake_dict, capitalize_first)


      def _snake_to_camel(snake, capitalize_first=False):
          if capitalize_first:
              return ''.join(x.capitalize() or '_' for x in snake.split('_'))
          else:
              return snake.split('_')[0] + ''.join(x.capitalize() or '_' for x in snake.split('_')[1:])


      def _camel_to_snake(name, reversible=False):
          def prepend_underscore_and_lower(m):
              return '_' + m.group(0).lower()

          if reversible:
              upper_pattern = r'[A-Z]'
          else:
              # Cope with pluralized abbreviations such as TargetGroupARNs
              # that would otherwise be rendered target_group_ar_ns
              upper_pattern = r'[A-Z]{3,}s$'

          s1 = re.sub(upper_pattern, prepend_underscore_and_lower, name)
          # Handle when there was nothing before the plural_pattern
          if s1.startswith("_") and not name.startswith("_"):
              s1 = s1[1:]
          if reversible:
              return s1

          first_cap_pattern = r'(.)([A-Z][a-z]+)'
          all_cap_pattern = r'([a-z0-9])([A-Z]+)'
          s2 = re.sub(first_cap_pattern, r'\\1_\\2', s1)
          return re.sub(all_cap_pattern, r'\\1_\\2', s2).lower()


      def dict_merge(a, b):
          if not isinstance(b, dict):
              return b
          result = deepcopy(a)
          for k, v in b.items():
              if k in result and isinstance(result[k], dict):
                  result[k] = dict_merge(result[k], v)
              else:
                  result[k] = deepcopy(v)
          return result


      def recursive_diff(dict1, dict2):
          if not all((isinstance(item, MutableMapping) for item in (dict1, dict2))):
              raise TypeError("Unable to diff 'dict1' %s and 'dict2' %s. "
                              "Both must be a dictionary." % (type(dict1), type(dict2)))

          left = dict((k, v) for (k, v) in dict1.items() if k not in dict2)
          right = dict((k, v) for (k, v) in dict2.items() if k not in dict1)
          for k in (set(dict1.keys()) & set(dict2.keys())):
              if isinstance(dict1[k], dict) and isinstance(dict2[k], dict):
                  result = recursive_diff(dict1[k], dict2[k])
                  if result:
                      left[k] = result[0]
                      right[k] = result[1]
              elif dict1[k] != dict2[k]:
                  left[k] = dict1[k]
                  right[k] = dict2[k]
          if left or right:
              return left, right
          return None
      PYTHON

    # ansible.module_utils.parsing.convert_bool - the BOOLEANS_TRUE/
    # BOOLEANS_FALSE tables and boolean() converter, which custom modules
    # import directly when they parse a loose boolean themselves (the
    # same tables this engine's own argspec validator emulates). Surveyed
    # beside issue #779 as the other small pure module_utils file a
    # role-private module most often imports that the shim bundle lacked;
    # adopted from ansible-core's own file minus the _no_six deprecation
    # hook (a py2-compat remnant no py3 module path exercises).
    CONVERT_BOOL_PY_SHIM = <<-PYTHON
      import collections.abc

      from ansible.module_utils.common.text.converters import to_text


      BOOLEANS_TRUE = frozenset(('y', 'yes', 'on', '1', 'true', 't', 1, 1.0, True))
      BOOLEANS_FALSE = frozenset(('n', 'no', 'off', '0', 'false', 'f', 0, 0.0, False))
      BOOLEANS = BOOLEANS_TRUE.union(BOOLEANS_FALSE)


      def boolean(value, strict=True):
          if isinstance(value, bool):
              return value

          normalized_value = value

          if isinstance(value, (str, bytes)):
              normalized_value = to_text(value, errors='surrogate_or_strict').lower().strip()

          if not isinstance(value, collections.abc.Hashable):
              normalized_value = None

          if normalized_value in BOOLEANS_TRUE:
              return True
          elif normalized_value in BOOLEANS_FALSE or not strict:
              return False

          raise TypeError("The value '%s' is not a valid boolean. Valid booleans include: %s" % (to_text(value), ', '.join(repr(i) for i in BOOLEANS)))
      PYTHON

    # ansible-core's ansible/module_utils/ansible_release.py is the
    # running release's own metadata, and modules read `__version__` out
    # of it (a module built on amazon.aws' module_utils, which import it,
    # failed with "No module named 'ansible.module_utils.ansible_release'"
    # under the shim bundle - issue #843 - while ansible-playbook, whose
    # AnsiballZ payload bundles the file, ran it). The version is the
    # ansible-core release this engine reproduces (ANSIBLE_TARGET_VERSION,
    # the same value the `ansible_version` magic variable reports) rather
    # than a second literal, so it tracks a compatibility-target bump.
    ANSIBLE_RELEASE_PY_SHIM = <<-python
      __version__ = '#{ANSIBLE_TARGET_VERSION}'
      __author__ = 'Ansible, Inc.'
      __codename__ = 'What Is and What Should Never Be'
      python

    # ansible.module_utils.common.warnings - the global warning and
    # deprecation accumulators real basic.py merges into the module result
    # (kwargs['warnings'] = get_warnings()). Modules importing warn or
    # deprecate directly (issue #908: a custom module importing warn, the
    # same import amazon.aws' AnsibleAWSModule tree uses) died with
    # ModuleNotFoundError under the shim bundle, which lacked the file,
    # while ansible-playbook's AnsiballZ payload ran it. The shim carries
    # the same warn/deprecate/get_warning_messages/get_deprecation_messages/
    # get_warnings/get_deprecations/error_as_warning surface and tracks
    # messages as plain strings so the shim's basic.py pulls them into
    # result['warnings'] the way real does.
    WARNINGS_PY_SHIM = <<-PYTHON
      _global_warnings = {}
      _global_deprecations = {}


      def _record_warning(message):
          _global_warnings[str(message)] = None


      def warn(warning, *, help_text=None, obj=None):
          _record_warning(warning)


      def error_as_warning(msg, exception, *, help_text=None, obj=None):
          _record_warning(msg or str(exception))


      def deprecate(msg, version=None, date=None, collection_name=None, *, deprecator=None, help_text=None, obj=None):
          if version:
              text = '%s (version %s)' % (msg, version)
          elif date:
              text = '%s (removed in %s)' % (msg, date)
          else:
              text = 'DEPRECATED: %s' % msg
          _global_deprecations[text] = None


      def get_warning_messages():
          return tuple(_global_warnings)


      def get_deprecation_messages():
          return tuple({'msg': text, 'collection_name': None, 'version': None} for text in _global_deprecations)


      def get_warnings():
          return list(_global_warnings)


      def get_deprecations():
          return list(_global_deprecations)
      PYTHON

    # Parses the module's stdout into its result JSON: Ansible modules
    # print a JSON object (pretty or single-line), possibly preceded by
    # other output (warnings, prints) that Ansible also strips.
    # Walks backwards from the end for the first offset where a JSON
    # object parse succeeds.
    def parse_module_output(stdout : String) : JSON::Any?
      idx = stdout.size
      while pos = stdout.rindex('{', idx - 1)
        # BigJson, not JSON.parse: a module can print an integer wider
        # than Int64 (Python ints are unbounded), which plain JSON.parse
        # turns into an "Invalid Int64" raise - the whole result silently
        # became nil. The bigint-aware parse marks those literals instead
        # (see Krikri::BigJson), and everything downstream already
        # understands the marker.
        if parsed = (Krikri::BigJson.parse(stdout[pos..]) rescue nil)
          return parsed if parsed.as_h?
        end
        idx = pos
      end
      nil
    end

    # Real basic.py's fail_json(exception=...) wraps the exception in an
    # ErrorSummary event chain whose dumped shape krikri keeps dropping
    # (issue #557: a plain-string traceback is hidden the same way), yet
    # real ansible composes the "[ERROR] <msg>: <cause>" header from the
    # chain's cause messages (issue #384: run_command's missing-binary
    # Popen OSError). Extracts those cause messages, deepest chain included;
    # nil when the result carries no ErrorSummary object.
    def error_exception_summary(result : JSON::Any) : String?
      summary = result["exception"]?.try(&.as_h?)
      return nil unless summary && summary["__ansible_type"]?.try(&.as_s?) == "ErrorSummary"
      msgs = [] of String
      node = summary.dig?("event", "chain")
      while node
        break unless chain = node.as_h?
        if msg = chain.dig?("event", "msg").try(&.as_s?)
          msgs << msg unless msg.empty?
        end
        node = chain.dig?("event", "chain")
      end
      return nil if msgs.empty?
      msgs.join(": ")
    end

    # Recovers the message of a module's uncaught exception from the raw
    # run's stderr. Real Ansible wraps every module run in an Exception
    # handler (AnsiballZ's loader) and reports the exception as a clean
    # module failure - but only Exception: SystemExit,
    # KeyboardInterrupt and GeneratorExit pass through unhandled there,
    # so they return nil here too. "" means the exception had no
    # message (bare `raise SomeError()`, which Ansible spells
    # "Module failed."), nil means no parseable traceback at all. An
    # explicit cause chain (`raise X from Y`) joins each direct cause's
    # message with ": ", outer first, deepest last - the way Ansible's
    # msg renders the chain (issue #523); implicit context ("During
    # handling of the above exception, another exception occurred")
    # contributes nothing, keeping only the final traceback's message.
    def uncaught_exception_detail(stderr : String) : String?
      marker = "Traceback (most recent call last):"
      final_idx = stderr.rindex(marker)
      return nil unless final_idx
      pair = traceback_message(stderr[(final_idx + marker.size)..])
      return nil unless pair
      detail, exc_class = pair
      return nil if exc_class.in?("SystemExit", "KeyboardInterrupt", "GeneratorExit")
      messages = [detail]
      # Walk backwards across the direct-cause separators, keeping only
      # explicit cause links: `raise X from Y` prints Y's section first, then
      # the separator, then X's traceback. The separator must sit directly
      # before the section it causes (blank lines only in between), and an
      # unparseable cause ends the chain.
      cursor = final_idx
      loop do
        break unless cursor > 0
        sep_idx = stderr.rindex(DIRECT_CAUSE_SEPARATOR, cursor - 1)
        break unless sep_idx
        gap = stderr[(sep_idx + DIRECT_CAUSE_SEPARATOR.size)...cursor]
        break unless gap.blank?
        pair = cause_message(stderr[0...sep_idx])
        break unless pair
        messages << pair[0]
        start = pair[1]
        break unless start
        cursor = start
      end
      messages.join(": ")
    end

    DIRECT_CAUSE_SEPARATOR = "The above exception was the direct cause of the following exception:"

    # The cause section's message and the index of its own traceback header
    # (nil for a cause constructed inline - `raise X from ValueError("msg")`
    # was never raised, so Python prints no "Traceback" header for it and
    # nothing can chain further back). nil when no parseable cause message
    # precedes the separator.
    private def cause_message(text : String) : {String, Int32?}?
      marker = "Traceback (most recent call last):"
      if idx = text.rindex(marker)
        pair = traceback_message(text[(idx + marker.size)..]) || return nil
        return {pair[0], idx}
      end
      lines = text.lines
      i = lines.size - 1
      while i >= 0 && lines[i].empty?
        i -= 1
      end
      msg_lines = [] of String
      while i >= 0
        line = lines[i]
        break if line.empty? || line.starts_with?(' ') || line.starts_with?('\t') ||
                 line.starts_with?(marker) ||
                 line.starts_with?("During handling of the above exception")
        msg_lines << line
        i -= 1
      end
      return nil if msg_lines.empty?
      msg_lines.reverse!
      first = msg_lines.first
      match = first.match(/\A[A-Za-z_][\w.]*/) || return nil
      rest = first[match[0].size..]
      return nil unless rest.empty? || rest.starts_with?(": ")
      detail = rest.empty? ? "" : rest[2..]
      unless msg_lines.size == 1
        detail = "#{detail}\n#{msg_lines[1..].join("\n")}"
      end
      {detail, nil}
    end

    # One traceback section's exception message (leading exception line plus
    # any non-indented continuation lines) and its exception class name.
    # Stops at the next traceback header or chained-exception separator, so
    # an earlier section's parse never swallows the section boundary; nil
    # when the section doesn't open with a parseable exception line.
    private def traceback_message(section : String) : {String, String}?
      msg_lines = [] of String
      section.each_line do |line|
        next if line.empty? || line.starts_with?(' ') || line.starts_with?('\t')
        break if line.starts_with?("Traceback (most recent call last):") ||
                 line.starts_with?("During handling of the above exception") ||
                 line.starts_with?(DIRECT_CAUSE_SEPARATOR)
        msg_lines << line
      end
      first = msg_lines.first?
      return nil unless first
      # An exception line starts with the class name (possibly dotted);
      # anything else means this isn't a parseable Python traceback.
      match = first.match(/\A[A-Za-z_][\w.]*/)
      return nil unless match
      rest = first[match[0].size..]
      return nil unless rest.empty? || rest.starts_with?(": ")
      detail = rest.empty? ? "" : rest[2..]
      if extra = msg_lines[1..]?
        detail = "#{detail}\n#{extra.join("\n")}" unless extra.empty?
      end
      {detail, match[0]}
    end
  end
end
