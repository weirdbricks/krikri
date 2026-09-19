#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Pip plugin - manages Python packages via pip. Compatible with (a
  # subset of) Ansible's ansible.builtin.pip module.
  #
  # Real gap found benchmarking geerlingguy.pip's own "Ensure
  # pip_install_packages are installed." task - entirely unimplemented
  # before (no plugins/pip.cr at all, not in AVAILABLE_PLUGINS), so
  # every real playbook's pip: task was skipped outright ("Plugin not
  # available"), silently never installing anything.
  #
  # Supported parameters:
  # - name (required unless requirements:): a package name, optionally
  #   with a version specifier (`requests==2.31.0`, `flask>=3.0`) -
  #   passed straight through to pip, which already understands this
  #   syntax natively
  # - version: install exactly this version (equivalent to appending
  #   `==version` to name: - real Ansible's own module does the same)
  # - state: present (default) | absent | latest
  # - virtualenv: path to a venv - created via `python3 -m venv` if it
  #   doesn't already exist, and used instead of the system pip
  # - virtualenv_python: python interpreter for `venv` creation
  #   (default: whatever `python3` resolves to)
  # - executable: which pip binary to use when NOT using a virtualenv
  #   (default: "pip3") - mutually exclusive with virtualenv:
  # - extra_args: appended verbatim to the pip command line
  # - chdir: run pip from this directory
  # - requirements: install from a requirements.txt file instead of a
  #   single name: - mutually exclusive with name:
  # - virtualenv_command: command used to create a new virtualenv
  #   (default: "virtualenv", matching real Ansible's argument_spec
  #   default - NOT hardcoded python3 -m venv). A bare name is resolved
  #   on PATH like real Ansible's get_bin_path; a space-separated
  #   command (e.g. `python3 -m venv`, `python -m virtualenv`) is used
  #   as-is like real Ansible's shlex.split of the same value
  # - virtualenv_site_packages: when CREATING a new virtualenv, pass
  #   --system-site-packages (true) or --no-site-packages when the
  #   chosen venv command supports it (false, the default) - mirroring
  #   real Ansible's setup_virtualenv, which probes `<command> --help`
  #   for the latter. No effect on an already-existing virtualenv
  # - break_system_packages: true sets PIP_BREAK_SYSTEM_PACKAGES=1 on
  #   the pip install/uninstall invocation (needed on PEP 668
  #   externally-managed systems). Real Ansible sets the env var rather
  #   than the --break-system-packages CLI flag so pip < 23.0 (which
  #   lacks the flag) still works - the env var is honored by the same
  #   pip versions that grew the flag
  #
  # Validation (mirroring real Ansible's own module-level argument
  # checks, which run before anything else - before pip discovery or
  # any venv creation):
  # - required_one_of name/requirements: neither given fails with real
  #   Ansible's "one of the following is required: name, requirements"
  # - mutually_exclusive name/requirements and executable/virtualenv:
  #   both of a pair given fails with real Ansible's "parameters are
  #   mutually exclusive: <pair>"
  #
  # Idempotency: `present` (no version:) checks `pip show <pkg>` for
  # existence only - already installed at ANY version is a no-op,
  # matching real Ansible's own default behavior (pip: doesn't silently
  # upgrade unless state: latest is explicit). `present` with a
  # version: compares the exact installed version. `latest` always
  # invokes `pip install --upgrade` and inspects its own output for
  # "Requirement already up-to-date" vs. an actual install/upgrade,
  # matching real Ansible's own PipModule.
  #
  # - editable: adds `-e` to extra_args (deduplicated if extra_args
  #   already includes it) - verified against real ansible/modules/
  #   pip.py's own source, `-e` is applied there too rather than as a
  #   separate standalone flag
  # - umask: an octal string, applied via a `umask <value>;` command
  #   prefix (this codebase shells out per-command rather than forking
  #   like real Ansible's own `os.umask()` around the whole run, so a
  #   shell-level `umask` prefix is the equivalent for the single `pip`
  #   invocation either wraps) - fails clearly on an invalid (non-octal)
  #   value, matching real Ansible's own validation message
  #
  # Not implemented: `extra_args:`/`requirements:`'s own check_mode-
  # specific idempotency short-circuit (real Ansible's check_mode always
  # reports changed: true when either is given, rather than attempting
  # an idempotency check it can't reliably make) - moot here, this
  # plugin doesn't implement check_mode at all yet, a separate and much
  # larger pre-existing gap not touched in this pass. Per-package
  # `state: absent` version pinning (uninstall doesn't take a version).
  class PipPlugin < BasePlugin
    # Set by #resolve_pip_binary when THIS task invocation itself created
    # the target virtualenv (it didn't exist before the task ran). Real
    # Ansible's pip module counts creating a virtualenv as a change in
    # its own right, independent of whether the requested package then
    # needed installing - found benchmarking claranet.postgresql, whose
    # `pip: {name: ..., virtualenv: ...}` cold run reported ok/"Package
    # already installed" in krikri (the fresh venv's own bootstrapped
    # pip satisfied `pip show pip`) where real Ansible reported changed.
    @created_virtualenv = false

    def execute : PluginResult
      # Real Ansible's required_one_of / mutually_exclusive checks run
      # inside AnsibleModule.__init__, before main() ever touches pip
      # discovery or venv creation - so a pip-less host with bad
      # arguments fails with the validation message, not the pip
      # discovery one. Same order here.
      if validation_error = argument_validation_error
        return validation_error
      end

      state = @params["state"]? || "present"
      requirements = @params["requirements"]?
      raw_name = @params["name"]?
      name = normalize_name(raw_name)

      # Real Ansible's pip.py resolves (and validates the EXISTENCE of)
      # the pip executable via `get_bin_path` before it ever looks at
      # name:/requirements: at all - a target with no pip/pip3 binary
      # installed anywhere fails immediately with "Unable to find any
      # of pip3 to use.  pip needs to be installed.", REGARDLESS of
      # whether there's actually anything to install. Previously this
      # engine only resolved pip_bin (a bare string, e.g. "pip3") and
      # never checked it actually exists on the target - combined with
      # the empty-name early-return just below, a role whose package
      # list happens to be empty ON THIS OS (buluma.vagrant's own
      # `vagrant_pip_packages: []` on Debian-family, round 180) never
      # even tried to invoke pip at all, silently reporting `ok:`
      # instead of real Ansible's hard failure for a genuinely
      # pip-less host. Skipped for a virtualenv: target - #resolve_pip_
      # binary already creates the venv (and fails there if that
      # itself doesn't work), so its own pip is guaranteed to exist by
      # the time this runs.
      if missing_binary = ensure_pip_binary
        return missing_binary
      end

      # Real Ansible's pip.py: `name` is a list; `if name:` is Python
      # truthiness, so a name: PARAM THAT IS PRESENT but resolves to an
      # EMPTY list (e.g. a templated `name: "{{ some_list_var }}"` that
      # rendered to `[]`) is not an error - it falls straight through to
      # the same "nothing to do" branch pip.py uses, exiting cleanly
      # with changed: false rather than trying to pip-install anything.
      # A name: key that's genuinely absent (not just empty) together
      # with no requirements: is the real required_one_of failure.
      if missing_name = missing_name_result(raw_name, name, requirements)
        return missing_name
      end

      pip_bin = resolve_pip_binary
      return pip_bin if pip_bin.is_a?(PluginResult)

      if bad_umask = umask_error
        return bad_umask
      end

      result = case state
               when "absent"
                 remove(pip_bin, name || raise "pip: name is required with state=absent")
               when "latest"
                 install(pip_bin, target_spec(name, nil), upgrade: true)
               else
                 install(pip_bin, target_spec(name, @params["version"]?), upgrade: false, requirements: requirements)
               end

      overlay_venv_creation_change(result)
    end

    # A venv this task itself created is a change regardless of what the
    # package-install step then did - including the
    # all_packages_satisfied? short-circuit, which for a brand-new venv
    # can legitimately succeed (the spec is already satisfied by
    # whatever pip bootstraps, e.g. name: pip) yet the task still
    # materially created something on the host.
    private def overlay_venv_creation_change(result : PluginResult) : PluginResult
      result.changed = true if @created_virtualenv && !result.failed?
      result
    end

    # Verify pip is usable on the target (skipped for a virtualenv:
    # target - see the caller's comment). Returns the failure result,
    # or nil when a usable pip was found. Mirrors real Ansible's
    # pip.py `_get_pip` discovery order - see #discover_system_pip.
    private def ensure_pip_binary : PluginResult?
      return nil if @params["virtualenv"]?

      result = discover_system_pip
      result.is_a?(PluginResult) ? result : nil
    end

    # Real Ansible's pip.py `_get_pip` discovery order, mirrored here:
    #
    # 1. `executable:` given - an absolute path is trusted as-is; a
    #    bare name must exist on PATH (get_bin_path) or the module
    #    fails with "Unable to find any of <name> to use."
    # 2. No executable: it first runs pip as `[sys.executable, '-m',
    #    'pip']` whenever the interpreter can `import pip`
    #    (_have_pip_module), and ONLY falls back to a `pip3` PATH
    #    search when it can't. sys.executable there is the DISCOVERED
    #    interpreter - e.g. /usr/bin/python3.9 on a Rocky 9.6 minimal
    #    image that ships no unversioned `python3` command at all
    #    (found via aloysius-lim.elasticsearch_api, round 91020, where
    #    BOTH the old literal-`python3` probe and the `pip3` PATH check
    #    failed while real Ansible, running its module under the
    #    discovered /usr/bin/python3.9, installed cleanly). Krikri's
    #    plugin is a compiled binary with no module interpreter of its
    #    own, so it probes the same candidates a `-m pip` invocation
    #    could plausibly work under (#discover_pip_module_interpreter)
    #    and uses the first that succeeds - also covering a host where
    #    `python3` exists but lacks the pip module while a versioned
    #    interpreter has it.
    #
    # `sh -c 'command -v ...'` rather than a bare `which ...`: the
    # LocalExecutor fast path execs argv[0] directly when the command
    # carries no shell metacharacters (single quotes don't count as
    # one - Process.parse_arguments handles them), so the shell
    # builtin resolves correctly without a full bash hop, AND the
    # check keeps working on hosts with no `which` binary at all.
    private def discover_system_pip : String | PluginResult
      if executable = @params["executable"]?
        return executable if executable.starts_with?("/")

        unless remote_exec("sh -c #{Shell.single_quote("command -v #{executable}")}")[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "Unable to find any of #{executable} to use.  pip needs to be installed.")
        end
        return executable
      end

      if interpreter = discover_pip_module_interpreter
        return "#{interpreter} -m pip"
      end

      unless remote_exec("sh -c 'command -v pip3'")[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Unable to find any of pip3 to use.  pip needs to be installed.")
      end
      "pip3"
    end

    # One shell loop over the `-m pip` candidate interpreters (a single
    # SSH round trip, not one per candidate): the host's
    # ansible_python_interpreter when set (real Ansible runs its pip
    # module under that interpreter, so sys.executable is exactly it),
    # then python3, then the versioned python3.N names interpreter
    # discovery iterates, then a bare python. Returns the winning
    # interpreter name (sanitized to a plain path token - this string
    # is interpolated into later shell commands), or nil when no
    # candidate could run pip as a module.
    private def discover_pip_module_interpreter : String?
      candidates = [] of String
      if interp = @vars["ansible_python_interpreter"]?.try(&.as_s?)
        stripped = interp.strip
        candidates << stripped unless stripped.empty?
      end
      candidates << "python3"
      candidates.concat((6..14).to_a.reverse.map { |minor| "python3.#{minor}" })
      candidates << "python"

      quoted = candidates.uniq.map { |candidate| Shell.single_quote(candidate) }.join(" ")
      result = remote_exec("for interp in #{quoted}; do if \"$interp\" -m pip --version >/dev/null 2>&1; then echo \"$interp\"; exit 0; fi; done; exit 1")
      return nil unless result[:exit_code] == 0

      interpreter = result[:stdout].strip
      interpreter =~ /\A[A-Za-z0-9_\/.\-]+\z/ ? interpreter : nil
    end

    # required_one_of + mutually_exclusive in real Ansible's own check
    # order (mutually_exclusive first). Returns the failure result, or
    # nil when the arguments are acceptable.
    private def argument_validation_error : PluginResult?
      if mutex = mutually_exclusive_error
        return mutex
      end
      required_one_of_error
    end

    # Real Ansible's required_one_of counts a parameter as given when
    # its KEY is present (even with an empty value) - the empty-value
    # no-op is a separate, later truthiness check (#missing_name_result).
    private def required_one_of_error : PluginResult?
      return nil if @params["name"]? || @params["requirements"]?

      PluginResult.new(changed: false, failed: true, msg: "one of the following is required: name, requirements")
    end

    # Real Ansible's mutually_exclusive message format
    # (module_utils/common/validation.py): each violated pair joined
    # with `|`, pairs joined with `, `.
    private def mutually_exclusive_error : PluginResult?
      violated = [] of String
      violated << "name|requirements" if @params["name"]? && @params["requirements"]?
      violated << "executable|virtualenv" if @params["executable"]? && @params["virtualenv"]?
      return nil if violated.empty?

      PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: #{violated.join(", ")}")
    end

    # The name/requirements combination check. Returns the early result
    # to use, or nil when the arguments are acceptable. (The outright
    # required_one_of failure is #required_one_of_error, which runs
    # earlier - this only handles the key-present-but-empty case.)
    private def missing_name_result(raw_name : String?, name : String?, requirements : String?) : PluginResult?
      return nil unless name.nil? && requirements.nil?

      PluginResult.new(changed: false, failed: false, msg: "No valid name or requirements file found.")
    end

    # Validate the umask: parameter, if given. Returns the failure
    # result for an invalid (non-octal) value, or nil.
    private def umask_error : PluginResult?
      if umask = @params["umask"]?
        return PluginResult.new(changed: false, failed: true, msg: "umask must be an octal integer") unless umask =~ /\A0?[0-7]{1,4}\z/
      end
      nil
    end

    # Handles the "Python-repr-list JSON" case: a `{{ }}`-templated
    # `name:` that resolves to a real list renders to its own bracketed
    # text form (e.g. `[]`, `['pkg']`) since this codebase's plugin
    # params are always plain strings. An empty list becomes `nil`
    # (matching real Ansible's `if name:` falsy-empty-list no-op); a
    # single-element list unwraps to that one package name (the common
    # real-world shape). A genuine multi-package list (`['a', 'b']`)
    # is a pre-existing, separately-scoped gap - this plugin has never
    # supported installing several distinct packages in one task - so
    # it's passed through as-is rather than silently dropped.
    private def normalize_name(raw : String?) : String?
      return nil unless raw
      stripped = raw.strip
      return raw unless stripped.starts_with?('[') && stripped.ends_with?(']')

      # ONLY valid JSON - never a Python-repr repair pass: a value that
      # merely LOOKS like a container is a plain STRING in real
      # ansible-core (live-verified vs ansible-playbook 2.19.11, see
      # apt.cr's parse_package_names). A whole-value `{{ list_var }}`
      # container arg arrives as the double-quoted JSON the wire
      # serialized it to (see substitute_task_params's whole-single-span
      # comment).
      list = (Array(String).from_json(stripped) rescue nil)
      return raw unless list

      # Real bug found benchmarking claranet.postgresql's own `name:
      # "{{ _postgresql_dependencies_pip_packages }}"` (a full-value
      # Jinja substitution of a >1-item list variable, as opposed to a
      # LITERAL YAML `name:` list - which the parser upstream already
      # comma-joins into a plain string before this plugin ever sees
      # it, per #install's own comment). A bare `{{ list_var }}`
      # indirection instead renders the array as bracketed text
      # (`['psycopg2', 'ipaddress']`), and the `else raw` branch here
      # returned that whole bracketed string UNCHANGED for any list
      # with more than one entry - #install then comma-split it
      # naively, truncating everything after the first item's own
      # internal comma into garbage ("['psycopg2'" as one bogus
      # "package", pip erroring "Invalid requirement"). Real Ansible's
      # pip.py takes the parsed list directly, regardless of whether it
      # arrived as a literal YAML list or a templated variable - so
      # every item here gets joined the same comma-separated way
      # #install already expects for the literal-list path.
      case list.size
      when 0 then nil
      when 1 then list[0]
      else        list.join(",")
      end
    end

    private def with_umask(command : String) : String
      return command unless umask = @params["umask"]?
      "umask #{umask}; #{command}"
    end

    # `version:` uses real Ansible's own Python truthiness (`if
    # version_string:` in pip.py) - an empty string counts as "no
    # version pin", same as nil/omitted, not literally "pin to the
    # empty version". Found via geerlingguy.elasticsearch-curator's own
    # `version: "{{ elasticsearch_curator_version | default(omit) }}"`
    # with its own default `elasticsearch_curator_version: ''` - Jinja2's
    # `default(omit)` only substitutes for an actually-Undefined value,
    # never a defined-but-empty string, so the empty string reaches this
    # module as a real (falsy) value either way. Without this check,
    # `target_spec` built the literal spec `elasticsearch-curator==`
    # (trailing `==` with no version), which pip correctly rejects as
    # unsatisfiable - real Ansible's pip install succeeds (unpinned).
    private def target_spec(name : String?, version : String?) : String?
      return nil unless name
      return name if version.nil? || version.empty?
      "#{name}==#{version}"
    end

    # Resolves the venv (creating it if needed) or the system pip
    # executable. Returns a PluginResult only on failure (venv creation
    # error), so callers can `return pip_bin if pip_bin.is_a?(PluginResult)`.
    private def resolve_pip_binary : String | PluginResult
      if venv = @params["virtualenv"]?
        pip_path = "#{venv}/bin/pip"
        unless remote_dir_exists?(venv)
          if failure = create_virtualenv(venv)
            return failure
          end
          @created_virtualenv = true
        end
        pip_path
      else
        discover_system_pip
      end
    end

    # Creates the virtualenv at `venv` using virtualenv_command:, or
    # nil on success. Mirrors real Ansible's setup_virtualenv:
    # - the command is shlex-split; a bare first token is resolved on
    #   PATH (get_bin_path), an absolute/relative path is trusted
    # - --system-site-packages when virtualenv_site_packages:, else
    #   --no-site-packages ONLY if the command's own --help advertises
    #   it (_get_cmd_options) - `python3 -m venv` never gets the flag,
    #   the classic virtualenv tool does
    # - a venv/pyvenv-style command gets no -p; anything else (the
    #   virtualenv tool) does, since -p is not a venv option - and
    #   virtualenv_python: with a venv command is a hard error
    private def create_virtualenv(venv : String) : PluginResult?
      command = @params["virtualenv_command"]? || "virtualenv"
      tokens = command.split(' ').reject(&.empty?)
      cmd0 = tokens[0]

      unless cmd0.includes?('/')
        found = remote_exec("sh -c 'command -v #{Shell.single_quote(cmd0)}'")
        unless found[:exit_code] == 0
          paths = remote_exec("echo $PATH")[:stdout].strip
          return PluginResult.new(changed: false, failed: true, msg: "Failed to find required executable #{cmd0} in paths: #{paths}")
        end
        cmd0 = found[:stdout].strip
      end

      parts = [cmd0] + tokens[1..]

      if true?(@params["virtualenv_site_packages"]?)
        parts << "--system-site-packages"
      else
        help = remote_exec("#{Shell.single_quote(cmd0)} --help")
        unless help[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "Could not get output from #{cmd0} --help: #{help[:stdout]}#{help[:stderr]}")
        end
        parts << "--no-site-packages" if help[:stdout].includes?("--no-site-packages")
      end

      if venv_command?(command)
        if @params["virtualenv_python"]?
          return PluginResult.new(changed: false, failed: true, msg: "virtualenv_python should not be used when using the venv module or pyvenv as virtualenv_command")
        end
      else
        parts << "-p#{@params["virtualenv_python"]? || "python3"}"
      end

      parts << venv
      result = remote_exec(parts.map { |part| Shell.single_quote(part) }.join(" "))
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to create virtualenv: #{result[:stderr]}")
      end

      nil
    end

    # Real Ansible's _is_venv_command: pyvenv (any argv[0] equal to it)
    # or a `-m venv` module invocation counts as a venv-style command;
    # the classic virtualenv tool does not (it takes -p).
    private def venv_command?(command : String) : Bool
      tokens = command.split(' ').reject(&.empty?)
      return true if tokens[0] == "pyvenv"

      tokens.each_with_index.any? { |token, index| token == "-m" && tokens[index + 1]? == "venv" }
    end

    private def with_chdir(command : String) : String
      if chdir = @params["chdir"]?
        "cd #{shell_single_quote(expand_tilde(chdir))} && #{command}"
      else
        command
      end
    end

    # `pip show` only understands a bare distribution name - a PEP 508
    # extras suffix (`ara[server]`, requesting ara's own optional
    # "server" extra dependencies) makes `pip show` itself fail with
    # "Package(s) not found: ara[server]" (verified live: `pip3 show
    # ara` succeeds, `pip3 show 'ara[server]'` doesn't - extras aren't a
    # separate installed distribution, pip just pulls in more deps for
    # the same base package). Without stripping this, `already_installed?`
    # always returned false for any `name: "pkg[extra]"` spec, so a
    # `pip: {name: ara[server]}` task (robertdebock.ara's own "install
    # ara" task) never converged - `changed: true` forever. Strips both
    # the version-operator suffix (existing behavior) AND any trailing
    # `[...]` extras.
    private def distribution_name(package : String) : String
      if vcs_name = vcs_distribution_name(package)
        return vcs_name
      end
      package.split(/[=<>!~]/, 2)[0].sub(/\[[^\]]*\]\z/, "")
    end

    # A VCS requirement (`git+https://github.com/grycap/clues.git@master`)
    # never matches a bare distribution name - the whole URL+ref string
    # reached `pip show` verbatim, which always fails ("Package(s) not
    # found"), so `already_installed?` always returned false and every
    # rerun re-installed, reporting `changed: true` where real Ansible's
    # own pip module pre-checks installed packages by their DERIVED name
    # and reports ok. Found live via grycap.clues (rounds 700036/820004):
    # its second `pip: {name: git+...clues.git@master}` "Install CLUES2"
    # task reported changed where real ansible-playbook reported ok.
    # Name derivation mirrors real pip's own VCS handling: an `#egg=`
    # fragment wins (PEP 508 direct-reference convention), otherwise the
    # URL's basename with the `.git` suffix stripped (`.../clues.git@master`
    # -> "clues"). The `@ref` suffix only appears at the END of a VCS URL
    # (pip's `@` ref separator), so splitting on the first `@` is safe for
    # the egg-less form.
    private def vcs_distribution_name(package : String) : String?
      return nil unless {"git+", "hg+", "bzr+", "svn+"}.any? { |prefix| package.starts_with?(prefix) }
      if egg = package.split("#egg=")[1]?
        return egg.split(/[&=<>!~]/, 2)[0].sub(/\[[^\]]*\]\z/, "")
      end
      base = package.split('@')[0].rstrip('/')
      base = base.rchop(".git").split('/').last
      base.empty? ? nil : base
    end

    private def already_installed?(pip_bin : String, package : String) : Bool
      bare_name = distribution_name(package)
      remote_exec("#{quoted_command(pip_bin)} show #{Shell.single_quote(bare_name)}")[:exit_code] == 0
    end

    private def installed_version(pip_bin : String, package : String) : String?
      bare_name = distribution_name(package)
      result = remote_exec("#{quoted_command(pip_bin)} show #{Shell.single_quote(bare_name)} 2>/dev/null")
      return nil unless result[:exit_code] == 0

      result[:stdout].each_line do |line|
        return line.split(":", 2)[1]?.try(&.strip) if line.starts_with?("Version:")
      end
      nil
    end

    private def install(pip_bin : String, spec : String?, upgrade : Bool, requirements : String? = nil) : PluginResult
      target = install_target(spec, requirements)
      return target if target.is_a?(PluginResult)

      # A comma-joined multi-package `name:` list checked as ONE bogus
      # "package" (`pip3 show docker,urllib3`) always failed - not just
      # returning a wrong single result, but reporting `changed: true`
      # on every rerun regardless of what was actually already present,
      # since the idempotency check itself could never succeed. Checked
      # per-package here (each already-installed, or - for a `==` pin -
      # already at the requested version) so a warm rerun genuinely
      # short-circuits, matching real Ansible's own per-package pip
      # idempotency.
      unless upgrade || requirements
        return PluginResult.new(changed: false, failed: false, msg: "Package already installed") if all_packages_satisfied?(pip_bin, spec)
      end

      extra = editable_extra(@params["extra_args"]? || "")

      # `target` reaches here already comma-joined by the parser for a
      # literal YAML `name:` list (real Ansible's pip module takes a
      # LIST and installs every element in one invocation, unlike this
      # plugin's own pre-existing single-package-name assumption
      # elsewhere - see #normalize_name's comment). Left as one
      # unescaped word, a version-constrained spec containing a shell
      # metacharacter (`urllib3<2`, `foo>1.0`) gets misparsed by the
      # `bash -c` this plugin shells out through - `<2` becomes a
      # stdin REDIRECT from a file literally named "2" instead of part
      # of the pip argument, and pip never runs at all. Real Ansible
      # never has this problem because it execs pip with a real argv
      # list, no shell in between. Splitting on the comma the parser
      # joined with and re-quoting each element via `Process.quote`
      # both makes a genuine multi-package `name:` list actually work
      # (was previously passed as one bogus comma-glued "package") and
      # makes each element shell-safe again. `-r <file>` and a bare
      # `--upgrade`/`extra_args` are never comma-joined so they pass
      # through the `elsif spec` branch above and are handled directly
      # below, one per name.
      quoted_target = requirements ? target : split_requirements(target).map { |tval| Process.quote(tval) }.join(" ")
      cmd = with_umask(with_chdir("#{break_system_packages_env}#{quoted_command(pip_bin)} install #{upgrade ? "--upgrade " : ""}#{extra_tokens(extra)} #{quoted_target}".strip))
      result = remote_exec(cmd)

      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to install: #{result[:stderr]}", stdout: result[:stdout], stderr: result[:stderr])
      end

      # Real Ansible's own state: latest changed-detection: pip prints
      # "Requirement already up-to-date" (older pip) or "Requirement
      # already satisfied" with no "Successfully installed" line when
      # an upgrade genuinely changed nothing.
      changed = !(result[:stdout].includes?("Requirement already up-to-date") ||
                  (upgrade && !result[:stdout].includes?("Successfully installed")))

      PluginResult.new(changed: changed, failed: false, msg: "Package installed", stdout: result[:stdout])
    end

    # Resolve what to pass to `pip install`: a requirements file, a
    # spec, or the missing-argument failure.
    private def install_target(spec : String?, requirements : String?) : String | PluginResult
      if requirements
        "-r #{Process.quote(requirements)}"
      elsif spec
        spec
      else
        PluginResult.new(changed: false, failed: true, msg: "name or requirements is required")
      end
    end

    # Real Ansible's pip.py list-type `name:` param auto-splits a raw
    # string on commas (AnsibleModule list-param coercion), then
    # RE-MERGES any resulting piece that starts with a version
    # comparison operator (<, >, =, !, ~) back onto the preceding
    # piece - such a piece can only be a continuation of that
    # package's own PEP 440 version specifier (no valid PyPI package
    # name starts with one of those characters), never a second
    # distinct package. Confirmed live: `name: "cryptography>3,<3.5"`
    # (jonaspammer.openssl round 813196) reaches real pip as ONE argv
    # word `cryptography<3.5,>3` - splitting naively on every comma
    # instead produced two words, the second (`<3.5`) rejected by pip
    # as "Invalid requirement: '<3.5': Expected package name at the
    # start of dependency specifier", which flipped that round's PLAY
    # RECAP counts (a downstream `when: ...failed` task then ran
    # differently than in real Ansible).
    private def split_requirements(spec : String) : Array(String)
      pieces = spec.split(',').map(&.strip)
      merged = [] of String
      pieces.each do |piece|
        if !merged.empty? && piece =~ /\A[<>=!~]/
          merged[-1] = "#{merged[-1]},#{piece}"
        else
          merged << piece
        end
      end
      merged
    end

    # Per-package idempotency check for a non-upgrade, non-requirements
    # install: every package already installed (or - for a `==` pin -
    # already at the requested version)?
    private def all_packages_satisfied?(pip_bin : String, spec : String?) : Bool
      sp = spec || raise "pip: spec is required"
      packages = split_requirements(sp)
      packages.all? do |package|
        if package.includes?("==")
          bare, _, wanted_version = package.partition("==")
          installed_version(pip_bin, bare) == wanted_version
        else
          already_installed?(pip_bin, package)
        end
      end
    end

    # Merge the `-e` flag into extra_args when editable: is set
    # (deduplicated if extra_args already includes it)
    private def editable_extra(extra : String) : String
      if true?(@params["editable"]?) && !extra.split(' ').includes?("-e")
        extra.empty? ? "-e" : "#{extra} -e"
      else
        extra
      end
    end

    # Each extra_args token is shell-quoted individually so an
    # `extra_args:` value can't inject extra shell operations - real
    # Ansible shlex-splits it into argv elements, and one quoted shell
    # word per token is the same argv.
    private def extra_tokens(extra : String) : String
      extra.split(' ').reject(&.empty?).map { |token| Process.quote(token) }.join(" ")
    end

    # pip_bin can be a multi-token command (`python3.9 -m pip` from the
    # interpreter-discovery fallback), so it's quoted per token - one
    # quoted shell word per argv element, safe tokens left verbatim.
    private def quoted_command(command : String) : String
      command.split(' ').reject(&.empty?).map { |token| Process.quote(token) }.join(" ")
    end

    # PEP 668 externally-managed environments (newer Debian/Ubuntu)
    # reject pip mutations outright unless overridden - real Ansible's
    # pip.py sets PIP_BREAK_SYSTEM_PACKAGES=1 in the module's own
    # environment when break_system_packages: is true (an env var, not
    # the CLI flag, so pip < 23.0 - which lacks the flag - still
    # works). Krikri shells out per command, so the same env var rides
    # on the pip invocation itself. Applies to uninstall too: PEP 668
    # blocks that just as hard.
    private def break_system_packages_env : String
      true?(@params["break_system_packages"]?) ? "PIP_BREAK_SYSTEM_PACKAGES=1 " : ""
    end

    private def remove(pip_bin : String, name : String) : PluginResult
      bare_name = name.split(/[=<>!~]/, 2)[0]

      cmd = with_umask(with_chdir("#{break_system_packages_env}#{quoted_command(pip_bin)} uninstall -y #{Shell.single_quote(bare_name)}"))
      result = remote_exec(cmd)

      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to uninstall: #{result[:stderr]}")
      end

      # Real Ansible runs `pip uninstall` unconditionally and lets pip's
      # own "not installed" line decide changed=false - it does NOT
      # pre-check installed-ness locally. Skipping that invocation made
      # a PEP 668 externally-managed environment report state=absent as
      # ok where real Ansible fails (pip refuses to even run), so the
      # command must actually be issued and its output parsed.
      if (result[:stdout] + result[:stderr]).downcase.includes?("not installed")
        return PluginResult.new(changed: false, failed: false, msg: "Package already absent")
      end

      PluginResult.new(changed: true, failed: false, msg: "Package removed")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::PipPlugin.new(config)
plugin.run
