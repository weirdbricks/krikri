require "json"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # Shared implementation for the RPM-family package-manager plugins
    # (`plugins/yum.cr`, `plugins/dnf.cr`): every method here was a
    # byte-identical (modulo the binary name / comment verbosity) copy
    # in both files, and the copies had already drifted once (yum's
    # install path gained the classify/batch refactor dnf never got).
    # Included as INSTANCE methods into both plugin classes, so they
    # dispatch through the includer's own remote_exec/@params/true? -
    # the only per-plugin input is #pkg_manager_binary, which each
    # plugin defines as a one-liner.
    #
    # NOTE: the two plugins' `execute` and install/absent handling are
    # still per-plugin (yum's install path has the newer classify/batch
    # shape; dnf's is the older monolith) - unify those only as part of
    # a deliberate behavioral alignment, not by wholesale deletion.
    module RpmPackage
      # ----- shared execution path (moved verbatim from yum.cr, whose
      # install path was the more-refactored of the two; dnf.cr now
      # delegates to the same methods instead of carrying an older,
      # drifted copy) -----

      private alias BatchOutcome = NamedTuple(changed: Bool, message: String?, output: String, failure: PluginResult?)

      private def early_result_for_empty_names(names : Array(String)) : PluginResult?
        return nil unless names.empty?

        if true?(@params["update_cache"]?)
          result = remote_exec("#{pkg_manager_binary} makecache")
          # changed: false even on success - same fix as dnf.cr's
          # identical branch (see its own comment): real ansible-core's
          # dnf/yum module never reports changed for a cache-only
          # refresh. Found via round172's buluma.rpmfusion.
          return PluginResult.new(
            changed: false,
            failed: result[:exit_code] != 0,
            msg: result[:exit_code] == 0 ? "Package cache updated" : "Failed to update package cache: #{result[:stderr]}"
          )
        end

        # A `name:`/`pkg:` KEY present but templating down to nothing -
        # `name: "{{ redhat_repo_extra_packages }}"` with the var
        # defaulting to `[]` renders as the literal string "[]", which
        # `names_from_name_param` parses down to an empty array. That's
        # exactly as "nothing to install" as no name: at all, and real
        # ansible-core's yum/dnf module reports ok/changed: false for it,
        # not a missing-parameter failure - found via trombik.redhat_repo's
        # "Install extra packages" task (round 601447), which failed here
        # outright while real ansible-playbook reported ok. Mirrors
        # apt.cr's identical fix for the same bug class (round 84000).
        if @params["name"]? || @params["pkg"]?
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Nothing to do"
          )
        end

        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: name"
        )
      end

      private def normalized_state : String
        state = @params["state"]? || "present"
        case state
        when "installed"
          "present"
        when "removed"
          "absent"
        else
          state
        end
      end

      private def special_case_result(names : Array(String), state : String) : PluginResult?
        return handle_autoremove if true?(@params["autoremove"]?) && names == ["*"]
        return handle_upgrade_all if names == ["*"] && state == "latest"
        nil
      end

      private def parse_package_names : Array(String)
        names = names_from_name_param || [] of String

        # Try 'list' parameter (array of packages)
        if list_param = @params["list"]?
          begin
            list_names = JSON.parse(list_param).as_a.map(&.as_s)
            names.concat(list_names)
          rescue
            # If parsing fails, treat as single package
            names << list_param
          end
        end

        # Try free-form parameter
        if names.empty? && (raw_param = @params["_raw_params"]?)
          names = raw_param.split.reject(&.empty?)
        end

        names.uniq
      end

      private def names_from_name_param : Array(String)?
        name_param = @params["name"]? || @params["pkg"]?
        return unless name_param

        parsed_json = parse_name_param_as_json(name_param.strip)

        if parsed_json
          parsed_json
        elsif name_param.includes?(",")
          name_param.split(",").map(&.strip)
        else
          [name_param]
        end
      end

      # ----- `list:` query mode -----
        # Real ansible.builtin.dnf/yum treat a scalar `list:` value as a
        # QUERY, never as packages to act on: `dnf: {list: updates}`
        # lists available updates and returns {"changed": false,
        # "results": [...]} where each result carries name/arch/epoch/
        # version/release/repo (+ nevra/envra). This plugin family
        # previously concatenated a scalar `list:` into the package
        # names (parse_package_names' rescue), so `dnf: {list: updates}`
        # ran `dnf install updates` and failed with "Error: Unable to
        # find a match: updates" where real Ansible succeeded - found
        # via oatakan.rhel_upgrade's own "check for missing updates
        # (dnf)" task (round 310183). A JSON-array `list:` keeps the
        # old package-list behavior below, so this only intercepts the
        # scalar form.
        private def list_query_result : PluginResult?
        list_value = @params["list"]?
        return nil unless list_value

        begin
          return nil if JSON.parse(list_value).as_a
        rescue
          # Not a JSON array - this is the scalar query spec.
        end

        query = list_value.strip
        return nil if query.empty?

        result = remote_exec("#{pkg_manager_binary} list #{shell_single_quote(query)}")

        results = parse_dnf_list_output(result[:stdout])

        PluginResult.new(
          changed: false,
          failed: result[:exit_code] != 0,
          msg: result[:exit_code] == 0 ? "" : "Failed to list packages: #{result[:stderr]}",
          results: results
        )
      end

      # Parses `dnf list <spec>` / `yum list <spec>` output into result
      # dicts shaped like real Ansible's own dnf module list results:
      # name/arch/epoch/version/release/repo/nevra/envra. Package lines
      # look like `name.arch  epoch:version-release  repo` (fields
      # separated by runs of 2+ spaces; the repo column may be absent
      # and an installed line's repo is prefixed `@`); anything else
      # (section headers like "Available Upgrades", cache-timestamp
      # notices) is skipped. Section headers additionally tell spec
      # queries ("Installed Packages" vs "Available Packages") whether
      # a match is installed or available.
      private def parse_dnf_list_output(output : String) : Array(JSON::Any)
        results = [] of JSON::Any
        state : String? = nil

        output.each_line do |line|
          stripped = line.strip
          next if stripped.empty?

          lowered = stripped.downcase
          if !stripped.starts_with?(' ') && lowered.includes?("installed")
            state = "installed"
            next
          elsif !stripped.starts_with?(' ') && (lowered.includes?("available") || lowered.includes?("updated") || lowered.includes?("upgrade"))
            state = "available"
            next
          end

          fields = stripped.split(/ {2,}|\t+/)
          next unless fields.size >= 2

          name_arch = fields[0]
          dot_index = name_arch.rindex('.')
          next unless dot_index
          name = name_arch[0...dot_index]
          arch = name_arch[(dot_index + 1)..]
          next unless !name.empty? && !arch.empty? && arch.matches?(/\A[A-Za-z0-9_]+\z/)

          # Some listings put the epoch in the name column
          # (`1:openssl-libs.x86_64`) - strip it; the version column is
          # the authoritative source below.
          if (name_colon = name.index(':')) && !name[0...name_colon].empty? && name[0...name_colon].chars.all?(&.ascii_number?)
            name = name[(name_colon + 1)..]
          end

          version_field = fields[1]
          epoch = nil
          if (colon = version_field.index(':')) && !version_field[0...colon].empty? && version_field[0...colon].chars.all?(&.ascii_number?)
            epoch = version_field[0...colon]
            version_field = version_field[(colon + 1)..]
          end

          version, release = version_field.split("-", 2)

          repo = fields[2]?.try(&.gsub(/\A@/, ""))
          nevra = "#{name}-#{epoch ? "#{epoch}:" : ""}#{version}-#{release}.#{arch}"

          entry = {
            "name"    => JSON::Any.new(name),
            "arch"    => JSON::Any.new(arch),
            "epoch"   => epoch ? JSON::Any.new(epoch) : JSON::Any.new(nil),
            "version" => JSON::Any.new(version),
            "release" => JSON::Any.new(release),
            "repo"    => repo ? JSON::Any.new(repo) : JSON::Any.new(nil),
            "nevra"   => JSON::Any.new(nevra),
            "envra"   => JSON::Any.new(nevra),
          }
          entry["state"] = JSON::Any.new(state) if state

          results << JSON::Any.new(entry)
        end

        results
      end

      private def parse_name_param_as_json(trimmed : String) : Array(String)?
        return unless trimmed.starts_with?('[') && trimmed.ends_with?(']')

        begin
          Array(String).from_json(trimmed)
        rescue
          # A Python-repr list (single-quoted strings) isn't
          # valid JSON - same fallback as apt.cr's/package.cr's
          # own copies of this logic (see there for the full
          # rationale: a Jinja `{% if %}...{{ [list] }}...
          # {% endif %}` template idiom renders as Python's
          # `str(list)` form, not JSON). Proactive fix - not
          # yet caught live for dnf specifically, but the
          # exact same bug class already found independently
          # in two other plugins this way.
          begin
            Array(String).from_json(trimmed.gsub('\'', '"'))
          rescue
            nil
          end
        end
      end

      private def handle_install(names : Array(String), options : String) : PluginResult
        # Check if update_only is set
        update_only = true?(@params["update_only"]?)

        classified = classify_install_packages(names, update_only)
        to_install = classified[:to_install]
        to_update = classified[:to_update]
        already_installed = classified[:already_installed]

        changed = false
        messages = [] of String
        all_output = [] of String

        # Install new packages
        unless to_install.empty?
          outcome = run_install_batch(to_install, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          changed ||= outcome[:changed]
          if message = outcome[:message]
            messages << message
          end
        end

        # Update packages (if update_only mode)
        unless to_update.empty?
          outcome = run_update_batch(to_update, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          changed ||= outcome[:changed]
          if message = outcome[:message]
            messages << message
          end
        end

        # Report already installed
        unless already_installed.empty?
          messages << "Already installed: #{already_installed.join(", ")}"
        end

        msg = messages.empty? ? "No changes needed" : messages.join("; ")

        PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          stdout: all_output.join("\n"),
          exit_code: 0
        )
      end

      private def classify_install_packages(names : Array(String), update_only : Bool) : NamedTuple(to_install: Array(String), to_update: Array(String), already_installed: Array(String))
        to_install = [] of String
        to_update = [] of String
        already_installed = [] of String

        names.each do |pkg|
          if package_group?(pkg)
            # For groups, always try to install (dnf handles idempotency)
            to_install << pkg
          elsif url_or_file?(pkg)
            # For URLs/files, always try to install
            to_install << pkg
          else
            # Check if package is installed
            if package_installed?(pkg)
              if update_only
                to_update << pkg
              else
                already_installed << pkg
              end
            else
              if update_only
                # Don't install new packages in update_only mode
                already_installed << pkg
              else
                to_install << pkg
              end
            end
          end
        end

        {to_install: to_install, to_update: to_update, already_installed: already_installed}
      end

      private def handle_remove(names : Array(String), options : String) : PluginResult
        to_remove = [] of String
        already_absent = [] of String

        # Check which packages need to be removed
        names.each do |pkg|
          if package_group?(pkg)
            # For groups, always try to remove (dnf handles if not installed)
            to_remove << pkg
          else
            if package_installed?(pkg)
              to_remove << pkg
            else
              already_absent << pkg
            end
          end
        end

        # Nothing to do
        if to_remove.empty?
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "All packages already absent",
            exit_code: 0
          )
        end

        # Build remove command
        autoremove_flag = true?(@params["autoremove"]?) ? "" : "--setopt=clean_requirements_on_remove=False"
        pkg_list = to_remove.map { |pth| quote_package(pth) }.join(" ")
        cmd = "#{pkg_manager_binary} remove #{options} #{autoremove_flag} #{pkg_list}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          msg_parts = ["Removed: #{to_remove.join(", ")}"]
          msg_parts << "Already absent: #{already_absent.join(", ")}" unless already_absent.empty?

          PluginResult.new(
            changed: true,
            failed: false,
            msg: msg_parts.join("; "),
            stdout: result[:stdout],
            exit_code: 0
          )
        else
          PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to remove packages",
            stdout: result[:stdout],
            stderr: result[:stderr],
            exit_code: result[:exit_code]
          )
        end
      end

      # Real Ansible's dnf/yum module `state: latest` installs a not-yet-
      # installed package (there is nothing to "update" yet) and upgrades
      # one that's already present - it never runs a bare `dnf/yum update
      # <name>` unconditionally, which fails outright ("No match for
      # argument", "No packages marked for upgrade") for any name not
      # already installed. Found via alvistack.openjdk (RHEL-family round
      # 60420): `dnf: {name: temurin-21-jdk, state: latest}` on a fresh
      # host installed fine under real ansible-playbook but failed here.
      # Reuses the same classify/batch helpers `handle_install` already
      # gets right, just routing "not installed" to an install batch
      # instead of `already_installed`.
      private def handle_update(names : Array(String), options : String) : PluginResult
        to_install = [] of String
        to_update = [] of String

        names.each do |pkg|
          if package_group?(pkg) || url_or_file?(pkg)
            to_install << pkg
          elsif package_installed?(pkg)
            to_update << pkg
          else
            to_install << pkg
          end
        end

        changed = false
        messages = [] of String
        all_output = [] of String

        unless to_install.empty?
          outcome = run_install_batch(to_install, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          changed ||= outcome[:changed]
          if message = outcome[:message]
            messages << message
          end
        end

        unless to_update.empty?
          outcome = run_update_batch(to_update, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          changed ||= outcome[:changed]
          if message = outcome[:message]
            messages << message
          end
        end

        msg = messages.empty? ? "Packages already at latest version" : messages.join("; ")

        PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          stdout: all_output.join("\n"),
          exit_code: 0
        )
      end

      private def run_install_batch(to_install : Array(String), options : String) : BatchOutcome
        pkg_list = to_install.map { |pth| quote_package(pth) }.join(" ")
        cmd = "#{pkg_manager_binary} install #{options} #{pkg_list}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        if result[:exit_code] != 0
          return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to install packages",
            stdout: result[:stdout],
            stderr: result[:stderr],
            exit_code: result[:exit_code]
          )}
        end

        # A requested name can be a virtual package already satisfied
        # by something else installed - `package_installed?`'s own
        # `dnf list installed <name>` pre-check only ever looks up the
        # literal requested name, which a purely virtual/Provides:-
        # satisfied name never has its own `dnf list installed` entry
        # for, so it always fell through to "needs install" here. dnf
        # itself prints a literal "Nothing to do." and still exits 0
        # for that case (a genuine no-op), so trusting exit_code alone
        # always reported changed: true even when nothing happened -
        # same bug class already fixed in apt.cr/package.cr's own
        # apt-get install handling (apt_summary_had_no_effect?), which
        # this handler never got ported to since it's a separate
        # RPM-based code path.
        if result[:stdout].includes?("Nothing to do")
          {changed: false, message: "Package#{to_install.size > 1 ? "s" : ""} #{to_install.join(", ")} already satisfied", output: result[:stdout], failure: nil}
        else
          {changed: true, message: "Installed: #{to_install.join(", ")}", output: result[:stdout], failure: nil}
        end
      end

      private def run_update_batch(to_update : Array(String), options : String) : BatchOutcome
        pkg_list = to_update.map { |pth| quote_package(pth) }.join(" ")
        cmd = "#{pkg_manager_binary} update #{options} #{pkg_list}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        if result[:exit_code] != 0
          return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to update packages",
            stdout: result[:stdout],
            stderr: result[:stderr],
            exit_code: result[:exit_code]
          )}
        end

        # Check if anything was actually updated
        if result[:stdout].includes?("Upgraded:") || result[:stdout].includes?("Installed:")
          {changed: true, message: "Updated: #{to_update.join(", ")}", output: result[:stdout], failure: nil}
        else
          {changed: false, message: nil, output: result[:stdout], failure: nil}
        end
      end

      # The package-manager command each includer shells out to ("yum"
      # / "dnf"). Defined by the including plugin class.
      abstract def pkg_manager_binary : String

      private def remote_exec_tolerating_unknown_repo(cmd : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
        result = remote_exec(cmd)
        if result[:exit_code] != 0 && (m = result[:stderr].match(/Unknown repo: '([^']+)'/))
          stripped_cmd = cmd.gsub("--enablerepo=#{m[1]}", "").gsub(/  +/, " ")
          return remote_exec_tolerating_unknown_repo(stripped_cmd) if stripped_cmd != cmd
        end
        result
      end

      private def url_or_file?(name : String) : Bool
        name.starts_with?("http://") ||
          name.starts_with?("https://") ||
          name.starts_with?("ftp://") ||
          name.starts_with?("/")
      end

      private def quote_package(name : String) : String
        if name.includes?(" ") || name.includes?(">") || name.includes?("<")
          "'#{name}'"
        else
          name
        end
      end

      private def package_group?(name : String) : Bool
        name.starts_with?("@")
      end

      private def package_installed?(name : String) : Bool
        # Strip version specifiers for checking
        base_name = name.split(/[<>=]/).first.strip

        # Try a plain `rpm -q <name>` first (correctly matches both a
        # bare name and a NEVRA-style "name-version" specifier), falling
        # back to `--whatprovides` (a Provides:/capability lookup) only
        # for a VIRTUAL package name satisfied purely via another real
        # package's `Provides:` (e.g. RHEL 9's `php-json`, bundled into
        # `php-common` since PHP 8.0) - `--whatprovides` ALONE regresses
        # any version-pinned NEVRA name (`rpm -q --whatprovides
        # telegraf-1.18.2` fails even when that exact NEVRA is installed,
        # verified live), so both checks are needed, in this order.
        result = remote_exec("rpm -q #{shell_single_quote(base_name)} 2>/dev/null")
        return true if result[:exit_code] == 0

        result = remote_exec("rpm -q --whatprovides #{shell_single_quote(base_name)} 2>/dev/null")
        result[:exit_code] == 0
      end

      private def handle_autoremove : PluginResult
        options = build_dnf_options
        cmd = "#{pkg_manager_binary} autoremove #{options}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          changed = result[:stdout].includes?("Removed:")

          msg = changed ? "Removed unneeded packages" : "No unneeded packages to remove"

          PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg,
            stdout: result[:stdout],
            exit_code: 0
          )
        else
          PluginResult.new(
            changed: false,
            failed: true,
            msg: "Autoremove failed",
            stdout: result[:stdout],
            stderr: result[:stderr],
            exit_code: result[:exit_code]
          )
        end
      end

      private def handle_upgrade_all : PluginResult
        options = build_dnf_options
        cmd = "#{pkg_manager_binary} upgrade #{options}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          changed = result[:stdout].includes?("Upgraded:") ||
                    result[:stdout].includes?("Installed:")

          msg = changed ? "System upgraded" : "All packages already up to date"

          PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg,
            stdout: result[:stdout],
            exit_code: 0
          )
        else
          PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to upgrade system",
            stdout: result[:stdout],
            stderr: result[:stderr],
            exit_code: result[:exit_code]
          )
        end
      end

      private def build_dnf_options : String
        options = [] of String

        # Always use -y for non-interactive
        options << "-y"

        # Enable/disable repos - a blank entry (e.g. `enablerepo: "{{ some_var
        # | default('') }}"` resolving empty) is real Ansible's own no-op,
        # not a repo named "". Passing it through as `--enablerepo=` instead
        # makes dnf hard-fail with `Error: Unknown repo: ''` - found via
        # gabops.cron (RHEL-family round 60447).
        if enablerepo = @params["enablerepo"]?
          enablerepo.split(",").each do |repo|
            repo = repo.strip
            options << "--enablerepo=#{repo}" unless repo.empty?
          end
        end

        if disablerepo = @params["disablerepo"]?
          disablerepo.split(",").each do |repo|
            repo = repo.strip
            options << "--disablerepo=#{repo}" unless repo.empty?
          end
        end

        # GPG check - real ansible's dnf module explicitly sets BOTH
        # conf.gpgcheck AND conf.localpkg_gpgcheck to `not disable_gpg_check`
        # (verified in ansible-core's own dnf.py: "conf.localpkg_gpgcheck =
        # not disable_gpg_check"), overriding dnf's own actual default for
        # local/URL package installs, which is gpgcheck-OFF regardless of
        # the repo gpgcheck=1 setting in dnf.conf. Plain `--nogpgcheck` only
        # covers the repo-package path; without also forcing
        # `--setopt=localpkg_gpgcheck=1` here, a `name: https://.../foo.rpm`
        # install silently skipped signature verification (inherited dnf's
        # own default), diverging from real ansible-playbook which
        # correctly refuses an RPM whose signing key isn't imported. Found
        # benchmarking geerlingguy.selenium's "Install Chrome (if
        # configured, RedHat)" task (direct google-chrome-stable RPM URL,
        # no imported key) - real ansible failed with "Failed to validate
        # GPG signature", krikri-playbook installed it anyway.
        if true?(@params["disable_gpg_check"]?)
          options << "--nogpgcheck"
        else
          options << "--setopt=localpkg_gpgcheck=1"
        end

        # Security/bugfix updates
        if true?(@params["security"]?)
          options << "--security"
        end

        if true?(@params["bugfix"]?)
          options << "--bugfix"
        end

        # Weak dependencies
        if false?(@params["install_weak_deps"]?)
          options << "--setopt=install_weak_deps=False"
        end

        # Skip broken packages
        if true?(@params["skip_broken"]?)
          options << "--skip-broken"
        end

        # Allow downgrade
        if true?(@params["allow_downgrade"]?)
          options << "--allowerasing"
        end

        # Best (default in dnf, but explicit is good)
        options << "--best" unless true?(@params["skip_broken"]?)

        options.join(" ")
      end
    end
  end
end
