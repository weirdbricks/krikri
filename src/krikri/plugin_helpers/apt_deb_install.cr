module Krikri
  # The `deb:` install machinery of the `apt` module, shared by the
  # `package` module's apt backend (whose `deb:` tasks previously fell
  # through to the empty-name path and silently reported ok without
  # installing anything - rchouinard.mysql-community-repo round 5210000:
  # real installed the mysql-apt-config deb (changed=1), krikri reported
  # ok and the .deb never landed). Extracted verbatim from apt.cr so the
  # two plugins can't drift; requires the including plugin to provide
  # BasePlugin's remote_exec/params/check_mode surface.
  module AptDebInstall
    # Parses the version column (3rd whitespace-separated field) out of
    # a `dpkg -l <pkg> | grep '^ii'` line, e.g. "ii  rabbitmq-server
    # 3.12.2-1  amd64  ...".
    private def installed_version(dpkg_line : String) : String?
      dpkg_line.split(/\s+/)[2]?
    end

    # One `dpkg-query` round trip for the WHOLE package list instead of
    # one `dpkg -l <pkg>` per package (N+1 remote commands on every
    # multi-package apt task). Returns installed-ness, the installed
    # version and the raw Status-Abbrev ("ii" installed, "rc" removed
    # with config files still on disk, ...) per requested base name; a
    # name dpkg has never heard of (never installed) simply has no line.
    # Keys are the bare name with any `:arch` suffix dpkg-query appends
    # for multi-arch packages stripped.
    private def dpkg_installed_status(packages : Array(String)) : Hash(String, {Bool, String?, String})
      statuses = Hash(String, {Bool, String?, String}).new
      return statuses if packages.empty?

      name_list = packages.map { |pkg| shell_single_quote(split_name_version(pkg)[0]) }.join(" ")
      result = remote_exec("dpkg-query -W -f='${db:Status-Abbrev} ${Version} ${Package}
' #{name_list} 2>/dev/null")
      result[:stdout].each_line do |line|
        parts = line.split(/\s+/, 3)
        next unless parts.size == 3
        bare = parts[2].strip.split(":").first
        next if statuses.has_key?(bare)
        installed = parts[0].starts_with?("ii")
        statuses[bare] = {installed, installed ? parts[1] : nil, parts[0]}
      end
      statuses
    end

    # Handle `deb:` - install a local .deb file or a URL (downloaded to a
    # temp path first). Idempotency mirrors Ansible's own apt module:
    # read the package's own name+version out of the .deb's control
    # metadata via `dpkg-deb -f`, and skip the install if that exact
    # name/version is already installed.
    private def handle_deb(deb_source : String, messages : Array(String), changed : Bool, lock_timeout : Int32) : PluginResult
      path = deb_source
      downloaded_tmp : String? = nil

      if deb_source.starts_with?("http://") || deb_source.starts_with?("https://")
        if @check_mode
          messages << "Would download #{deb_source} to a private /tmp staging file"
        else
          # File.tempfile (unguessable name + O_EXCL + 0600), not the
          # URL's own basename: /tmp/<basename> was fully predictable,
          # and curl -o follows a symlink planted there, clobbering an
          # arbitrary file as root.
          # The suffix is not cosmetic: command-line apt-get/dpkg refuse
          # non-.deb files with "E: Unsupported file ... given on
          # commandline" (Ansible's apt module uses python-apt, which
          # never sees the filename, so this only bit us).
          tmp = File.tempfile(".krikri-playbook-deb-", ".deb")
          path = tmp.path
          downloaded_tmp = tmp.path
          tmp.close
          download_result = remote_exec("curl -fsSL -o #{shell_single_quote(path)} #{shell_single_quote(deb_source)}")
          if download_result[:exit_code] != 0
            File.delete(path) rescue nil
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to download #{deb_source}: #{download_result[:stderr]}"
            )
          end
        end
      end

      # Ansible's fetch_file registers the downloaded temp with
      # module.add_cleanup_file, so it lives for the whole module run
      # (the very next thing apt.py does with it is `dpkg-deb -f`) and is
      # removed only at module exit. An ensure-scoped delete around just
      # the download removed the file before that first metadata read,
      # failing every URL deb: with "No such file or directory"
      # (round900223, j91321.sysmon's packages-microsoft-prod.deb task).
      begin
        install_deb_file(path, lock_timeout, messages, changed)
      ensure
        File.delete(downloaded_tmp) if downloaded_tmp
      end
    end

    # The metadata-read + idempotency + install half of #handle_deb,
    # shared by the URL (downloaded temp path) and local-file cases so a
    # local deb: path never gains URL-only behavior.
    private def install_deb_file(path : String, lock_timeout : Int32, messages : Array(String), changed : Bool) : PluginResult
      # python-apt's DebPackage construction is the FIRST thing real
      # install_deb does, and its SystemError text IS the registered
      # failure msg ("Unable to install package: <e>" - round-99500x
      # captures apt_fail_deb_missing/_corrupt/_dir):
      #   - a missing file:  E:Could not open file <path> - open (2: No such file or directory)
      #   - a directory:     E:Read error - read (21: Is a directory)
      #   - a non-archive:   E:Invalid archive signature (the 8-byte ar
      #     magic "!<arch>\n" is the first thing apt_pkg validates)
      unless File.exists?(path)
        return unable_to_install("E:Could not open file #{path} - open (2: No such file or directory)")
      end
      if File.directory?(path)
        return unable_to_install("E:Read error - read (21: Is a directory)")
      end
      magic = Bytes.new(8)
      begin
        File.open(path, "r") { |io| io.read_fully(magic) }
      rescue File::Error
        # an unreadable file lets the metadata read below produce the
        # failure, as before
        magic = "!<arch>\n".to_slice
      end
      unless magic == "!<arch>\n".to_slice
        return unable_to_install("E:Invalid archive signature")
      end

      # Read the .deb's own control metadata: the name/version identity
      # Ansible's apt module checks against dpkg's installed-package
      # database for idempotency, plus the dependency fields real
      # install_deb resolves BEFORE any dpkg run (DebPackage.depends
      # folds Depends AND Pre-Depends; Recommends joins in only when
      # install_recommends is explicitly true) - one dpkg-deb -f call
      # for all of them.
      info_result = remote_exec("dpkg-deb -f #{shell_single_quote(path)} Package Version Pre-Depends Depends Recommends")
      if info_result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read package metadata from #{path}: #{info_result[:stderr]}"
        )
      end

      fields = parse_deb_control_fields(info_result[:stdout])
      pkg_name = fields["Package"]?
      pkg_version = fields["Version"]?

      installed_deb_ver : String? = nil
      if pkg_name && pkg_version
        check_result = remote_exec("dpkg -l #{shell_single_quote(pkg_name)} 2>/dev/null | grep '^ii'")
        if check_result[:exit_code] == 0
          installed_deb_ver = installed_version(check_result[:stdout])
          if installed_deb_ver == pkg_version
            # Real install_deb's already-installed exit: the deps install
            # produced no retvals, so exit_json(changed=False,
            # stdout='', stderr='', diff='') - diff is the EMPTY STRING,
            # not a dict (round-99500x apt_real_deb_again capture), and
            # there is no msg key.
            return PluginResult.new(changed: false, failed: false,
              stdout: "", stderr: "", diff: JSON::Any.new(""),
              key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"])
          end
        end
      end

      # Real install_deb, past the same-version skip, runs pkg.check()
      # before anything is installed. Its version gate fires first: a deb
      # OLDER than the installed version fails with "A later version is
      # already installed" (a plain fail_json(msg=...), the round-1100002
      # apt_fail_deb capture's [failed, msg, changed, exception] shape)
      # unless force: or allow_downgrade: releases it - allow_downgrade
      # by explicitly passing on that one failure string. The comparison
      # goes through dpkg's own Debian-version ordering (not a
      # reimplemented comparator) and only when the name is installed at
      # a DIFFERENT version than the deb carries.
      if installed_deb_ver && pkg_version && installed_deb_ver != pkg_version &&
         !true?(@params["force"]?) && !true?(@params["allow_downgrade"]?) &&
         dpkg_version_compares([{installed_deb_ver.not_nil!, ">", pkg_version.not_nil!}])[0]
        return PluginResult.new(changed: false, failed: true,
          msg: "A later version is already installed")
      end

      # DebPackage.check()'s dependency half, CLI-mirrored: the .deb's
      # own Depends/Pre-Depends are resolved BEFORE the dpkg run - missing
      # dependencies go through the normal install() machinery first,
      # because `dpkg -i` itself cannot resolve dependencies and dies on
      # "dependency problems prevent configuration" (round-1200xxx:
      # appsilon.r_language, JonasPammer/kso512.checkmk_server,
      # Oefenweb.rstudio_server all failed exactly there while real
      # ansible-playbook pre-installed the missing deps and succeeded).
      # The or-group rules mirror python-apt: a group is satisfied when
      # any alternative is installed at a constraint-satisfying version
      # (unversioned deps are satisfied by the bare installed name);
      # otherwise the first alternative apt can actually install wins -
      # unknown names and purely virtual ones ("Candidate: (none)") are
      # skipped the way _satisfy_or_group skips them, and a group with no
      # selectable alternative fails check() with "Dependency is not
      # satisfiable: <or-group>". (python-apt additionally resolves a
      # virtual dep through a lone provider and honors Provides:-based
      # satisfaction for unversioned deps - neither is reachable without
      # an in-process apt cache here; those fall through to apt-get's own
      # handling, which errors where python-apt would have auto-picked.)
      deps_to_install = [] of String
      dep_groups = parse_dep_string(fields["Depends"]?) + parse_dep_string(fields["Pre-Depends"]?)
      unless dep_groups.empty?
        dep_alt_names = Set(String).new
        dep_groups.each do |alternatives|
          alternatives.each { |alternative| dep_alt_names << alternative.name }
        end
        statuses = dpkg_installed_status(dep_alt_names.to_a.map(&.split(":").first))
        # Every version constraint an INSTALLED alternative can answer,
        # in one batched dpkg --compare-versions round trip.
        compare_pairs = [] of {String, String, String}
        sat_pair_group = [] of Int32
        dep_groups.each_with_index do |alternatives, group_idx|
          alternatives.each do |alternative|
            next unless alternative.oper && alternative.version
            st = statuses[alternative.name.split(":").first]?
            next unless st && st[0] && st[1]
            compare_pairs << {st[1].not_nil!, alternative.oper.not_nil!, alternative.version.not_nil!}
            sat_pair_group << group_idx
          end
        end
        sat_answers = dpkg_version_compares(compare_pairs)

        group_satisfied = Array(Bool).new(dep_groups.size, false)
        sat_answers.each_with_index do |satisfied, i|
          group_satisfied[sat_pair_group[i]] = true if satisfied
        end
        unsatisfied = [] of Array(DebDepAlternative)
        dep_groups.each_with_index do |alternatives, group_idx|
          next if group_satisfied[group_idx]
          # an installed alternative with NO version constraint satisfies
          # its group outright (python-apt's unversioned installed check)
          group_satisfied[group_idx] = alternatives.any? do |alternative|
            next false if alternative.oper || alternative.version
            st = statuses[alternative.name.split(":").first]?
            st && st[0]
          end
          unsatisfied << alternatives unless group_satisfied[group_idx]
        end

        # One apt-cache policy round trip per batch for every alternative
        # of the unsatisfied groups (see #apt_candidates_batch).
        unsatisfied_alt_names = Set(String).new
        unsatisfied.each do |alternatives|
          alternatives.each { |alternative| unsatisfied_alt_names << alternative.name }
        end
        candidates = apt_candidates_batch(unsatisfied_alt_names.to_a)

        # python-apt's provider paths for a name the apt cache knows only
        # as virtual (Provides:), e.g. jammy's check-mk-raw Depends:
        # "libffi8ubuntu1" where the archive only has libffi8 (=
        # 3.4.2-4), Provides: libffi8ubuntu1 - round-1300024/1300039
        # checkmk_server failed "Dependency is not satisfiable:
        # libffi8ubuntu1" here while real ansible's DebPackage satisfied
        # the group through the installed provider. showpkg's Reverse
        # Provides section is the only CLI window onto apt_pkg's provider
        # table, so the provider walks batch there. Upstream semantics
        # mirrored: _is_or_group_satisfied treats an INSTALLED provider
        # as satisfying the group outright (ignoring the version
        # constraint - upstream's virtual check never consults it), both
        # for a purely-virtual name and for an unversioned name that is
        # real-but-uninstalled; _satisfy_or_group installs a purely
        # virtual name's EXACTLY ONE provider (constraint checked
        # against that provider's candidate like any other alternative),
        # and skips names with more than one provider (upstream's
        # len(providers) != 1 guard).
        provider_probe_names = Set(String).new
        unsatisfied.each do |alternatives|
          alternatives.each do |alternative|
            res = candidates[alternative.name]?
            next unless res && res[0]
            provider_probe_names << alternative.name if res[1].nil? || !alternative.oper
          end
        end
        providers_map = apt_reverse_provides_batch(provider_probe_names.to_a)
        provider_names = Set(String).new
        providers_map.each_value do |providers|
          providers.each do |provider|
            provider_names << provider.split(":").first
          end
        end
        provider_statuses = provider_names.empty? ? Hash(String, {Bool, String?, String}).new : dpkg_installed_status(provider_names.to_a)
        provider_candidates = provider_names.empty? ? Hash(String, {Bool, String?}).new : apt_candidates_batch(provider_names.to_a)

        res_pairs = [] of {String, String, String}
        res_pair_slot = Hash({Int32, Int32}, Int32).new
        prov_pair_slot = Hash({Int32, Int32}, Int32).new
        unsatisfied.each_with_index do |alternatives, group_idx|
          alternatives.each_with_index do |alternative, alt_idx|
            res = candidates[alternative.name]?
            next unless res && res[0] && res[1]
            next unless alternative.oper && alternative.version
            res_pair_slot[{group_idx, alt_idx}] = res_pairs.size
            res_pairs << {res[1].not_nil!, alternative.oper.not_nil!, alternative.version.not_nil!}
          end
        end
        unsatisfied.each_with_index do |alternatives, group_idx|
          alternatives.each_with_index do |alternative, alt_idx|
            res = candidates[alternative.name]?
            next unless res && res[0] && res[1].nil?
            next unless alternative.oper && alternative.version
            providers = providers_map[alternative.name]?
            next unless providers && providers.size == 1
            provider = providers[0].split(":").first
            next if provider_statuses[provider]?.try(&.[0])
            pres = provider_candidates[provider]?
            next unless pres && pres[0] && pres[1]
            prov_pair_slot[{group_idx, alt_idx}] = res_pairs.size
            res_pairs << {pres[1].not_nil!, alternative.oper.not_nil!, alternative.version.not_nil!}
          end
        end
        res_answers = dpkg_version_compares(res_pairs)

        unsatisfied.each_with_index do |alternatives, group_idx|
          # _is_or_group_satisfied runs before _satisfy_or_group for the
          # WHOLE group, so an installed provider on ANY alternative
          # preempts the install-a-provider walk of an earlier one.
          provider_satisfied = alternatives.any? do |alternative|
            res = candidates[alternative.name]?
            next false unless res && res[0]
            next false unless res[1].nil? || !alternative.oper
            providers = providers_map[alternative.name]?
            providers && providers.any? { |provider| provider_statuses[provider.split(":").first]?.try(&.[0]) }
          end
          next if provider_satisfied
          pick : String? = nil
          alternatives.each_with_index do |alternative, alt_idx|
            res = candidates[alternative.name]?
            next unless res && res[0]
            if res[1]
              if alternative.oper && alternative.version
                if pi = res_pair_slot[{group_idx, alt_idx}]?
                  pick = alternative.name if res_answers[pi]
                end
              else
                pick = alternative.name
              end
            else
              # purely virtual: only a single provider can be picked
              providers = providers_map[alternative.name]?
              next unless providers && providers.size == 1
              provider = providers[0].split(":").first
              pres = provider_candidates[provider]?
              next unless pres && pres[0] && pres[1]
              if alternative.oper && alternative.version
                if pi = prov_pair_slot[{group_idx, alt_idx}]?
                  pick = provider if res_answers[pi]
                end
              else
                pick = provider
              end
            end
            break if pick
          end
          unless pick
            # DebPackage._satisfy_or_group's own failure: the ONLY
            # fail_json check() produces before install() ever runs -
            # the plain [failed, msg, changed, exception] shape, with the
            # msg carrying the trailing "\n" of the gettext string.
            return PluginResult.new(changed: false, failed: true,
              msg: "Dependency is not satisfiable: #{dep_or_str(alternatives)}\n")
          end
          deps_to_install << pick
        end
      end

      # Real install_deb's Recommends handling, verbatim INCLUDING its
      # wart: with install_recommends explicitly true the raw Recommends
      # field is split on WHITESPACE and every token joins the deps list
      # ("a, b (>= 1)" becomes the specs "a," "b" "(>=" "1)") - upstream
      # hands those to install() unfiltered, where a junk token fails
      # "No package matching '(>=' is available" like any other unknown
      # name. An unset install_recommends (None) is falsy upstream and
      # skips the field entirely.
      if true?(@params["install_recommends"]?) && (rec = fields["Recommends"]?)
        deps_to_install.concat(rec.split)
      end

      # The deps install through install()'s own machinery, then - only
      # once it succeeded - the dpkg run, exactly install_deb's sequence.
      # Its failure retvals (msg/stdout/stderr/rc, NO cache keys -
      # install_deb exits before main()'s cache-key append) are re-failed
      # as-is: fail_json(**retvals) captures msg as its named parameter
      # and re-adds it AFTER kwargs, so the registered order is
      # [stdout, stderr, rc, failed, msg, *_lines] - the same kwargs rule
      # that puts msg after failed in the round-99500x
      # apt_fail_install_dpkgopt capture (where main()'s cache keys sit
      # between rc and failed).
      deps_stdout = ""
      deps_stderr = ""
      deps_diff_prepared : String? = nil
      deps_had_retvals = false
      unless deps_to_install.empty?
        deps_result = handle_install(deps_to_install, messages, changed, lock_timeout, deb_deps: true)
        if deps_result.failed?
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: deps_result.msg,
            stdout: deps_result.extra["stdout"]?.try(&.as_s) || "",
            stderr: deps_result.extra["stderr"]?.try(&.as_s) || "",
            rc: deps_result.extra["rc"]?.try(&.as_i) || 1,
            key_order: ["stdout", "stderr", "rc", "failed", "msg", "stdout_lines", "stderr_lines"]
          )
        end
        if deps_result.extra.has_key?("stdout")
          # install() ran apt-get: retvals = {changed, stdout, stderr,
          # diff}. The all-deps-already-installed case produces the bare
          # {changed: False} retvals with no stdout at all, which merges
          # below exactly like an empty retvals dict.
          deps_stdout = deps_result.extra["stdout"].as_s
          deps_stderr = deps_result.extra["stderr"].as_s
          deps_had_retvals = true
          deps_diff_prepared = deps_result.diff.try(&.as_h?).try(&.["prepared"]?).try(&.as_s)
        end
      end

      # Real install_deb's dpkg invocation: `dpkg <options> -i <debs>`
      # with options = the raw dpkg_options: list as --flags, plus
      # --simulate in check mode and --force-all under force:. The exact
      # string is the registered failure msg ("<cmd> failed" - no err
      # text, no quotes, no rc key; round-99500x apt_fail_deb_preinst
      # capture), so it is built verbatim.
      dpkg_flags = (@params["dpkg_options"]? || "force-confdef,force-confold").split(",").map(&.strip).reject(&.empty?)
        .map { |opt| "--#{opt}" }.join(" ")
      dpkg_flags += " --simulate" if @check_mode
      dpkg_flags += " --force-all" if true?(@params["force"]?)
      dpkg_cmd = "dpkg #{dpkg_flags} -i #{path}"

      # Check mode: Ansible still RUNS the command - with --simulate - and
      # registers its output (round-99500x apt_check_deb capture:
      # changed=True, the simulate output as stdout, parse_diff ALWAYS
      # applied here - install_deb has no m._diff guard, unlike
      # install()/remove()).
      deb_result = with_policy_rc_d { apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive dpkg #{dpkg_flags} -i #{shell_single_quote(path)}", lock_timeout, ->remote_exec(String)) }
      if deb_result[:exit_code] == 0 || @check_mode
        unless deb_result[:exit_code] == 0
          # a --simulate run failing is Ansible's same "<cmd> failed" shape
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "#{dpkg_cmd} failed",
            stdout: deps_stdout + deb_result[:stdout],
            stderr: deps_stderr + deb_result[:stderr],
            key_order: ["stdout", "stderr", "failed", "msg", "stdout_lines", "stderr_lines"]
          )
        end
        # Real install_deb's success exit: exit_json(changed=True,
        # stdout=stdout, stderr=stderr, diff=diff) with the deps install's
        # retvals merged in - stdout/stderr CONCATENATED (deps output
        # first), and diff following install_deb's own merge rule: when
        # retvals carried a diff (deps reached apt-get), its `prepared`
        # grows by the dpkg output in diff mode and the diff stays the
        # bare {} retvals carried in non-diff mode; with no deps retvals
        # at all, diff is parse_diff(dpkg out) with NO diff-mode guard.
        if deps_had_retvals
          merged_diff = if prepared = deps_diff_prepared
                          JSON.parse({"prepared" => "#{prepared}\n\n#{deb_result[:stdout]}"}.to_json)
                        else
                          JSON.parse("{}")
                        end
          return PluginResult.new(changed: true, failed: false,
            stdout: deps_stdout + deb_result[:stdout],
            stderr: deps_stderr + deb_result[:stderr],
            diff: merged_diff,
            key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"])
        end
        return PluginResult.new(changed: true, failed: false,
          stdout: deb_result[:stdout],
          stderr: deb_result[:stderr],
          diff: apt_install_diff(deb_result[:stdout]),
          key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"])
      end

      # dpkg failed after the deps install succeeded (or with no deps at
      # all, e.g. a failing preinst script): Ansible's "<cmd> failed"
      # shape over the same merged stdout/stderr.
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "#{dpkg_cmd} failed",
        stdout: deps_stdout + deb_result[:stdout],
        stderr: deps_stderr + deb_result[:stderr],
        key_order: ["stdout", "stderr", "failed", "msg", "stdout_lines", "stderr_lines"]
      )
    end

    # Real install_deb's DebPackage-construction failure: fail_json with
    # the plain kwargs-first shape ([failed, msg, changed, exception]).
    private def unable_to_install(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Unable to install package: #{detail}")
    end

    # Parses the control-field dump `dpkg-deb -f <deb> F1 F2 ...` prints
    # ("Name: value" lines; folded continuation lines start with
    # whitespace and join their field with a single space) into a
    # name->value map. A requested-but-absent field simply has no entry.
    private def parse_deb_control_fields(stdout : String) : Hash(String, String)
      fields = {} of String => String
      current : String? = nil
      stdout.each_line do |line|
        if (line.starts_with?(' ') || line.starts_with?('\t')) && (cur = current)
          fields[cur] = "#{fields[cur]} #{line.strip}"
        elsif (m = line.match(/^([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*(.*)$/))
          current = m[1]
          fields[current.not_nil!] = m[2].strip
        end
      end
      fields
    end

    # One alternative of a dependency or-group: the bare package name
    # (any :arch suffix kept verbatim) plus its optional version
    # constraint operands. Architecture lists and profile restrictions
    # are parsed past and never consulted, matching what this CLI-level
    # mirror can act on.
    private struct DebDepAlternative
      getter name : String
      getter oper : String?
      getter version : String?

      def initialize(@name, @oper, @version)
      end
    end

    # apt_pkg.parse_depends's structure: comma-separated groups, each a
    # '|' list of alternatives, each with an optional "(op version)"
    # constraint. Empty segments drop out (a trailing comma or empty
    # group is not a dependency).
    private def parse_dep_string(value : String?) : Array(Array(DebDepAlternative))
      return [] of Array(DebDepAlternative) unless value
      groups = [] of Array(DebDepAlternative)
      value.split(",").each do |group|
        alts = group.split("|").compact_map do |raw|
          s = raw.strip
          next nil if s.empty?
          name_match = s.match(/^[^\s(\[<]+/)
          next nil unless name_match
          oper : String? = nil
          version : String? = nil
          if cm = s.match(/\((<<|<=|<|>>|>=|>|=)\s+([^)]+)\)/)
            oper = cm[1]
            version = cm[2].strip
          end
          DebDepAlternative.new(name_match[0], oper, version)
        end
        groups << alts unless alts.empty?
      end
      groups
    end

    # DebPackage._satisfy_or_group's failure-string serialization of one
    # or-group: "name" or "name (oper version)", alternatives joined by
    # "|".
    private def dep_or_str(alternatives : Array(DebDepAlternative)) : String
      alternatives.map do |alternative|
        alternative.oper && alternative.version ? "#{alternative.name} (#{alternative.oper} #{alternative.version})" : alternative.name
      end.join("|")
    end

    # One batched `dpkg --compare-versions` round trip for every
    # constraint/version comparison a deb: install needs (dpkg's own
    # Debian version ordering - epoch, tilde, letter-vs-number - is not
    # reimplemented here). Each pair evaluates
    # `dpkg --compare-versions 'a' '<op>' 'b'` and answers on its own
    # "K<n>=Y/N" marker line; a pair whose dpkg invocation errors answers
    # false (the && || chain still emits the marker).
    private def dpkg_version_compares(pairs : Array({String, String, String})) : Array(Bool)
      return [] of Bool if pairs.empty?
      cmd = pairs.map_with_index do |(a, op, b), i|
        "dpkg --compare-versions #{shell_single_quote(a)} #{shell_single_quote(op)} #{shell_single_quote(b)} && echo 'K#{i}=Y' || echo 'K#{i}=N'"
      end.join("; ")
      result = remote_exec(cmd)
      answers = Array(Bool).new(pairs.size, false)
      result[:stdout].each_line do |line|
        if (m = line.match(/^K(\d+)=(Y|N)\s*$/)) && (idx = m[1].to_i) < pairs.size
          answers[idx] = m[2] == "Y"
        end
      end
      answers
    end

    # Batched form of #apt_candidate for the deb: dependency resolution:
    # one apt-cache policy round trip for a whole list of names, with a
    # marker line between probes. Same per-name semantics as its
    # single-name sibling: no stanza at all -> unknown (false, nil),
    # "Candidate: (none)"/empty -> known but purely virtual (true, nil),
    # otherwise (true, candidate version).
    private def apt_candidates_batch(names : Array(String)) : Hash(String, {Bool, String?})
      result = {} of String => {Bool, String?}
      return result if names.empty?
      probes = names.map do |name|
        "echo #{shell_single_quote("==KRIKRI-POLICY== #{name}")}; apt-cache policy #{shell_single_quote(name)} 2>/dev/null"
      end.join("; ")
      probe = remote_exec(probes)
      current : String? = nil
      probe[:stdout].each_line do |line|
        if line.starts_with?("==KRIKRI-POLICY== ")
          current = line.lchop("==KRIKRI-POLICY== ").strip
          result[current] = {false, nil}
        elsif (cur = current) && line.strip.starts_with?("Candidate:")
          version = line.split("Candidate:")[1]?.try(&.strip) || ""
          result[cur] = {true, version.empty? || version == "(none)" ? nil : version}
        end
      end
      result
    end

    # Batched form of python-apt's get_providing_packages, for the deb:
    # dependency provider walks: one `apt-cache showpkg` round trip per
    # batch of names, marker lines between probes. Every "name version
    # (= ver)" entry under a probe's "Reverse Provides:" section yields
    # one provider name (arch-qualified entries collapse to their base
    # name, and duplicates drop out); a probe with no Reverse Provides
    # section, or with none listed, has no providers.
    private def apt_reverse_provides_batch(names : Array(String)) : Hash(String, Array(String))
      result = {} of String => Array(String)
      return result if names.empty?
      probes = names.map do |name|
        "echo #{shell_single_quote("==KRIKRI-PROVIDES== #{name}")}; apt-cache showpkg #{shell_single_quote(name)} 2>/dev/null"
      end.join("; ")
      probe = remote_exec(probes)
      current : String? = nil
      in_reverse = false
      probe[:stdout].each_line do |line|
        if line.starts_with?("==KRIKRI-PROVIDES== ")
          current = line.lchop("==KRIKRI-PROVIDES== ").strip
          result[current] = [] of String
          in_reverse = false
        elsif cur = current
          if line.strip == "Reverse Provides:"
            in_reverse = true
          elsif in_reverse
            if line.strip.empty?
              in_reverse = false
            elsif provider = line.strip.split[0]?
              name = provider.split(":").first
              result[cur] << name unless result[cur].includes?(name)
            end
          end
        end
      end
      result
    end

    private def apt_install_diff(output : String) : JSON::Any
      lines = output.lines
      start = (lines.index("Resolving dependencies...") || lines.index("Reading state information...")).try(&.+(1)) || 0
      stop = (lines.index { |line| line.matches?(/^\d+ (packages )?upgraded/) }).try(&.+(1)) || lines.size
      stop = start if stop < start
      JSON.parse({"prepared" => lines[start...stop].join("\n")}.to_json)
    end

    # The policy-rc.d guard around dpkg/apt runs (prevents service
    # restarts mid-install): param-driven so both including plugins get
    # it - apt.cr's own instance-variable form is equivalent.
    private def with_policy_rc_d(& : -> NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      return yield if (desired_rc = @params["policy_rc_d"]?.try(&.to_i?)).nil?

      path = @params["_policy_rc_d_path"]? || "/usr/sbin/policy-rc.d"
      backup_path = "#{path}.krikri-backup.#{Random.rand(1_000_000)}"
      had_existing = remote_exec("test -e #{shell_single_quote(path)}")[:exit_code] == 0

      if had_existing
        move = remote_exec("mv #{shell_single_quote(path)} #{shell_single_quote(backup_path)}")
        if move[:exit_code] != 0
          return {exit_code: 1, stdout: "", stderr: "Fail to move #{path} to #{backup_path}: #{move[:stderr]}"}
        end
      end

      write = remote_exec("printf '#!/bin/sh\\nexit #{desired_rc}\\n' > #{shell_single_quote(path)} && chmod 0755 #{shell_single_quote(path)}")
      if write[:exit_code] != 0
        restore_policy_rc_d(had_existing, backup_path)
        return {exit_code: 1, stdout: "", stderr: "Failed to create or chmod #{path}: #{write[:stderr]}"}
      end

      @policy_rc_d_restore_failed = false
      inner = begin
        yield
      ensure
        @policy_rc_d_restore_failed = !restore_policy_rc_d(had_existing, backup_path)
      end

      # Restore failure fails the task even when the operation itself
      # succeeded - Ansible's __exit__ fail_json's the same way.
      # When the operation already failed its own error surfaces
      # instead (the task fails either way).
      if @policy_rc_d_restore_failed && inner[:exit_code] == 0
        inner = {exit_code: 1, stdout: inner[:stdout], stderr: "Fail to move back #{backup_path} to #{path} (or remove the temporary policy-rc.d)"}
      end

      inner
    end

    private def restore_policy_rc_d(had_existing : Bool, backup_path : String) : Bool
      if had_existing
        remote_exec("mv #{shell_single_quote(backup_path)} #{shell_single_quote(@params["_policy_rc_d_path"]? || "/usr/sbin/policy-rc.d")}")[:exit_code] == 0
      else
        remote_exec("rm -f #{shell_single_quote(@params["_policy_rc_d_path"]? || "/usr/sbin/policy-rc.d")}")[:exit_code] == 0
      end
    end
    # apt.cr's engine-wide cache-key backfill suppression: a deb: result
    # carries no cache keys on any exit (install_deb exits through its
    # own fail_json/exit_json before main() ever assigns
    # cache_updated/cache_update_time). No-op for backends without the
    # cache-key backfill (package.cr).
    private def deb_suppress_cache_backfill! : Nil
    end
  end
end
