require "json"
require "base64"

# Runner for role-private custom modules - a role's own `library/*.py`,
# outside the plugin set this engine ships as native binaries. Real
# Ansible executes these as ordinary Python on the target; the previous
# scope cut skipped them with a parse-time "uses unimplemented plugin"
# warning (exit 4 via reachable_unavailable_modules since 0.9.558),
# which diverged on every role leaning on its own library/ - seen
# repeatedly benchmarking linux-system-roles (sr_fingerprint,
# timesync_provider, kernel_settings_get_config, blivet).
#
# The runner delegates to the TARGET's own python3, the same way real
# Ansible does - no Python is embedded or reimplemented here. The
# module source is uploaded and executed through the same plugin-binary
# transport everything else uses (see plugins/py_module.cr), so local
# and SSH connections both work without any new plumbing.
#
# Deliberately scoped to role-private `library/` directories and the
# playbook-adjacent `library/` (real Ansible's two most common search
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
    # Search roots mirror real Ansible's two most-used locations: the
    # current role's own `library/` and the playbook-adjacent
    # `library/`. First match wins (real Ansible's own nearest-first
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
    def find_source(module_name : String, role_path : String?, playbook_dir : String?) : String?
      short = short_name(module_name)
      return nil if short.empty?

      roots = [] of String
      roots << File.join(role_path, "library") if role_path
      roots << File.join(playbook_dir, "library") if playbook_dir && !playbook_dir.empty?

      roots.each do |root|
        candidate = File.join(root, "#{short}.py")
        return candidate if File.file?(candidate)
      end
      nil
    end

    # Real Ansible's own new-style detection (ansiballz): a module
    # importing ansible.module_utils gets its args as a JSON dict (via
    # the ANSIBLE_MODULE_ARGS env var its basic.py reads when no argv
    # is given); everything else is old-style key=value argv.
    def new_style?(source : String) : Bool
      source.includes?("from ansible.module_utils") ||
        source.includes?("import ansible.module_utils") ||
        source.includes?("ansible.module_utils.basic")
    end

    # The module's argument dict: the substituted task params (already
    # stringified by the parser) re-typed as JSON where they parse -
    # the parser JSON-encodes list/dict-valued params verbatim, so
    # `"['a','b']"` becomes a real array for the module, the way real
    # Ansible passes typed args. Plus real Ansible's own reserved
    # `_ansible_*` keys a new-style module's AnsibleModule reads.
    def build_module_args(params : Hash(String, String), check_mode : Bool) : String
      args = Hash(String, JSON::Any).new
      args["_ansible_check_mode"] = JSON::Any.new(check_mode)
      args["_ansible_diff"] = JSON::Any.new(false)
      args["_ansible_verbosity"] = JSON::Any.new(0_i64)
      params.each do |key, value|
        next if key.in?("check_mode", "diff_mode", "_verbosity", "_environment")
        args[key] = typed_value(value)
      end
      args.to_json
    end

    # The old-style key=value argv line (one entry per param).
    def build_kv_argv(params : Hash(String, String)) : Array(String)
      params.reject { |key, _| key.in?("check_mode", "diff_mode", "_verbosity", "_environment") }
        .map do |key, value|
          "#{key}=#{value}"
        end
    end

    private def typed_value(value : String) : JSON::Any
      stripped = value.strip
      if stripped.starts_with?('{') || stripped.starts_with?('[')
        # A magic var like `ansible_play_hosts_all` (a real list) renders
        # through the substitutor as a Python-repr string
        # (`['10.99.1.2']`, single-quoted) rather than valid JSON when a
        # task param references it directly - same Jinja
        # `{% if %}...{{ [list] }}...{% endif %}`-shaped rendering
        # already handled elsewhere in this codebase (package.cr's own
        # `parse_package_names`). Found via linux-system-roles.storage's
        # own `sr_fingerprint: {ansible_play_hosts_all: "{{
        # ansible_play_hosts_all }}", ...}`.
        parsed = begin
          JSON.parse(stripped)
        rescue
          begin
            JSON.parse(stripped.gsub('\'', '"'))
          rescue
            nil
          end
        end
        return parsed if parsed
      end
      return JSON::Any.new(true) if stripped == "true" || stripped == "True"
      return JSON::Any.new(false) if stripped == "false" || stripped == "False"
      return JSON::Any.new(nil) if stripped == "None" || stripped == "null"
      if int = stripped.to_i64?
        return JSON::Any.new(int)
      end
      JSON::Any.new(value)
    end

    # The `ansible/module_utils` bundle a new-style module's
    # `from ansible.module_utils.basic import AnsibleModule` import needs.
    # Real Ansible never relies on ansible-core being installed on the
    # target - the AnsiballZ wrapper bundles module_utils INTO the module
    # payload it ships - so every new-style role-private module runs on
    # any target with a python3. This engine runs the raw module script
    # instead, so on a target with no ansible-core installed the import
    # died with ModuleNotFoundError and the module printed no result JSON
    # ("MODULE FAILURE") - hard-FAILING the task where real Ansible ran
    # it successfully (found via newrelic.newrelic-infra's own
    # "Setup agent config *NIX" task: the role ships its own
    # library/merge_yaml.py, which took the py_module path and failed on
    # every fresh target while real ansible-playbook succeeded). The shim
    # covers what corpus role-private modules actually use - params
    # parsing/validation against argument_spec (with type coercion,
    # defaults, aliases, required), check_mode, exit_json/fail_json,
    # warn/run_command, log, get_bin_path - not the whole real
    # basic.py surface; anything beyond that fails exactly as before
    # this shim existed.
    BASIC_PY_SHIM = <<-PYTHON
      import json
      import os
      import subprocess
      import sys
      import tempfile


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
              self._apply_argument_spec(raw_args)

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
              return value

          def _apply_argument_spec(self, raw_args):
              for key, spec in self.argument_spec.items():
                  for alias in spec.get('aliases', []) or []:
                      if alias in raw_args and key not in raw_args:
                          raw_args[key] = raw_args[alias]
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
              if isinstance(args, str):
                  argv = args.split()
              else:
                  argv = [str(a) for a in args]
              env = os.environ.copy()
              if environ_update:
                  env.update({k: str(v) for k, v in environ_update.items()})
              proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, env=env)
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
          # with neither, and real ansible-playbook still succeeds
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
              msg = ('Failed to find required executable %s in paths: %s'
                     % (arg, ':'.join(paths)))
              if required:
                  self.fail_json(msg=msg)
              raise ValueError(msg)

          def exit_json(self, **kwargs):
              result = dict(kwargs)
              result.setdefault('changed', False)
              if self._warnings:
                  result['warnings'] = self._warnings
              sys.stdout.write(json.dumps(result) + '\\n')
              sys.exit(0)

          def fail_json(self, msg='Module failed', **kwargs):
              result = dict(kwargs)
              result['failed'] = True
              result['msg'] = msg
              if self._warnings:
                  result['warnings'] = self._warnings
              sys.stdout.write(json.dumps(result) + '\\n')
              sys.exit(1)
      PYTHON

    # Writes the shim bundle above into *work_dir* as a real
    # ansible/module_utils package tree. The module script itself sits in
    # work_dir too, and Python puts the script's own directory first on
    # sys.path - so the shim shadows any installed ansible-core exactly
    # when it's written, and the import resolves to it instead of dying
    # with ModuleNotFoundError. Written ONLY for a target where the probe
    # import failed (see py_module.cr): where real ansible-core IS
    # installed the module keeps running against the real basic.py,
    # unchanged from pre-shim behavior.
    def self.write_module_utils_bundle(work_dir : String) : Nil
      package_init = File.join(work_dir, "ansible", "__init__.py")
      module_utils_init = File.join(work_dir, "ansible", "module_utils", "__init__.py")
      basic_py = File.join(work_dir, "ansible", "module_utils", "basic.py")
      Dir.mkdir_p(File.dirname(package_init))
      Dir.mkdir_p(File.dirname(module_utils_init))
      File.write(package_init, "")
      File.write(module_utils_init, "")
      File.write(basic_py, BASIC_PY_SHIM)
    end

    # Parses the module's stdout into its result JSON: real modules
    # print a JSON object (pretty or single-line), possibly preceded by
    # other output (warnings, prints) that real Ansible also strips.
    # Walks backwards from the end for the first offset where a JSON
    # object parse succeeds.
    def parse_module_output(stdout : String) : JSON::Any?
      idx = stdout.size
      while pos = stdout.rindex('{', idx - 1)
        if parsed = (JSON.parse(stdout[pos..]) rescue nil)
          return parsed if parsed.as_h?
        end
        idx = pos
      end
      nil
    end
  end
end
