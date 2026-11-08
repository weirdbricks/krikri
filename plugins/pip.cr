#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/run_command_failure"
require "../src/krikri/plugin_helpers/python_lib_gate"

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
  # - version: install exactly this version - appended to name with
  #   `==` when the version starts with a digit, or with NO separator
  #   when it starts with a comparison operator (`>=22` -> `pip>=22`),
  #   matching Ansible's own pip module
  # - state: present (default) | absent | latest | forcereinstall
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
  #   (default: "virtualenv", matching Ansible's argument_spec
  #   default - NOT hardcoded python3 -m venv). A bare name is resolved
  #   on PATH like Ansible's get_bin_path; a space-separated
  #   command (e.g. `python3 -m venv`, `python -m virtualenv`) is used
  #   as-is like Ansible's shlex.split of the same value
  # - virtualenv_site_packages: when CREATING a new virtualenv, pass
  #   --system-site-packages (true) or --no-site-packages when the
  #   chosen venv command supports it (false, the default) - mirroring
  #   Ansible's setup_virtualenv, which probes `<command> --help`
  #   for the latter. No effect on an already-existing virtualenv
  # - break_system_packages: true sets PIP_BREAK_SYSTEM_PACKAGES=1 on
  #   the pip install/uninstall invocation (needed on PEP 668
  #   externally-managed systems). Ansible sets the env var rather
  #   than the --break-system-packages CLI flag so pip < 23.0 (which
  #   lacks the flag) still works - the env var is honored by the same
  #   pip versions that grew the flag
  #
  # Validation (mirroring Ansible's own module-level argument
  # checks, which run before anything else - before pip discovery or
  # any venv creation):
  # - required_one_of name/requirements: neither given fails with
  #   Ansible's "one of the following is required: name, requirements"
  # - mutually_exclusive name/requirements and executable/virtualenv:
  #   both of a pair given fails with Ansible's "parameters are
  #   mutually exclusive: <pair>"
  #
  # Idempotency: `present` (with or without version:) runs
  # `pip install <spec>` unconditionally like Ansible's own pip module,
  # which has NO idempotency pre-check at all - changed comes from pip's
  # own output ("Successfully installed" present or not). A VCS-URL
  # requirement is the one exception: a `pip show <derived-name>`
  # pre-check short-circuits it, matching Ansible's freeze-comparison
  # changed detection, which likewise reports ok whenever a rerun
  # converges to what is already installed. `latest` always
  # invokes `pip install --upgrade` and inspects its own output for
  # "Requirement already up-to-date" vs. an actual install/upgrade,
  # matching Ansible's own PipModule. `forcereinstall` likewise mirrors
  # Ansible's state_map entry ['install', '-U', '--force-reinstall']: it
  # was treated as plain `present` before, so a satisfied constraint
  # (JonasPammer.pip's `pip>=22` on a host whose system pip already
  # satisfies it) printed "Requirement already satisfied" and reinstalled
  # nothing, leaving the role's before/after `pip --version` outputs
  # identical and flipping its `changed_when: before != after` comparison
  # task from Ansible's changed to ok (issue #380).
  #
  # - editable: adds `-e` to extra_args (deduplicated if extra_args
  #   already includes it) - verified against the Ansible module
  #   the Ansible module's observed behavior, `-e` is applied there too rather than as a
  #   separate standalone flag
  # - umask: an octal string, applied via a `umask <value>;` command
  #   prefix (this codebase shells out per-command rather than forking
  #   like Ansible's own `os.umask()` around the whole run, so a
  #   shell-level `umask` prefix is the equivalent for the single `pip`
  #   invocation either wraps) - fails clearly on an invalid (non-octal)
  #   value, matching Ansible's own validation message
  #
  # check_mode IS implemented now (issue #794): pip.py's setup_virtualenv
  # exits changed before creating anything, and its check_mode block
  # reports changed outright for what it can't probe idempotently
  # (`extra_args:`/`requirements:`/state=latest) and decides the rest from
  # `pip list --format=freeze` presence. NOT implemented: `--check`-driven
  # diff output, a separate pre-existing gap. Per-package
  # `state: absent` version pinning (uninstall doesn't take a version).
  class PipPlugin < BasePlugin
    # ansible.builtin.pip's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.pip). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[break_system_packages editable virtualenv_site_packages]
    end

    # Set by #resolve_pip_binary when THIS task invocation itself created
    # the target virtualenv (it didn't exist before the task ran).
    # Ansible's pip module counts creating a virtualenv as a change in
    # its own right, independent of whether the requested package then
    # needed installing - found benchmarking claranet.postgresql, whose
    # `pip: {name: ..., virtualenv: ...}` cold run reported ok/"Package
    # already installed" in krikri (the fresh venv's own bootstrapped
    # pip satisfied `pip show pip`) where Ansible reported changed.
    @created_virtualenv = false

    def execute : PluginResult
      validate_bool_params!
      # Ansible's required_one_of / mutually_exclusive checks run
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

      # The umask/pip-binary/name checks pip.py runs before any install,
      # in that order - see #pip_preflight for what each one covers.
      if preflight = pip_preflight(raw_name, name, requirements)
        return preflight
      end

      check_mode = true?(@params["_ansible_check_mode"]?)

      # pip.py's setup_virtualenv opens with `if module.check_mode:
      # module.exit_json(changed=True)` BEFORE creating anything, so a
      # check-mode pip task never leaves a virtualenv behind - even though
      # it still reports changed. CoffeeITWorks.ansible_burpui_server's own
      # `check_mode: yes` "check only if burpui is installed" task runs
      # right before `update pip` on a cold host: with the venv still
      # absent, Ansible's update-pip task creates the venv itself and
      # reports changed (pip.py counts venv_created as a change of its
      # own), while a plugin that ignores check mode runs the probe for
      # real, creates the venv there, and the update-pip task then finds
      # the venv already present and reports ok (issue #794).
      if check_mode && check_mode_venv_missing?
        return PluginResult.new(changed: true, failed: false)
      end

      pip_bin = resolve_pip_binary
      return pip_bin if pip_bin.is_a?(PluginResult)

      # pip.py: version= with more than one package - after the virtualenv/pip
      # resolution above, before any install (that order is Ansible's)
      if @params["version"]? && name && name.split(",").count { |spec| !spec.strip.empty? } > 1
        return PluginResult.new(changed: false, failed: true,
          msg: "'version' argument is ambiguous when installing multiple package distributions. " \
               "Please specify version restrictions next to each package in 'name' argument.")
      end

      # pip.py's own check_mode block sits after the virtualenv/pip
      # resolution AND the version: validation (both can still fail hard
      # in check mode), right before the real install would run.
      return check_mode_result(pip_bin, state, name, requirements) if check_mode

      result = run_state_action(pip_bin, state, name, requirements)
      overlay_venv_creation_change(result)
    end

    # Whether the target virtualenv still needs creating (check mode must
    # exit before it would be, see the caller's comment).
    private def check_mode_venv_missing? : Bool
      venv = virtualenv_path
      return false unless venv
      !remote_file_exists?("#{venv}/bin/activate")
    end

    # Ansible declares virtualenv: as a path-type param, so AnsibleModule
    # runs it through os.path.expanduser before the module body ever looks
    # at it. Without the same expansion, `virtualenv: ~/some_venv` stays a
    # literal "~" path that never exists on disk, so the existence probe
    # wrongly reports the venv missing and check mode answers changed where
    # Ansible answers ok (issue #954).
    private def virtualenv_path : String?
      @params["virtualenv"]?.try { |venv| expand_tilde(venv) }
    end

    # The per-state action pip.py dispatches through its state_map, after
    # every validation and any check-mode exit has run.
    private def run_state_action(pip_bin : String, state : String, name : String?, requirements : String?) : PluginResult
      case state
      when "absent"
        remove(pip_bin, name || raise "pip: name is required with state=absent")
      when "latest"
        install(pip_bin, target_spec(name, nil), upgrade: true)
      when "forcereinstall"
        install(pip_bin, target_spec(name, @params["version"]?), upgrade: true,
          force_reinstall: true, requirements: requirements)
      else
        install(pip_bin, target_spec(name, @params["version"]?), upgrade: false, requirements: requirements)
      end
    end

    # The three checks pip.py makes before it installs anything, in its
    # own order, returning the first failure any of them produces.
    #
    # Ansible's pip.py converts the umask before any
    # virtualenv/pip resolution, then resolves (and validates the
    # EXISTENCE of) the pip executable via `get_bin_path` before it ever
    # looks at name:/requirements: at all - a target with no pip/pip3
    # binary installed anywhere fails immediately with "Unable to find
    # any of pip3 to use.  pip needs to be installed.", REGARDLESS of
    # whether there's actually anything to install. Previously this
    # engine only resolved pip_bin (a bare string, e.g. "pip3") and never
    # checked it actually exists on the target - combined with the
    # empty-name check just below, a role whose package list happens to
    # be empty ON THIS OS (buluma.vagrant's own
    # `vagrant_pip_packages: []` on Debian-family, round 180) never even
    # tried to invoke pip at all, silently reporting `ok:` instead of
    # Ansible's hard failure for a genuinely pip-less host. Skipped
    # for a virtualenv: target - #resolve_pip_binary already creates the
    # venv (and fails there if that itself doesn't work), so its own pip
    # is guaranteed to exist by the time this runs.
    #
    # `name` is a list and `if name:` is Python truthiness, so a name:
    # PARAM THAT IS PRESENT but resolves to an EMPTY list (e.g. a
    # templated `name: "{{ some_list_var }}"` that rendered to `[]`) is
    # not an error - it falls straight through to the same "nothing to
    # do" branch pip.py uses, exiting cleanly with changed: false rather
    # than trying to pip-install anything. A name: key that's genuinely
    # absent (not just empty) together with no requirements: is the real
    # required_one_of failure.
    private def pip_preflight(raw_name : String?, name : String?, requirements : String?) : PluginResult?
      if bad_umask = umask_error
        return bad_umask
      end

      # pip.py's `if state == 'latest' and version is not None` guard sits
      # INSIDE the umask try-block, before chdir handling and before any
      # virtualenv/pip resolution - so a version: pinned at state: latest
      # fails here rather than deeper in (e.g. on a missing virtualenv
      # command). `version is not None` is a presence check, so an empty
      # version: string trips it too (live-verified vs 2.19.11). An
      # EXPLICIT NULL version does not: python's `version is not None`
      # is False for the None that `expr | default(omit)` does NOT
      # replace (default() only substitutes for undefined, never for
      # None - rolehippie.mongodb's own
      # `version: "{{ mongodb_pymongo_version | default(omit) }}"` with
      # a null default, round 5210000: real proceeded to the install,
      # krikri failed with this exact message). BasePlugin records such
      # a null param in @null_params with a demoted "" value, so the
      # presence check must exclude it - "" from a real empty string
      # still trips, as before.
      if (@params["state"]? || "present") == "latest" && @params["version"]? && !@null_params.includes?("version")
        return PluginResult.new(changed: false, failed: true,
          msg: "version is incompatible with state=latest")
      end

      if missing_binary = ensure_pip_binary
        return missing_binary
      end

      missing_name_result(raw_name, name, requirements)
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

    # pip.py's own check_mode block (which sits after the virtualenv/pip
    # resolution and the version: validation, both of which can still fail
    # hard in check mode): requirements:/extra_args:/state=latest (and an
    # empty name list) cannot be probed idempotently, so it reports changed
    # outright; anything else runs `pip list --format=freeze` (falling back
    # to `pip freeze` on old pips) and decides per requirement whether the
    # installed version satisfies it - state=present changes when a
    # requirement is missing or unsatisfied, state=absent when it IS
    # present. state=forcereinstall has no check-mode special case and
    # follows the present rule.
    private def check_mode_result(pip_bin : String, state : String, name : String?, requirements : String?) : PluginResult
      # Python truthiness on both strings: pip.py's `if extra_args or
      # requirements or state == 'latest' or not name` treats an empty
      # string as absent, so an empty extra_args:/requirements: does not
      # short-circuit here.
      extra = @params["extra_args"]?
      if (extra && !extra.empty?) || (requirements && !requirements.empty?) || state == "latest" || name.nil? || name.strip.empty?
        return PluginResult.new(changed: true, failed: false)
      end

      list_cmd, probe_out, probe_err = list_packages(pip_bin)
      unless list_cmd
        argv = pip_bin.split(' ').reject(&.empty?) + ["list", "--format=freeze"]
        return PluginResult.new(changed: false, failed: true,
          msg: pip_failure_msg(probe_out, probe_err), include_empty_msg: true, cmd: argv)
      end

      # Only the refs that fail to parse as a PEP 508 requirement (VCS
      # urls, file paths, archives) get resolved to the concrete
      # name==version pip would install. A bare name keeps its own empty
      # requirement, which every installed version satisfies, so an
      # installed-but-outdated package reports ok like Ansible's own - a
      # real install would upgrade it, but check mode does not look at
      # the index at all (issue #1004).
      packages, resolution_warning = resolve_check_packages(pip_bin, split_requirements(name))

      # pip.py's loop with its early break: state=present changes when ANY
      # requirement is missing/unsatisfied, state=absent when ANY is present.
      changed = if state == "absent"
                  packages.any? { |package| requirement_present?(package, probe_out) }
                else
                  packages.any? { |package| !requirement_present?(package, probe_out) }
                end

      # exit_json(changed=..., cmd=pkg_cmd, stdout=..., stderr=...): the
      # probe command and its output ride the result like an install's do.
      result = PluginResult.new(changed: changed, failed: false, stdout: probe_out,
        key_order: ["changed", "stdout"])
      if warning = resolution_warning
        result.extra["warnings"] = JSON::Any.new([JSON::Any.new(warning)])
      end
      result
    end

    # pip.py's _resolve_package_names(): a ref that is NOT a parseable
    # requirement is replaced by the concrete name==version pip would
    # install, read back from `pip install --dry-run --ignore-installed
    # --report=<tmpfile>`. pip older than 24.1 cannot report reliably, so
    # it keeps those refs and warns (real's own wording). Any failure
    # of the probe leaves the list untouched - real raises and fails the
    # task, but a check-mode probe is not worth failing a dry run over.
    private def resolve_check_packages(pip_bin : String, packages : Array(String)) : {Array(String), String?}
      to_resolve = packages.reject { |package| parsable_requirement?(package) }
      return {packages, nil} if to_resolve.empty?

      version = installed_pip_version(pip_bin)
      if version.nil? || pip_version_cmp(version, "24.1") < 0
        return {packages, "Using check mode with packages from vcs urls, file paths, or archives will not behave as expected when using pip versions <24.1."}
      end

      report_path = File.tempname("krikri-pip-report", ".json")
      begin
        report_arg = Process.quote("--report=#{report_path}")
        result = remote_exec("#{quoted_command(pip_bin)} install --dry-run --ignore-installed #{report_arg} #{to_resolve.map { |package| Process.quote(package) }.join(" ")}")
        return {packages, nil} unless result[:exit_code] == 0 && File.exists?(report_path)

        report = JSON.parse(File.read(report_path)) rescue nil
        resolved = report.try(&.["install"]?).try(&.as_a?)
        return {packages, nil} unless resolved

        other_packages = packages.reject { |package| to_resolve.includes?(package) }
        resolved_packages = resolved.compact_map do |entry|
          metadata = entry["metadata"]?
          next unless metadata
          name = metadata["name"]?.try(&.as_s?)
          version_string = metadata["version"]?.try(&.as_s?)
          next unless name && version_string
          "#{name}==#{version_string}"
        end
        {other_packages + resolved_packages, nil}
      ensure
        File.delete(report_path) if File.exists?(report_path)
      end
    end

    # pip.py's Package.has_requirement is literally `self._requirement is
    # not None`, i.e. "the packaging grammar accepted this string" - true
    # for a bare `six` too, whose specifier is simply empty. So the refs
    # _resolve_package_names replaces with a resolved name==version are
    # the ones that grammar REJECTS: VCS urls, local file paths/archives
    # and a direct `name @ url` reference (`six` alone parses,
    # `git+https://host/x.git` and `/tmp/x.tar.gz` do not).
    private def parsable_requirement?(package : String) : Bool
      piece = package.strip
      return false if piece.empty?
      return false if piece.includes?("://") || piece.includes?('@')
      return false if {"git+", "hg+", "bzr+", "svn+"}.any? { |prefix| piece.starts_with?(prefix) }
      return false if piece.starts_with?('/') || piece.starts_with?('.') || piece.starts_with?('~')

      # PEP 508's name rule: alphanumerics at both ends, `-_.` inside.
      name = piece.split(/[=<>!~(\[;\s]/, 2)[0].strip
      name.matches?(/\A[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\z/)
    end

    # `pip show pip`'s Version line (real's _get_package_info on itself).
    private def installed_pip_version(pip_bin : String) : String?
      result = remote_exec("#{quoted_command(pip_bin)} show pip")
      return nil unless result[:exit_code] == 0
      result[:stdout].each_line do |line|
        return line.split(":", 2)[1].strip if line.starts_with?("Version:")
      end
      nil
    end

    # pip.py's _get_packages: `pip list --format=freeze` first, `pip freeze`
    # when the pip is too old for the --format flag; the returned command
    # is the joined shell string (' '.join(command)), nil here on the
    # _fail path (both probes failed).
    private def list_packages(pip_bin : String) : {String?, String, String}
      result = remote_exec("#{quoted_command(pip_bin)} list --format=freeze")
      if result[:exit_code] == 0
        return {"#{pip_bin} list --format=freeze", result[:stdout], result[:stderr]}
      end

      fallback = remote_exec("#{quoted_command(pip_bin)} freeze")
      if fallback[:exit_code] == 0
        return {"#{pip_bin} freeze", fallback[:stdout], fallback[:stderr]}
      end

      {nil, fallback[:stdout], fallback[:stderr]}
    end

    # pip.py's _is_present: scan the freeze lines for the canonical name
    # and require every version specifier to hold (a bare name - no
    # specifier - is satisfied by any installed version). An
    # unparseable requirement piece is "not present", which makes the
    # check-mode task report changed, exactly like pip.py's
    # is_satisfied_by returning False for a Package that failed to parse.
    private def requirement_present?(package : String, freeze_out : String) : Bool
      canonical = canonical_pip_name(distribution_name(package))
      specs = requirement_specs(package)

      freeze_out.each_line do |line|
        sep = line.index("==")
        next unless sep
        installed_name = canonical_pip_name(line[0...sep].strip)
        next unless installed_name == canonical
        installed_version = line[sep + 2..].strip
        return true if specs.all? { |op, want| specifier_satisfied?(op, want, installed_version) }
      end
      false
    end

    # PEP 503 name canonicalization (pip.py's Package.canonicalize_name).
    private def canonical_pip_name(name : String) : String
      name.gsub(/[-_.]+/, "-").downcase
    end

    # The (operator, version) pairs of a requirement piece, e.g.
    # "cryptography<39,>=38.0.0" -> [("<", "39"), (">=", "38.0.0")]. The
    # alternation lists the multi-char operators first so "===" is not
    # read as "==" plus a stray "=".
    private def requirement_specs(package : String) : Array(Tuple(String, String))
      package.scan(/(===|==|!=|<=|>=|~=|<|>)\s*([^\s,;]+)/).map do |match|
        {match[1], match[2]}
      end
    end

    private def specifier_satisfied?(op : String, want : String, have : String) : Bool
      case op
      when "==="      then have == want
      when "==", "!=" then equality_satisfied?(op, want, have)
      when ">="       then pip_version_cmp(have, want) >= 0
      when "<="       then pip_version_cmp(have, want) <= 0
      when ">"        then pip_version_cmp(have, want) > 0
      when "<"        then pip_version_cmp(have, want) < 0
      when "~="       then compatible_release_satisfied?(want, have)
      else                 true
      end
    end

    # `==` and `!=` share pip's one exclusion: an `x.*` wildcard operand
    # matches by leading components, anything else by version equality.
    private def equality_satisfied?(op : String, want : String, have : String) : Bool
      satisfied = want.ends_with?(".*") ? wildcard_version_match?(want, have) : pip_version_cmp(have, want) == 0
      op == "==" ? satisfied : !satisfied
    end

    # `~=X.Y` is `>=X.Y, ==X.Y.*` - the lower bound holds and the version
    # stays under the compatible-release ceiling.
    private def compatible_release_satisfied?(want : String, have : String) : Bool
      ceiling = compatible_release_ceiling(want)
      pip_version_cmp(have, want) >= 0 && (!ceiling || pip_version_cmp(have, ceiling) < 0)
    end

    # `==1.4.*` matches any version whose leading numeric components are
    # exactly 1.4 (1.4.3 yes, 1.40 no).
    private def wildcard_version_match?(want : String, have : String) : Bool
      prefix = version_tokens(want.chomp(".*"))
      have_t = version_tokens(have)
      return false if have_t.size < prefix.size

      prefix.each_with_index.all? do |token, i|
        candidate = have_t[i]
        if token.matches?(/\A\d+\z/) && candidate.matches?(/\A\d+\z/)
          token.to_i64 == candidate.to_i64
        else
          token == candidate
        end
      end
    end

    # `~=X.Y.Z` is `>=X.Y.Z, ==X.Y.*` - the ceiling is the same version
    # with its second-to-last component incremented (~=2.2 -> <3,
    # ~=1.4.5 -> <1.5). A single-component version has no valid ceiling.
    private def compatible_release_ceiling(want : String) : String?
      parts = want.split('.').select(&.matches?(/\A\d+\z/))
      return nil if parts.size < 2

      bumped = parts[0...-1]
      bumped[-1] = (bumped[-1].to_i64 + 1).to_s
      bumped.join('.')
    end

    # Loose PEP 440-flavoured version comparison for the check-mode
    # presence probe - the shapes real roles pin (== pins, >= floors,
    # compatible release), decided the way pip's SpecifierSet does:
    # dot-separated components compare numerically (1.10 > 1.9), a
    # missing component reads as 0 (1.0 == 1.0.0), and a non-numeric
    # suffix (1.0rc1) sorts below the bare release it attaches to
    # (pip's pre-release ordering). Epochs (1!2.0) and local segments
    # (2.0+abc) are outside the shapes roles pin in practice.
    private def pip_version_cmp(a : String, b : String) : Int32
      a_tokens = version_tokens(a)
      b_tokens = version_tokens(b)

      [a_tokens.size, b_tokens.size].max.times do |i|
        x = a_tokens[i]?
        y = b_tokens[i]?
        return 0 if x.nil? && y.nil?

        cmp = token_pair_cmp(x, y)
        return cmp unless cmp == 0
      end
      0
    end

    # One component position of the comparison, with pip's tie-breaking:
    # a missing component reads as numeric 0 (1.0 == 1.0.0), a present
    # non-numeric component where the other side ran out is a
    # pre-release-style suffix sorting BELOW the bare release
    # (1.0rc1 < 1.0), two numerics compare numerically, and a mixed
    # numeric/alpha pair falls back to a string compare.
    private def token_pair_cmp(x : String?, y : String?) : Int32
      x_num = numeric_token(x)
      y_num = numeric_token(y)

      if x.nil? || y.nil?
        return (x_num || 0i64) <=> (y_num || 0i64) if x_num || y_num
        return x.nil? ? 1 : -1
      end

      return x_num <=> y_num if x_num && y_num
      x.to_s <=> y.to_s
    end

    private def numeric_token(token : String?) : Int64?
      token && token.matches?(/\A\d+\z/) ? token.to_i64 : nil
    end

    private def version_tokens(version : String) : Array(String)
      version.scan(/\d+|[A-Za-z]+/).map(&.[0])
    end

    # Verify pip is usable on the target (skipped for a virtualenv:
    # target - see the caller's comment). Returns the failure result,
    # or nil when a usable pip was found. Mirrors Ansible's
    # pip.py `_get_pip` discovery order - see #discover_system_pip.
    private def ensure_pip_binary : PluginResult?
      return nil if @params["virtualenv"]?

      result = discover_system_pip
      result.is_a?(PluginResult) ? result : nil
    end

    # Ansible's pip.py `_get_pip` discovery order, mirrored here:
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
    #    failed while Ansible, running its module under the
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
        if executable.starts_with?("/")
          # a missing absolute executable fails inside run_command (Errno 2)
          unless remote_exec("test -e #{shell_single_quote(executable)}")[:exit_code] == 0
            state = @params["state"]? || "present"
            raw_names = @params["name"]?.to_s
            names = (JSON.parse(raw_names).as_a.map(&.to_s) rescue raw_names.split(",").map(&.strip)).reject(&.empty?)
            extra = @params["extra_args"]?.to_s.strip
            verb = state == "absent" ? "uninstall -y" : (state == "latest" ? "install -U" : "install")
            cmd_text = ([executable] + verb.split + (extra.empty? ? [] of String : extra.split) + names).join(" ")
            return PluginResult.new(changed: false, failed: true, msg: "Error executing command.",
              cmd: cmd_text, rc: 2, stdout: "", stdout_lines: [] of String, stderr: "", stderr_lines: [] of String,
              _ansible_error_detail: "Error executing command: [Errno 2] No such file or directory: b'#{executable}'")
          end
          return executable
        end

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
    # SSH round trip, not one per candidate), in the order Ansible
    # itself decides the module's interpreter: the host's
    # ansible_python_interpreter when set (Ansible runs its pip module
    # under that interpreter, so sys.executable is exactly it; "auto*"
    # values are discovery directives, not names, and resolve to the
    # discovered fact below), then discovered_interpreter_python when
    # gathered (Ansible's sys.executable IS interpreter discovery's
    # answer - on a Ubuntu 22.04 host that is the VERSIONED
    # /usr/bin/python3.10, so reporting whatever bare `python3`
    # resolves to diverged, issue #474), then Ansible's
    # INTERPRETER_PYTHON_FALLBACK order (INTERPRETER_FALLBACK,
    # python_lib_gate.cr's plugin-side copy of facts_gatherer.cr's
    # list), then the remaining bare python3.N names and a bare
    # python, then the absolute /usr/bin and /usr/local/bin spellings
    # of the same names. The absolute entries are for a task whose
    # `environment:` PATH hides every bare name: Ansible's module runs
    # under an absolute interpreter (ansible_python_interpreter /
    # sys.executable) so it still finds pip there, and this probe must
    # too. Returns the winning interpreter name (sanitized to a plain
    # path token - this string is interpolated into later shell
    # commands), or nil when no candidate could run pip as a module.
    private def discover_pip_module_interpreter : String?
      candidates = [] of String
      if interp = @vars["ansible_python_interpreter"]?.try(&.as_s?)
        stripped = interp.strip
        candidates << stripped unless stripped.empty? || stripped.starts_with?("auto")
      end
      if discovered = @vars["discovered_interpreter_python"]?.try(&.as_s?)
        stripped = discovered.strip
        candidates << stripped unless stripped.empty?
      end
      candidates.concat(INTERPRETER_FALLBACK)
      names = ["python3"] + (6..14).to_a.reverse.map { |minor| "python3.#{minor}" } + ["python"]
      candidates.concat(names)
      candidates.concat(names.flat_map { |name| ["/usr/bin/#{name}", "/usr/local/bin/#{name}"] })

      quoted = candidates.uniq.map { |candidate| Shell.single_quote(candidate) }.join(" ")
      # ansible only checks the pip PACKAGE is importable and never
      # runs pip's CLI when choosing its module invocation, so the
      # probe must not gate on pip's own CLI health: on a host with a
      # broken pip CLI (vendored urllib3 failing on Python 3.10+)
      # ansible still runs `python -m pip install ...` and fails from
      # that command, while a `--version` probe here made discovery
      # fall through to bare `pip3` instead. The winner is printed as
      # an absolute path because ansible's cmd carries sys.executable
      # (e.g. /usr/bin/python3), not the bare candidate name.
      result = remote_exec("for interp in #{quoted}; do if \"$interp\" -c 'import importlib.util,sys; sys.exit(0 if importlib.util.find_spec(\"pip\") else 1)' >/dev/null 2>&1; then command -v \"$interp\"; exit 0; fi; done; exit 1")
      return nil unless result[:exit_code] == 0

      interpreter = result[:stdout].strip
      interpreter =~ /\A[A-Za-z0-9_\/.\-]+\z/ ? interpreter : nil
    end

    # required_one_of + mutually_exclusive in Ansible's own check
    # order (mutually_exclusive first). Returns the failure result, or
    # nil when the arguments are acceptable.
    private def argument_validation_error : PluginResult?
      if mutex = mutually_exclusive_error
        return mutex
      end
      required_one_of_error
    end

    # Ansible's required_one_of counts a parameter as given when
    # its KEY is present (even with an empty value) - the empty-value
    # no-op is a separate, later truthiness check (#missing_name_result).
    private def required_one_of_error : PluginResult?
      return nil if @params["name"]? || @params["requirements"]?

      PluginResult.new(changed: false, failed: true, msg: "one of the following is required: name, requirements")
    end

    # Ansible's mutually_exclusive message format
    # Observed behavior: each violated pair joined
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

      # Ansible's pip.py main() calls module.warn with this text and then
      # exit_json(changed=False): the text rides the result's `warnings`
      # list (a [WARNING] line before the ok: status) and the wire result
      # carries NO msg at all - a msg: here printed `ok:` with a message
      # body where real Ansible prints a bare ok line under the warning.
      # unarchive.cr#attach_warning is the established single-warning way.
      res = PluginResult.new(changed: false, failed: false)
      res.extra["warnings"] = JSON.parse(["No valid name or requirements file found."].to_json)
      res
    end

    # Validate the umask: parameter, if given. Returns the failure
    # result for an invalid (non-octal) value, or nil.
    private def umask_error : PluginResult?
      if umask = @params["umask"]?
        unless umask.to_i?(8)
          return PluginResult.new(changed: false, failed: true, msg: "umask must be an octal integer",
            details: "invalid literal for int() with base 8: '#{umask}'")
        end
      end
      nil
    end

    # Handles the "Python-repr-list JSON" case: a `{{ }}`-templated
    # `name:` that resolves to a real list renders to its own bracketed
    # text form (e.g. `[]`, `['pkg']`) since this codebase's plugin
    # params are always plain strings. An empty list becomes `nil`
    # (matching Ansible's `if name:` falsy-empty-list no-op); a
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
      # merely LOOKS like a container is a plain STRING in
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
      # "package", pip erroring "Invalid requirement"). Ansible's
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

    # `version:` uses Ansible's own Python truthiness (`if
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
    # unsatisfiable - Ansible's pip install succeeds (unpinned).
    # Ansible's pip.py (Package.__init__) does version_string.lstrip()
    # and then joins name and version with `==` only when the stripped
    # version starts with a digit - a version starting with a comparison
    # operator keeps the operator as the separator itself (`pip>=22`,
    # `pip~=1.2`). Building the unconditional `pip==>=22` made pip reject
    # the requirement outright ("Invalid requirement") where
    # ansible-playbook installs fine (issue #357). A version that is
    # only whitespace strips to nothing, so it installs the package
    # unpinned - Ansible would crash here; any unpinned outcome matches
    # the falsy-empty handling above.
    private def target_spec(name : String?, version : String?) : String?
      return nil unless name
      return name if version.nil? || version.empty?
      stripped = version.lstrip
      return name if stripped.empty?
      separator = stripped[0].in?('<', '>', '=', '!', '~') ? "" : "=="
      "#{name}#{separator}#{stripped}"
    end

    # Resolves the venv (creating it if needed) or the system pip
    # executable. Returns a PluginResult only on failure (venv creation
    # error), so callers can `return pip_bin if pip_bin.is_a?(PluginResult)`.
    private def resolve_pip_binary : String | PluginResult
      if venv = virtualenv_path
        # Ansible keys venv creation on bin/activate, not the directory: a
        # pre-created empty dir (file: state=directory) still runs
        # virtualenv_command, which fails on a host lacking it.
        unless remote_file_exists?("#{venv}/bin/activate")
          if failure = create_virtualenv(venv)
            return failure
          end
          @created_virtualenv = true
        end
        # Ansible's _get_pip, in the virtualenv branch, tries the venv's
        # own pip3 FIRST and only falls back to pip: candidate_pip_basenames
        # starts as ('pip3',) and the env branch extends it to ('pip3',
        # 'pip'), taking the first candidate that exists and is executable.
        # A pip-bootstrapped venv virtually always has pip3, so Ansible
        # runs pip3 there - CoffeeITWorks.ansible_burpui_server's failing
        # task recorded cmd ["/venv_apps/bui/bin/pip3", ...] where krikri
        # ran .../bin/pip, which also changed pip's own "To update, run:
        # ..." stderr notice wording (issue #794).
        if remote_file_exists?("#{venv}/bin/pip3")
          "#{venv}/bin/pip3"
        else
          "#{venv}/bin/pip"
        end
      else
        discover_system_pip
      end
    end

    # Creates the virtualenv at `venv` using virtualenv_command:, or
    # nil on success. Mirrors Ansible's setup_virtualenv:
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
          return PluginResult.new(changed: false, failed: true, msg: missing_executable_message(cmd0.to_s))
        end
        cmd0 = found[:stdout].strip
      end

      parts = [cmd0] + tokens[1..]

      if true?(@params["virtualenv_site_packages"]?)
        parts << "--system-site-packages"
      else
        # Ansible's _get_cmd_options runs `<cmd> --help` through
        # AnsibleModule.run_command, which raises OSError for a missing
        # binary, so the failure surfaces as the exec-failure shape
        # rather than "Could not get output from ...".
        if failure = PluginHelpers::RunCommandFailure.exec_check(cmd0)
          return PluginHelpers::RunCommandFailure.exec_failure(cmd0, failure[0], failure[1], "#{cmd0} --help")
        end
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
        # Ansible's setup_virtualenv fails via _fail, which reports the
        # venv command's own argv and joins BOTH output streams ("stdout:
        # ..." when present, then "\n:stderr: ..."), not just stderr -
        # `python3 -m venv`'s ensurepip error lands entirely on stdout.
        return PluginResult.new(changed: false, failed: true, msg: pip_failure_msg(result[:stdout], result[:stderr]), include_empty_msg: true, cmd: parts)
      end

      nil
    end

    # Ansible's _is_venv_command: a first token equal to "pyvenv", or the
    # rest of the command parsed by an argparse that knows only `-m` (a
    # value-taking option; unknown options are ignored via
    # parse_known_args and later occurrences win). argparse glues a short
    # option to its value, so `-mvenv` parses the same as `-m venv`
    # (GitHub issue #686: `python3 -mvenv` was misclassified as the
    # classic virtualenv tool and got `-ppython3` appended, which venv
    # rejects as an unrecognized argument). `-m=venv` also parses to
    # m == "venv". The classic virtualenv tool does not count (it takes
    # -p).
    private def venv_command?(command : String) : Bool
      tokens = command.split(' ').reject(&.empty?)
      return true if tokens[0] == "pyvenv"

      m_value : String? = nil
      expecting_value = false
      tokens[1..].each do |token|
        if expecting_value
          m_value = token
          expecting_value = false
        elsif token == "-m"
          expecting_value = true
        elsif token.starts_with?("-m")
          m_value = token[2..].lstrip('=')
        end
      end
      m_value == "venv"
    end

    private def with_chdir(command : String) : String
      if chdir = @params["chdir"]?
        # Ansible's run_command only honors cwd when it is an existing directory
        quoted = shell_single_quote(expand_tilde(chdir))
        "{ [ ! -d #{quoted} ] || cd #{quoted}; } && #{command}"
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
    # rerun re-installed, reporting `changed: true` where Ansible's
    # own pip module pre-checks installed packages by their DERIVED name
    # and reports ok. Found live via grycap.clues (rounds 700036/820004):
    # its second `pip: {name: git+...clues.git@master}` "Install CLUES2"
    # task reported changed where ansible-playbook reported ok.
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

    private def install(pip_bin : String, spec : String?, upgrade : Bool, requirements : String? = nil, force_reinstall : Bool = false) : PluginResult
      target = install_target(spec, requirements)
      return target if target.is_a?(PluginResult)

      # pip.py has NO idempotency pre-check for state=present: it always
      # runs `pip install <spec>` and decides
      # `changed = 'Successfully installed' in out_pip` (its only path
      # when there's no requirements file or VCS name). Skipping the
      # invocation is NOT observationally equivalent even when every
      # top-level pin is already satisfied, because pip's own resolver
      # may still change the environment: rolehippie.ansible (round
      # 5460398) pins ansible-doctor/ansible-later on pathspec==0.11.1
      # and jsonschema==4.17.3 while ansible-lint's own resolution
      # upgrades those same deps, so every rerun of
      # `pip install ansible-doctor==2.1.1` downgrades them back and
      # prints "Successfully installed pathspec-0.11.1" (live-verified:
      # `pip show ansible-doctor` reports 2.1.1 the whole time) - real
      # Ansible reports changed, a `pip show`-based pre-check whose
      # top-level `==` comparison matched reported ok. So for plain
      # name/version specs the install ALWAYS runs and pip's own output
      # decides changed.
      #
      # The one surviving pre-check is a VCS requirement: pip.py decides
      # a VCS/requirements install by freeze-before vs freeze-after
      # comparison, which reports ok whenever the rerun converges to
      # what pip show already finds - the same result this pre-check
      # gives without invoking pip at all (grycap.clues, rounds
      # 700036/820004).
      unless upgrade || requirements
        if spec && split_requirements(spec).any? { |package| vcs_distribution_name(package) }
          return PluginResult.new(changed: false, failed: false, msg: "Package already installed") if all_packages_satisfied?(pip_bin, spec)
        end
      end

      # 2.21 applies editable: to the install command itself, one `-e`
      # per package (2.19 merged a single -e into extra_args, which pip
      # then bound to the first package only). requirements: is
      # exclusive with editable: in the 2.21 spec, so the -r path never
      # carries a flag.
      extra = @params["extra_args"]? || ""
      editable = true?(@params["editable"]?)

      # `target` reaches here already comma-joined by the parser for a
      # literal YAML `name:` list (Ansible's pip module takes a
      # LIST and installs every element in one invocation, unlike this
      # plugin's own pre-existing single-package-name assumption
      # elsewhere - see #normalize_name's comment). Left as one
      # unescaped word, a version-constrained spec containing a shell
      # metacharacter (`urllib3<2`, `foo>1.0`) gets misparsed by the
      # `bash -c` this plugin shells out through - `<2` becomes a
      # stdin REDIRECT from a file literally named "2" instead of part
      # of the pip argument, and pip never runs at all. Ansible
      # never has this problem because it execs pip with a real argv
      # list, no shell in between. Splitting on the comma the parser
      # joined with and re-quoting each element via `Process.quote`
      # both makes a genuine multi-package `name:` list actually work
      # (was previously passed as one bogus comma-glued "package") and
      # makes each element shell-safe again. `-r <file>` and a bare
      # `--upgrade`/`extra_args` are never comma-joined so they pass
      # through the `elsif spec` branch above and are handled directly
      # below, one per name.
      quoted_target = quoted_install_target(target, requirements, editable)
      argv = install_argv(pip_bin, upgrade, force_reinstall, extra, requirements, target, editable)
      cmd = with_umask(with_chdir("#{break_system_packages_env}#{quoted_command(pip_bin)} install #{upgrade ? "--upgrade " : ""}#{force_reinstall ? "--force-reinstall " : ""}#{extra_tokens(extra)} #{quoted_target}".strip))
      result = remote_exec(cmd)

      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: pip_failure_msg(result[:stdout], result[:stderr]), include_empty_msg: true, cmd: argv)
      end

      # Ansible's own changed-detection for BOTH present and
      # latest (pip.py: `changed = 'Successfully installed' in
      # out_pip`, the only path when there's no requirements file or
      # VCS name - out_freeze_before stays None): pip prints
      # "Requirement already up-to-date"/"Requirement already
      # satisfied" - never "Successfully installed" - when the
      # invocation genuinely changed nothing.
      changed = result[:stdout].includes?("Successfully installed")

      # Ansible 2.19.11 registered pip orders (live-verified against a venv
      # pip): changed, cmd, name, version, state, requirements,
      # virtualenv, stdout, stderr, stdout_lines, stderr_lines, failed
      # (a fresh venv's create adds ansible_facts + warnings between
      # stderr_lines and failed). krikri emits only changed/stdout of
      # that set today - the pin keeps the shared keys in Ansible's
      # relative order; the missing echo keys are a known set gap.
      PluginResult.new(changed: changed, failed: false, msg: "Package installed", stdout: result[:stdout],
        key_order: ["changed", "stdout"])
    end

    # The shell-quoted install target: a requirements file passes through
    # verbatim, every other target is split back apart (see #install's
    # comment on the parser's comma-joining) and each element re-quoted,
    # carrying the -e flag when editable: is set.
    private def quoted_install_target(target : String, requirements : String?, editable : Bool) : String
      return target if requirements
      split_requirements(target).map { |tval| editable ? "-e #{Process.quote(tval)}" : Process.quote(tval) }.join(" ")
    end

    private def install_argv(pip_bin : String, upgrade : Bool, force_reinstall : Bool, extra : String, requirements : String?, target : String, editable : Bool = false) : Array(String)
      argv_target = requirements ? target.split(' ').reject(&.empty?) : split_requirements(target)
      argv_target = argv_target.flat_map { |tval| editable ? ["-e", tval] : [tval] } if editable && requirements.nil?
      pip_bin.split(' ').reject(&.empty?) + ["install"] + (upgrade ? ["--upgrade"] : [] of String) + (force_reinstall ? ["--force-reinstall"] : [] of String) + extra.split(' ').reject(&.empty?) + argv_target
    end

    # ansible's _fail reports only cmd (the argv it ran) and msg, and
    # always emits a msg key even when both halves are empty
    # (fail_json(msg="")), so no stdout/stderr keys and no empty-msg
    # omission here.
    private def pip_failure_msg(stdout : String, stderr : String) : String
      msg = stdout.empty? ? "" : "stdout: #{stdout}"
      msg += "\n:stderr: #{stderr}" unless stderr.empty?
      msg
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

    # Ansible's pip.py list-type `name:` param auto-splits a raw
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
    # differently than in Ansible).
    #
    # Commas INSIDE a PEP 508 extras bracket are not separators at all:
    # real pip's own requirement grammar treats `pkg[extra1,extra2]` as
    # one atomic token (pip's parser - not Ansible's module - is what
    # makes bracket-interior commas non-separating; a truncated
    # `horovod[keras` is rejected outright with "Expected matching
    # RIGHT_BRACKET"). Ansible reassembles bracket-interior
    # pieces the same way (pip.py's `_recover_package_name` tracks an
    # in-brackets state across its comma-split pieces and joins them
    # back verbatim). Confirmed live in round900263 (grycap.horovod):
    # `name: "horovod[keras,pytorch,tensorflow]"` must reach pip as
    # ONE argv word, and `name: "pkgA[e1,e2],pkgB==1.0"` as two -
    # ansible-playbook -vvv was checked against both before this
    # fix. So a comma only separates requirements when no `[` is
    # currently open; everything inside stays part of the piece,
    # brackets included.
    private def split_requirements(spec : String) : Array(String)
      pieces = [] of String
      current = IO::Memory.new
      depth = 0
      spec.each_char do |char|
        case char
        when '['
          depth += 1
        when ']'
          depth -= 1 if depth > 0
        when ','
          if depth.zero?
            pieces << current.to_s.strip
            current = IO::Memory.new
            next
          end
        end
        current << char
      end
      pieces << current.to_s.strip
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

    # Per-package satisfaction check for the VCS pre-check above: every
    # package already installed, or - for a `==` pin - already at the
    # requested version. pip's own stdlib-shadow skip (pip 25.1:
    # `pip._internal.metadata.base.stdlib_pkgs` = {'argparse', 'python',
    # 'wsgiref'}, found via geerlingguy.elasticsearch-curator's
    # `pip: name: argparse`, round 975000-975099) does not apply here:
    # pip.py decides a VCS install by freeze comparison, which is blind
    # to a same-version reinstall anyway, so counting pip show's find as
    # satisfied matches the freeze result for these names too. For a
    # non-VCS spec the install always runs (see #install), and pip's own
    # output - which DOES reinstall these names every time - decides
    # changed, exactly like Ansible.
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

    # Each extra_args token is shell-quoted individually so an
    # `extra_args:` value can't inject extra shell operations -
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
    # reject pip mutations outright unless overridden - Ansible's
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
      argv = pip_bin.split(' ').reject(&.empty?) + ["uninstall", "-y", bare_name]

      cmd = with_umask(with_chdir("#{break_system_packages_env}#{quoted_command(pip_bin)} uninstall -y #{Shell.single_quote(bare_name)}"))
      result = remote_exec(cmd)

      # Ansible's pip.py treats rc==1 carrying a "not installed" line as
      # the ordinary "nothing to uninstall" outcome and any OTHER non-zero
      # rc as a hard failure reported through _fail(): `cmd` is the exact
      # argv it ran (["<interpreter>", "-m", "pip", "uninstall", "-y",
      # "<pkg>"]) and `msg` is pip_failure_msg's stdout/stderr tagging
      # ("\n:stderr: <stderr>" when stdout is empty). A PEP 668 refusal
      # surfaces exactly like that, not with a bespoke "Failed to
      # uninstall:" prefix and no cmd key (issue #946).
      not_installed = (result[:stdout] + result[:stderr]).downcase.includes?("not installed")
      unless result[:exit_code] == 0 || (result[:exit_code] == 1 && not_installed)
        return PluginResult.new(changed: false, failed: true,
          msg: pip_failure_msg(result[:stdout], result[:stderr]), include_empty_msg: true, cmd: argv)
      end

      # Ansible runs `pip uninstall` unconditionally and lets pip's
      # own "not installed" line decide changed=false - it does NOT
      # pre-check installed-ness locally. Skipping that invocation made
      # a PEP 668 externally-managed environment report state=absent as
      # ok where Ansible fails (pip refuses to even run), so the
      # command must actually be issued and its output parsed.
      if not_installed
        return PluginResult.new(changed: false, failed: false, msg: "Package already absent",
          key_order: ["changed", "stdout"])
      end

      PluginResult.new(changed: true, failed: false, msg: "Package removed", key_order: ["changed", "stdout"])
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::PipPlugin.new(config)
plugin.run
