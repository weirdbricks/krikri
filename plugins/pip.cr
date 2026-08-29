#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
  #   (default: "pip3")
  # - extra_args: appended verbatim to the pip command line
  # - chdir: run pip from this directory
  # - requirements: install from a requirements.txt file instead of a
  #   single name:
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
    def execute : PluginResult
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
      unless @params["virtualenv"]?
        candidate = @params["executable"]? || "pip3"
        # `which`, not the shell builtin `command -v` - LocalExecutor's
        # own no-shell-metacharacters fast path execs argv[0] directly
        # as a real binary (skipping a `bash -c` hop), and "command" is
        # a shell builtin with no standalone executable on this system
        # (or most others) to exec at all.
        unless remote_exec("which #{candidate}")[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "Unable to find any of #{candidate} to use.  pip needs to be installed.")
        end
      end

      # Real Ansible's pip.py: `name` is a list; `if name:` is Python
      # truthiness, so a name: PARAM THAT IS PRESENT but resolves to an
      # EMPTY list (e.g. a templated `name: "{{ some_list_var }}"` that
      # rendered to `[]`) is not an error - it falls straight through to
      # the same "nothing to do" branch pip.py uses, exiting cleanly
      # with changed: false rather than trying to pip-install anything.
      # A name: key that's genuinely absent (not just empty) together
      # with no requirements: is the real required_one_of failure.
      if name.nil? && requirements.nil?
        return raw_name ? PluginResult.new(changed: false, failed: false, msg: "No valid name or requirements file found.") : PluginResult.new(changed: false, failed: true, msg: "name or requirements is required")
      end

      pip_bin = resolve_pip_binary
      return pip_bin if pip_bin.is_a?(PluginResult)

      if umask = @params["umask"]?
        return PluginResult.new(changed: false, failed: true, msg: "umask must be an octal integer") unless umask =~ /\A0?[0-7]{1,4}\z/
      end

      case state
      when "absent"
        remove(pip_bin, name.not_nil!)
      when "latest"
        install(pip_bin, target_spec(name, nil), upgrade: true)
      else
        install(pip_bin, target_spec(name, @params["version"]?), upgrade: false, requirements: requirements)
      end
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

      list = (Array(String).from_json(stripped) rescue nil) ||
             (Array(String).from_json(stripped.gsub('\'', '"')) rescue nil)
      return raw unless list

      case list.size
      when 0 then nil
      when 1 then list[0]
      else        raw
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
          python = @params["virtualenv_python"]? || "python3"
          result = remote_exec("#{python} -m venv #{venv}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: false, failed: true, msg: "Failed to create virtualenv: #{result[:stderr]}")
          end
        end
        pip_path
      else
        @params["executable"]? || "pip3"
      end
    end

    private def with_chdir(command : String) : String
      if chdir = @params["chdir"]?
        "cd #{expand_tilde(chdir)} && #{command}"
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
      package.split(/[=<>!~]/, 2)[0].sub(/\[[^\]]*\]\z/, "")
    end

    private def already_installed?(pip_bin : String, package : String) : Bool
      bare_name = distribution_name(package)
      remote_exec("#{pip_bin} show #{bare_name}")[:exit_code] == 0
    end

    private def installed_version(pip_bin : String, package : String) : String?
      bare_name = distribution_name(package)
      result = remote_exec("#{pip_bin} show #{bare_name} 2>/dev/null")
      return nil unless result[:exit_code] == 0

      result[:stdout].each_line do |line|
        return line.split(":", 2)[1]?.try(&.strip) if line.starts_with?("Version:")
      end
      nil
    end

    private def install(pip_bin : String, spec : String?, upgrade : Bool, requirements : String? = nil) : PluginResult
      target = if requirements
                 "-r #{requirements}"
               elsif spec
                 spec
               else
                 return PluginResult.new(changed: false, failed: true, msg: "name or requirements is required")
               end

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
        packages = spec.not_nil!.split(',').map(&.strip)
        all_satisfied = packages.all? do |package|
          if package.includes?("==")
            bare, _, wanted_version = package.partition("==")
            installed_version(pip_bin, bare) == wanted_version
          else
            already_installed?(pip_bin, package)
          end
        end
        if all_satisfied
          return PluginResult.new(changed: false, failed: false, msg: "Package already installed")
        end
      end

      extra = @params["extra_args"]? || ""
      if true?(@params["editable"]?) && !extra.split(' ').includes?("-e")
        extra = extra.empty? ? "-e" : "#{extra} -e"
      end

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
      quoted_target = requirements ? target : target.split(',').map { |t| Process.quote(t.strip) }.join(" ")
      cmd = with_umask(with_chdir("#{pip_bin} install #{upgrade ? "--upgrade " : ""}#{extra} #{quoted_target}".strip))
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

    private def remove(pip_bin : String, name : String) : PluginResult
      bare_name = name.split(/[=<>!~]/, 2)[0]
      unless already_installed?(pip_bin, bare_name)
        return PluginResult.new(changed: false, failed: false, msg: "Package already absent")
      end

      cmd = with_umask(with_chdir("#{pip_bin} uninstall -y #{bare_name}"))
      result = remote_exec(cmd)

      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to uninstall: #{result[:stderr]}")
      end

      PluginResult.new(changed: true, failed: false, msg: "Package removed")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::PipPlugin.new(config)
plugin.run
