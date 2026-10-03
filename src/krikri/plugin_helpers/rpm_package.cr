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

      # ------------------------------------------------------------------
      # Real ansible-core 2.19.11 `ansible.builtin.dnf` registered-result
      # shapes (live-verified inside a fedora:41 container through
      # `{{ r | to_json }}` on a registered task, one FRESH container per
      # engine so both engines saw identical host state):
      #
      #   install/remove/latest (the module's own `response` dict, which
      #   it initializes msg/changed/results/rc and exits with via
      #   exit_json(**response)): results, changed, msg, rc, failed - msg
      #   "Nothing to do" on a no-op, "" on a real transaction, results
      #   holding "Installed: <name>-<version>-<release>.<arch>" /
      #   "Removed: <nevra>" entries.
      #   update_cache only (a literal exit_json(msg=, changed=, results=,
      #   rc=) call, so THAT path keeps the module's kwargs order): msg,
      #   changed, results, rc, failed - msg "Cache updated".
      #   `list:` (list_items' exit_json(msg="", results=results)): msg,
      #   results, failed.
      #   failure (failure_response = msg/failures/results/rc): msg,
      #   failures, results, rc, failed.
      #
      # `ansible_facts` and `warnings` also appear in real's registered
      # result (the interpreter-discovery warning and the fact the
      # controller merges in) but have no krikri equivalent - same as
      # every other plugin pinned in this sweep.
      #
      # dnf5 shares these shapes except its `list:` path, which also
      # carries rc (its own exit_json(msg="", results=results, rc=0)) -
      # see dnf5.cr's #list_result_key_order.
      DNF_TRANSACTION_ORDER = %w[results changed msg rc failed]
      DNF_CACHE_ORDER       = %w[msg changed results rc failed]
      # `list:` - real's exit_json(msg="", results=results) carries no
      # `changed`, so the CONTROLLER backfills it AFTER `failed`; `rc`
      # rides along because the 2.19.11 module's own list path reports it
      # (both observed live, in this order, on fedora:41).
      DNF_LIST_ORDER        = %w[msg results rc failed changed]
      DNF_FAILURE_ORDER     = %w[msg failures results rc failed]

      # The key order an includer uses for a `list:` query result - dnf's
      # own list_items() passes no rc, dnf5's does (plugins/dnf5.cr
      # overrides this).
      private def list_result_key_order : Array(String)
        DNF_LIST_ORDER
      end

      # The msg real reports for a cache-only refresh. dnf and dnf5 both
      # use "Cache updated" (their own run() early-exit).
      private def cache_updated_msg : String
        "Cache updated"
      end

      # Real's `results` entries are built from the RPM database, not
      # from the requested spec: "Installed: sl-5.02-22.fc41.x86_64".
      # Ask rpm for the installed NEVRA of `pkg` (name-version-release
      # .arch, epoch omitted when zero) and fall back to the requested
      # spec for anything rpm cannot name (a group, a URL/local RPM, a
      # virtual provide) - a stable, deterministic string either way.
      private def rpm_nevra(pkg : String) : String
        result = remote_exec_tolerating_unknown_repo(
          "rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' #{quote_package(pkg)}"
        )
        out = result[:stdout].strip
        return pkg if result[:exit_code] != 0 || out.empty? || out.includes?("not installed")
        out
      end

      # The transaction success shape: results, changed, msg, rc, failed.
      # Real leaves msg EMPTY on a transaction it performed and says
      # "Nothing to do" when the transaction resolved to nothing, so an
      # empty msg must actually be emitted (include_empty_msg).
      private def transaction_result(changed : Bool, results : Array(String) = [] of String) : PluginResult
        PluginResult.new(
          changed: changed,
          failed: false,
          msg: changed ? "" : "Nothing to do",
          include_empty_msg: true,
          results: results,
          rc: 0,
          key_order: DNF_TRANSACTION_ORDER
        )
      end

      # Real's failure shape: msg, failures, results, rc, failed. The
      # backend's own error text is what goes in `failures`.
      private def failure_result(msg : String, failures : Array(String), rc : Int32 = 1) : PluginResult
        PluginResult.new(
          changed: false,
          failed: true,
          msg: msg,
          include_empty_msg: true,
          failures: failures,
          results: [] of String,
          rc: rc,
          key_order: DNF_FAILURE_ORDER
        )
      end

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
            msg: result[:exit_code] == 0 ? cache_updated_msg : "Failed to update package cache: #{result[:stderr]}",
            include_empty_msg: true,
            results: [] of String,
            rc: 0,
            key_order: DNF_CACHE_ORDER
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
            msg: "Nothing to do",
            include_empty_msg: true,
            results: [] of String,
            rc: 0,
            key_order: DNF_TRANSACTION_ORDER
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

        result = remote_exec("#{pkg_manager_binary} #{list_args(query)}")

        # The magic query words are POSITIONAL subcommands on the dnf4
        # CLI, but Fedora 41's dnf4 (libdnf5-backed) rejects them -
        # `dnf list installed` exits 1 with "No matching packages to
        # list", where the equivalent FLAG form works. Real's dnf module
        # goes through the libdnf API and lists the installed set either
        # way, so retry the magic words as flags before giving up.
        if result[:exit_code] != 0 && (flag = list_flag(query))
          retry_result = remote_exec("#{pkg_manager_binary} list #{flag}")
          result = retry_result if retry_result[:exit_code] == 0
        end

        results = parse_dnf_list_output(result[:stdout])

        PluginResult.new(
          changed: false,
          failed: result[:exit_code] != 0,
          msg: result[:exit_code] == 0 ? "" : "Failed to list packages: #{result[:stderr]}",
          include_empty_msg: true,
          results: results,
          rc: 0,
          key_order: list_result_key_order
        )
      end

      # The flag spelling of dnf's magic list words, or nil for a plain
      # package spec (which has no flag form).
      private def list_flag(query : String) : String?
        case query
        when "installed"             then "--installed"
        when "available"             then "--available"
        when "updates", "upgrades"   then "--upgrades"
        when "extras"                then "--extras"
        when "obsoletes"             then "--obsoletes"
        end
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
          if fields.size < 2
            # Fedora's dnf prints a spec query's columns separated by a
            # SINGLE space (`bash.x86_64 5.2.32-1.fc41 @System`), where
            # the aligned multi-column listing splits on runs of 2+
            # spaces. Fall back to a single-space split, which is only
            # safe because the first column was just validated as
            # `name.arch` below.
            single = stripped.split(' ')
            fields = single if single.size >= 2
          end
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

          repo = fields[2]?
          nevra = "#{name}-#{version}-#{release}.#{arch}"

          # Real's own per-package dict (dnf.py's _package_dict,
          # live-verified against ansible-core 2.19.11 on fedora:41):
          # name, arch, epoch (ALWAYS a string, "0" when unset), release,
          # version, repo (the literal column value - "@System" for an
          # installed row, NOT de-@'d), nevra/envra both spelled
          # name-version-release.arch, and yumstate naming which side of
          # the query matched the row - there is no "state" key.
          entry = {
            "name"     => JSON::Any.new(name),
            "arch"     => JSON::Any.new(arch),
            "epoch"    => JSON::Any.new(epoch || "0"),
            "release"  => JSON::Any.new(release),
            "version"  => JSON::Any.new(version),
            "repo"     => repo ? JSON::Any.new(repo) : JSON::Any.new(nil),
            "nevra"    => JSON::Any.new(nevra),
            "envra"    => JSON::Any.new(nevra),
            "yumstate" => JSON::Any.new(state || "available"),
          }

          results << JSON::Any.new(entry)
        end

        results
      end

      private def parse_name_param_as_json(trimmed : String) : Array(String)?
        return unless trimmed.starts_with?('[') && trimmed.ends_with?(']')

        # ONLY valid JSON - never a Python-repr repair pass. A value that
        # merely LOOKS like a container (a literal `name: "['pkg1']"`
        # string, or a `{% if %}...{% else %}['pkg1']{% endif %}` block's
        # rendered output) is a plain STRING in real ansible-core -
        # native typing requires the template's whole AST to be one
        # output node wrapping one expression, so block-tag output is
        # never re-parsed (live-verified vs ansible-playbook 2.19.11,
        # see apt.cr's parse_package_names). A whole-value `{{ list_var }}`
        # container arg arrives as the double-quoted JSON the wire
        # serialized it to (see substitute_task_params's
        # whole-single-span comment), which the plain JSON parse above
        # already handles.
        Array(String).from_json(trimmed) rescue nil
      end

      private def handle_install(names : Array(String), options : String) : PluginResult
        # Check if update_only is set
        update_only = true?(@params["update_only"]?)

        classified = classify_install_packages(names, update_only)
        to_install = classified[:to_install]
        to_update = classified[:to_update]

        changed = false
        installed = [] of String
        all_output = [] of String

        # Install new packages
        unless to_install.empty?
          outcome = run_install_batch(to_install, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          if outcome[:changed]
            changed = true
            # Real builds `results` from the transaction's own package
            # set, i.e. the RPM NEVRA that actually landed - not the
            # requested spec (see #rpm_nevra).
            installed.concat(to_install.map { |pkg| "Installed: #{rpm_nevra(pkg)}" })
          end
        end

        # Update packages (if update_only mode)
        unless to_update.empty?
          outcome = run_update_batch(to_update, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          if outcome[:changed]
            changed = true
            installed.concat(to_update.map { |pkg| "Installed: #{rpm_nevra(pkg)}" })
          end
        end

        # Real's no-op path reports NOTHING about the packages that were
        # already there (msg "Nothing to do", empty results) - the
        # "Already installed: ..." summary this used to build is a
        # krikri-only shape, dropped to match.
        transaction_result(changed, installed)
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

        # Check which packages need to be removed
        names.each do |pkg|
          if package_group?(pkg)
            # For groups, always try to remove (dnf handles if not installed)
            to_remove << pkg
          elsif package_installed?(pkg)
            to_remove << pkg
          end
        end

        # Nothing to do - real's no-op shape (results [], msg "Nothing to
        # do", rc 0), which says nothing about which packages were already
        # absent.
        if to_remove.empty?
          return transaction_result(false)
        end

        # Real's `results` entries name the RPM that was removed, so the
        # NEVRA has to be read BEFORE the transaction erases it.
        nevras = {} of String => String
        to_remove.each { |pkg| nevras[pkg] = rpm_nevra(pkg) }

        # Build remove command
        autoremove_flag = true?(@params["autoremove"]?) ? "" : "--setopt=clean_requirements_on_remove=False"
        pkg_list = to_remove.map { |pth| quote_package(pth) }.join(" ")
        cmd = "#{pkg_manager_binary} remove #{options} #{autoremove_flag} #{pkg_list}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          PluginResult.new(
            changed: true,
            failed: false,
            msg: "",
            include_empty_msg: true,
            results: to_remove.map { |pkg| "Removed: #{nevras[pkg]? || pkg}" },
            rc: 0,
            key_order: DNF_TRANSACTION_ORDER
          )
        else
          failure_result(
            "Failed to remove packages",
            error_lines(result),
            result[:exit_code] == 0 ? 1 : result[:exit_code]
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
        installed = [] of String
        all_output = [] of String

        unless to_install.empty?
          outcome = run_install_batch(to_install, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          if outcome[:changed]
            changed = true
            installed.concat(to_install.map { |pkg| "Installed: #{rpm_nevra(pkg)}" })
          end
        end

        unless to_update.empty?
          outcome = run_update_batch(to_update, options)
          all_output << outcome[:output]

          failure = outcome[:failure]
          return failure if failure

          if outcome[:changed]
            changed = true
            installed.concat(to_update.map { |pkg| "Installed: #{rpm_nevra(pkg)}" })
          end
        end

        # `state: latest` on an already-latest host is real's ordinary
        # no-op (results [], msg "Nothing to do") - not a "Packages
        # already at latest version" summary of this engine's own making.
        transaction_result(changed, installed)
      end

      private def run_install_batch(to_install : Array(String), options : String) : BatchOutcome
        pkg_list = to_install.map { |pth| quote_package(pth) }.join(" ")
        cmd = "#{pkg_manager_binary} install #{options} #{pkg_list}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        if result[:exit_code] != 0
          return {changed: false, message: nil, output: result[:stdout], failure: failure_result("Failed to install packages", error_lines(result), result[:exit_code])}
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
        elsif to_install.any? { |pkg| package_group?(pkg) } && group_install_noop?(result[:stdout])
          {changed: false, message: "Package#{to_install.size > 1 ? "s" : ""} #{to_install.join(", ")} already satisfied", output: result[:stdout], failure: nil}
        else
          {changed: true, message: "Installed: #{to_install.join(", ")}", output: result[:stdout], failure: nil}
        end
      end

      # Real yum/dnf CLI's own no-op shape for an ALREADY-INSTALLED
      # package GROUP is different from a plain package's: the CLI never
      # prints "Nothing to do" for a group (verified live in a
      # rockylinux:9 container - a second `yum -y install
      # @"Development tools"` exits 0 with a full "Dependencies resolved."
      # run whose "Transaction Summary" section lists NO
      # `Install N Packages` / `Upgrade N Packages` count line at all,
      # just the `====` rule and then `Complete!`), while a transaction
      # that actually installs or upgrades anything always carries at
      # least one such count line right after the Transaction Summary
      # header. Round 900999 tcosta84.yum found the gap: its
      # `yum: {name: "@Development tools", state: present}` warm rerun
      # reported changed: false under real ansible-playbook (whose module
      # uses the yum Python API and knows nothing needs installing) but
      # changed: true here on every run, because this handler trusted
      # exit_code plus the plain-package "Nothing to do" text alone.
      # Only consulted for batches that actually contained a group, so
      # plain-package batches keep the existing "Nothing to do"
      # detection untouched.
      private def group_install_noop?(output : String) : Bool
        in_summary = false
        output.each_line do |line|
          stripped = line.strip
          if in_summary
            return false if stripped.matches?(/\A(?:Install|Upgrade|Remove|Reinstall|Downgrade)\s+\d+\s+Packages?\z/)
            return true if stripped == "Complete!"
          else
            in_summary = true if stripped == "Transaction Summary"
          end
        end
        false
      end

      private def run_update_batch(to_update : Array(String), options : String) : BatchOutcome
        pkg_list = to_update.map { |pth| quote_package(pth) }.join(" ")
        cmd = "#{pkg_manager_binary} #{update_verb} #{options} #{pkg_list}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        if result[:exit_code] != 0
          return {changed: false, message: nil, output: result[:stdout], failure: failure_result("Failed to update packages", error_lines(result), result[:exit_code])}
        end

        # Check if anything was actually updated
        if result[:stdout].includes?("Upgraded:") || result[:stdout].includes?("Installed:")
          {changed: true, message: "Updated: #{to_update.join(", ")}", output: result[:stdout], failure: nil}
        else
          {changed: false, message: nil, output: result[:stdout], failure: nil}
        end
      end

      # Real's failure shape carries the backend's own error lines in
      # `failures` (failure_response['failures'] is appended to as the
      # transaction goes wrong) - stderr first, then any stdout error
      # lines, each stripped, so the list is deterministic.
      private def error_lines(result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : Array(String)
        lines = [] of String
        result[:stderr].each_line { |line| lines << line.strip }
        result[:stdout].each_line { |line| lines << line.strip }
        lines.reject(&.empty?)
      end

      # The package-manager command each includer shells out to ("yum"
      # / "dnf"). Defined by the including plugin class.
      abstract def pkg_manager_binary : String

      # The verb used to upgrade already-installed packages to their
      # latest version. yum/dnf accept "update"; dnf5 renamed it to
      # "upgrade" and no longer ships an "update" alias, so the dnf5
      # plugin overrides this. handle_upgrade_all always uses "upgrade"
      # (valid on every backend).
      private def update_verb : String
        "update"
      end

      # The `list <query>` argument string (everything after the binary)
      # for a scalar `list:` query. dnf/yum accept the query word as a
      # positional subcommand (`dnf list installed`); included as a hook so
      # dnf5 - whose `list` takes `--installed`/`--available`/`--upgrades`
      # FLAGS instead - can override it. Default keeps the existing
      # single-quoted-positional behavior byte-for-byte.
      # remote_exec hands the command to an ARGV splitter, not to a
      # shell, so shell-quoting the query here passed the literal quotes
      # through to dnf as part of the package spec: `list: installed`
      # became `dnf list 'installed'`, which matches nothing ("No
      # matching packages to list"), and `list: bash` silently returned
      # an EMPTY results list instead of the package real's own
      # `dnf list bash` reports (both live-verified against
      # ansible-core 2.19.11 on fedora:41). Pass the spec through bare.
      private def list_args(query : String) : String
        "list #{query}"
      end

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
          # Real's autoremove has no prose summary of its own: it goes
          # through the very same transaction result as any other dnf
          # call, so a removal reports its `results` entries and a no-op
          # reports "Nothing to do".
          transaction_result(changed, autoremove_results(result[:stdout]))
        else
          failure_result("Autoremove failed", error_lines(result), result[:exit_code])
        end
      end

      # The packages an autoremove/upgrade transaction reported removing,
      # in real's `results` spelling. The dnf transaction summary lists
      # them as "Removed:  <name>-<version>-<release>.<arch>", which is
      # already exactly the string real's results array carries.
      private def autoremove_results(output : String) : Array(String)
        output.each_line.map(&.strip).select { |line| line.starts_with?("Removed:") }.map { |line| line.sub(/^Removed:\s*/, "") }.reject(&.empty?).to_a
      end

      private def handle_upgrade_all : PluginResult
        options = build_dnf_options
        cmd = "#{pkg_manager_binary} upgrade #{options}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          changed = result[:stdout].includes?("Upgraded:") ||
                    result[:stdout].includes?("Installed:")
          transaction_result(changed, upgrade_results(result[:stdout]))
        else
          failure_result("Failed to upgrade system", error_lines(result), result[:exit_code])
        end
      end

      # The packages an upgrade transaction touched, in real's `results`
      # spelling - the transaction summary's own "Upgraded:" /
      # "Installed:" lines, which are already the exact strings real
      # puts in that array.
      private def upgrade_results(output : String) : Array(String)
        output.each_line.map(&.strip).select { |line| line.starts_with?("Upgraded:") || line.starts_with?("Installed:") }.reject(&.empty?).to_a
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

        # Best (default in dnf, but explicit is good). Real ansible-core's
        # dnf module has only `nobest` in its shared yumdnf argument spec
        # (`conf.best = not self.nobest`, verified in ansible-core's own
        # dnf.py _configure_base) - there is no `best:` parameter (one was
        # invented here briefly and had to go, real Ansible rejects it as
        # an unsupported parameter), and the documented default is "set by
        # the operating system distribution", so nothing is emitted when
        # it is not given - the historical unconditional `--best` (dnf's
        # own built-in default) is kept for that case.
        if nobest = @params["nobest"]?
          options << (true?(nobest) ? "--nobest" : "--best")
        elsif !true?(@params["skip_broken"]?)
          options << "--best"
        end

        # Allow erasing already-installed packages to resolve dependencies
        # (dnf's own --allowerasing transaction flag). Verified in
        # ansible-core's dnf.py: `allowerasing` goes straight into
        # `base.resolve(allow_erasing=self.allowerasing)`. (NB: the
        # pre-existing `allow_downgrade:` branch above also emits
        # --allowerasing - left as found rather than silently re-pointed,
        # though real ansible-core implements allow_downgrade in module
        # logic, not via this flag.)
        if true?(@params["allowerasing"]?)
          options << "--allowerasing"
        end

        # Run entirely from the local cache - no metadata download/update
        # (dnf's -C/--cacheonly; real ansible-core sets conf.cacheonly,
        # dnf.py _configure_base).
        if true?(@params["cacheonly"]?)
          options << "--cacheonly"
        end

        # Alternate dnf.conf path (dnf's -c/--config). Real ansible-core
        # points conf.config_file_path at it and fails when unreadable
        # (dnf.py _configure_base); the CLI pass-through relies on dnf's
        # own equivalent read failure.
        if conf_file = @params["conf_file"]?
          options << "--config=#{shell_single_quote(conf_file)}" unless conf_file.strip.empty?
        end

        # Disable dnf.conf excludes entirely ("all"), just [main]'s
        # ("main"), or one repo's ("<repoid>") for this transaction (dnf's
        # --disableexcludes; real ansible-core appends to
        # conf.disable_excludes, dnf.py _configure_base).
        if disable_excludes = @params["disable_excludes"]?
          options << "--disableexcludes=#{disable_excludes}" unless disable_excludes.strip.empty?
        end

        # Per-transaction plugin enable/disable (dnf's
        # --enableplugin/--disableplugin). Real ansible-core passes these
        # sets to base.init_plugins (dnf.py _base) - never persisted
        # beyond the transaction, exactly like the CLI flags.
        string_list_param("enable_plugin").each do |plugin|
          options << "--enableplugin=#{plugin}"
        end

        string_list_param("disable_plugin").each do |plugin|
          options << "--disableplugin=#{plugin}"
        end

        # Package name(s) to exclude from present/latest operations (dnf's
        # --exclude; real ansible-core appends to conf.exclude, dnf.py
        # _configure_base - a list or comma-separated string, listified
        # exactly like enablerepo/disablerepo already are above). Quoted
        # so a glob like `kernel*` reaches dnf without the target shell
        # expanding it.
        string_list_param("exclude").each do |pkg|
          options << "--exclude=#{shell_single_quote(pkg)}"
        end

        # Alternate install root, relative to which all packages install
        # (dnf's --installroot; real ansible-core sets conf.installroot,
        # dnf.py _configure_base, defaulting to "/"). "/" is dnf's own
        # default, so it isn't emitted.
        if installroot = @params["installroot"]?
          options << "--installroot=#{shell_single_quote(installroot)}" unless installroot.strip.empty? || installroot == "/"
        end

        # Install packages as if running a different OS release version
        # (dnf's --releasever; real ansible-core overrides
        # conf.substitutions['releasever'], dnf.py _configure_base).
        if releasever = @params["releasever"]?
          options << "--releasever=#{shell_single_quote(releasever)}" unless releasever.strip.empty?
        end

        # Disable SSL validation of the repo servers for this transaction
        # (dnf's sslverify conf option via --setopt; real ansible-core sets
        # conf.sslverify = sslverify, dnf.py _configure_base, default
        # true). Only the false case needs a flag - true is dnf's default.
        if false?(@params["sslverify"]?)
          options << "--setopt=sslverify=False"
        end

        # Download packages without installing (dnf's --downloadonly; real
        # ansible-core sets conf.downloadonly, dnf.py _configure_base).
        if true?(@params["download_only"]?)
          options << "--downloadonly"
        end

        # Alternate package-download directory - only meaningful with
        # download_only, exactly as in real ansible-core (conf.destdir is
        # only set when download_only is set, dnf.py _configure_base).
        if true?(@params["download_only"]?) && (download_dir = @params["download_dir"]?)
          options << "--downloaddir=#{shell_single_quote(download_dir)}" unless download_dir.strip.empty?
        end

        options.join(" ")
      end

      # List-typed params (`exclude:`, `enable_plugin:`, `disable_plugin:`)
      # arrive either as a JSON array string (the PluginManager serializes
      # list params with JSON's own .to_s) or as the comma-separated string
      # real Ansible's yumdnf.listify_comma_sep_strings_in_list still
      # accepts for these same options ("It's possible someone passed a
      # comma separated string since it used to be a string type"). ONLY
      # valid JSON, though - never a Python-repr repair pass: a value that
      # merely LOOKS like a container is a plain STRING in real
      # ansible-core (live-verified vs ansible-playbook 2.19.11, see
      # apt.cr's parse_package_names), and a whole-value `{{ list_var }}`
      # container arg arrives as the double-quoted JSON the wire
      # serialized it to (see substitute_task_params's whole-single-span
      # comment).
      private def string_list_param(key : String) : Array(String)
        raw = @params[key]?
        return [] of String if raw.nil? || raw.strip.empty?

        parsed = JSON.parse(raw).as_a.map(&.as_s) rescue nil
        return parsed if parsed

        raw.split(",").map(&.strip).reject(&.empty?)
      end
    end
  end
end
