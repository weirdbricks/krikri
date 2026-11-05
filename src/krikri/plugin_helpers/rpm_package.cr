require "json"
require "uri"
require "./dnf_install_failures"
require "./http_download"
require "./fetch_tempfile"
require "./multiext_split"
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
      # The dnf-module failure wording/key order for a failed install
      # batch comes from the shared DnfInstallFailures parser
      # (plugin_helpers/dnf_install_failures.cr) - plugins/package.cr's
      # own dnf/yum shell-out needs the identical shape and can't include
      # this module (it also serves apt).
      include DnfInstallFailures
      # ----- shared execution path (moved verbatim from yum.cr, whose
      # install path was the more-refactored of the two; dnf.cr now
      # delegates to the same methods instead of carrying an older,
      # drifted copy) -----

      private alias BatchOutcome = NamedTuple(changed: Bool, message: String?, output: String, failure: PluginResult?)

      # ------------------------------------------------------------------
      # ansible-core 2.19.11 registered-result shapes for the
      # dnf-family backends (each observed through `{{ r | to_json }}` on
      # a registered task - fedora:41 container for dnf5, Rocky Linux 9
      # for dnf, one FRESH host per engine so both engines saw identical
      # host state):
      #
      #   The `dnf:` ACTION plugin dispatches on the host's pkg_mgr fact
      #   (or an explicit use_backend), so the SAME task registers a
      #   DIFFERENT key order per backend:
      #   - dnf4 (Rocky 9, `dnf.py`): the module's own `response` dict,
      #     initialized msg/changed/results/rc and exited via
      #     exit_json(**response): msg, changed, results, rc, failed -
      #     msg "Nothing to do" on a no-op, "" on a real transaction,
      #     results holding "Installed: <nevra>" / "Removed: <nevra>"
      #     entries.
      #   - dnf5 (Fedora 41, `dnf5.py`): a literal
      #     exit_json(results=, changed=, msg=, rc=) call, so THAT path
      #     keeps the kwargs order: results, changed, msg, rc, failed.
      #   update_cache only is a literal exit_json(msg=, changed=,
      #   results=, rc=) call on BOTH backends, so that path keeps the
      #   module's kwargs order: msg, changed, results, rc, failed - msg
      #   "Cache updated".
      #   `list:` (list_items' exit_json(msg="", results=results); dnf5
      #   adds rc=0): msg, results[, rc], with `changed` backfilled by
      #   the CONTROLLER after `failed`.
      #   failure (failure_response = msg/failures/results/rc): msg,
      #   failures, results, rc, failed.
      #
      # `ansible_facts` and `warnings` also appear in Ansible's registered
      # result (the interpreter-discovery warning and the fact the
      # controller merges in) but have no krikri equivalent - same as
      # every other plugin pinned in this sweep.
      DNF_TRANSACTION_ORDER  = %w[msg changed results rc failed]
      DNF5_TRANSACTION_ORDER = %w[results changed msg rc failed]
      DNF_CACHE_ORDER        = %w[msg changed results rc failed]
      # `list:` - Ansible's exit_json(msg="", results=results) carries no
      # `changed`, so the CONTROLLER backfills it after `failed`; dnf4
      # passes no rc at all, dnf5 passes rc=0 (both observed live, in
      # this order, on their respective hosts).
      DNF4_LIST_ORDER   = %w[msg results]
      DNF5_LIST_ORDER   = %w[msg results rc]
      DNF_FAILURE_ORDER = %w[msg failures results rc failed]

      # The transaction success key order an includer emits - dnf4/yum
      # (the response-dict order) by default, dnf5's kwargs order where
      # the backend resolves to dnf5 (plugins/dnf5.cr always;
      # plugins/dnf.cr when the host's pkg_mgr resolves there).
      private def transaction_key_order : Array(String)
        DNF_TRANSACTION_ORDER
      end

      # The key order an includer uses for a `list:` query result - dnf's
      # own list_items() passes no rc, dnf5's does.
      private def list_result_key_order : Array(String)
        DNF4_LIST_ORDER
      end

      # The msg Ansible reports for a cache-only refresh. dnf and dnf5 both
      # use "Cache updated" (their own run() early-exit).
      private def cache_updated_msg : String
        "Cache updated"
      end

      # Ansible's `results` entries are built from the RPM database, not
      # from the requested spec: "Installed: sl-5.02-22.fc41.x86_64".
      # Ask rpm for the installed NEVRA of `pkg` (name-version-release
      # .arch, epoch omitted when zero) and fall back to the requested
      # spec for anything rpm cannot name (a group, a URL/local RPM, a
      # virtual provide) - a stable, deterministic string either way.
      private def rpm_nevra(pkg : String) : String
        # A downloaded remote RPM is staged to a local file (see handle_install),
        # which the RPM database does not know by path: `rpm -q <path>` falls
        # back to the path and leaks the temp name into "Installed:". Ansible's
        # remote-rpm results name the package from the file's own header, so
        # query the file with `rpm -qp` instead.
        query = pkg.starts_with?("/") && pkg.ends_with?(".rpm") ? "rpm -qp" : "rpm -q"
        result = remote_exec_tolerating_unknown_repo(
          "#{query} --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' #{quote_package(pkg)}"
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
          key_order: transaction_key_order
        )
      end

      # Real's `dnf:` ACTION plugin fetches the pkg_mgr fact on demand for a
      # fact-less host (gather_facts: false) and puts it on the RESULT, so
      # the registered task carries `ansible_facts: {pkg_mgr: <backend>}` -
      # issue #844's registered `r` had exactly that, and a task that only
      # checks `r.results | length > 0` is unaffected by it but any
      # `r.ansible_facts.pkg_mgr` reference is. A task that pinned the
      # backend itself (use_backend:) never runs that fetch in real, and a
      # module result that ships its own ansible_facts (interpreter
      # discovery) replaces the action plugin's on the wire, so neither
      # surfaces here.
      #
      # A FAILED module result must not carry the fetched fact at all
      # (issue #894): the module's own failure payload - which in real
      # carries either the interpreter-discovery fact or nothing once
      # discovery has already run - replaces whatever the action attached,
      # so real's failed results never show pkg_mgr (live-verified vs
      # 2.15.13 on Rocky 9: the failed "Unsupported parameters" result
      # shows {"discovered_interpreter_python": ...} or no ansible_facts
      # key at all). The backend-resolution tuple failure keeps its own
      # ansible_facts - real's action-level fatal carries it (#768).
      def finalize_result(result : PluginResult) : PluginResult
        return result if result.failed?
        return result unless backend_resolved_from_facts? && pkg_mgr_fact_fetched?
        return result if result.extra.has_key?("ansible_facts")
        result.extra["ansible_facts"] = JSON::Any.new({"pkg_mgr" => JSON::Any.new(pkg_mgr_fact)})
        if order = result.key_order
          result.key_order = ["ansible_facts"] + order
        end
        result
      end

      # Ansible's dnf ACTION plugin only consults the pkg_mgr fact for the
      # auto/yum backends; an explicit yum4/dnf4/dnf5 skips its setup call.
      private def backend_resolved_from_facts? : Bool
        (@params["use_backend"]? || "auto").in?("auto", "yum")
      end

      # True when pkg_mgr_fact came from a probe on the target, i.e. the
      # fetch real's action plugin would have performed.
      def pkg_mgr_fact_fetched? : Bool
        pkg_mgr_fact
        !@pkg_mgr_fact_from_vars
      end

      # Real's dnf.py appends "Installed <filename>" for EVERY file/URL spec
      # right after _install_remote_rpms, before the transaction's own
      # "Installed: <nevra>" entries, and on its no-op path too - so an
      # already-installed local rpm under --check still reports
      # results: ["Installed <path>"] (issue #844). Failures return before
      # that append in real.
      private def with_installed_filename_results(result : PluginResult, names : Array(String)) : PluginResult
        return result if result.failed?
        filenames = names.select { |name| name.strip.ends_with?(".rpm") && !remote_rpm_url?(name) }
        return result if filenames.empty?
        existing = result.extra["results"]?.try(&.as_a?) || [] of JSON::Any
        appended = filenames.map { |name| JSON::Any.new("Installed #{name.strip}") }
        result.extra["results"] = JSON::Any.new(appended + existing)
        result
      end

      # Ansible's check-mode shape: the module runs the SAME transaction
      # planning but stops before touching the host, so it reports what
      # it WOULD have done - `results` naming the RPMs involved and msg
      # "Check mode: No changes made, but would have if not in check
      # mode" (dnf.py) - with the same key order as the real
      # transaction. This engine used to run the transaction for real
      # under --check (installing/removing packages on the target!), and
      # reported the ordinary transaction msg on top of that.
      private def check_mode? : Bool
        true?(@params["_ansible_check_mode"]?)
      end

      private def check_mode_msg : String
        "Check mode: No changes made, but would have if not in check mode"
      end

      # The NEVRA the backend WOULD settle on for `pkg`, without
      # installing it: the installed one when the package is already
      # there, otherwise the newest row `dnf list --available` reports.
      private def candidate_nevra(pkg : String) : String
        return rpm_nevra(pkg) if package_installed?(pkg)
        listed = remote_exec("#{pkg_manager_binary} list --available #{quote_package(pkg)}")
        row = parse_dnf_list_output(listed[:stdout]).first?
        row && row["nevra"].as_s? ? row["nevra"].as_s : pkg
      end

      # An rpm FILE (a fetched URL or a local path) whose own NEVRA is
      # already installed is a NO-OP, not an install: real feeds the file
      # to base.package_install and dnf resolves an identical installed
      # package to an empty transaction - "Nothing to do", changed: false,
      # in check mode too (issue #781: real ansible --check said ok where
      # this engine classified the file as "would install" and said
      # changed). Plain `rpm -q <path>` cannot do this lookup: rpm answers
      # a path argument straight from the file's own header (rc 0 whether
      # installed or not), so read the header with -qp first and look the
      # NEVRA up in the database. A header-read failure (unreadable or
      # corrupt file) keeps the install classification - the batch's own
      # failure shapes carry the module's error text.
      private def rpm_file_already_installed?(pkg : String) : Bool
        # A file:// URL is dnf's own local-path spelling (real fetch_file
        # copies it) - rpm wants the bare path.
        path = pkg.strip.lchop("file://")
        header = remote_exec("rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' #{shell_single_quote(path)} 2>/dev/null")
        nevra = header[:stdout].strip
        return false if header[:exit_code] != 0 || nevra.empty?
        remote_exec("rpm -q #{shell_single_quote(nevra)} 2>/dev/null")[:exit_code] == 0
      end

      # The check-mode twin of #transaction_result: same keys and order,
      # but the "would have" msg and, crucially, no host mutation.
      private def check_mode_transaction_result(changed : Bool, results : Array(String) = [] of String) : PluginResult
        return transaction_result(false) unless changed

        PluginResult.new(
          changed: true,
          failed: false,
          msg: check_mode_msg,
          results: results,
          rc: 0,
          key_order: transaction_key_order
        )
      end

      # Ansible's failure shape: msg, failures, results, rc, failed. The
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

      # Backends the `dnf:` ACTION plugin can dispatch to (upstream
      # plugins/action/dnf.py's VALID_BACKENDS frozenset). Every `dnf:` task
      # runs through that action plugin, and so does `yum:` - ansible-core
      # 2.19.11's ansible_builtin_runtime.yml redirects yum to the dnf module,
      # whose module file was then dropped entirely (no modules/yum.py in
      # 2.19.11), so yum exists only as this action plugin on modern installs.
      private VALID_ACTION_BACKENDS = {"yum", "yum4", "dnf", "dnf4", "dnf5"}

      # Real's dnf ACTION plugin resolves which backend module to dispatch to
      # from an explicit use_backend, falling back to the host's pkg_mgr fact
      # for auto/yum. The fact comes from the hostvars when it was gathered;
      # on a fact-less host (gather_facts: false) the action plugin fetches it
      # ON DEMAND - `setup` with filter=ansible_pkg_mgr - before deciding
      # (ansible-core 2.19.11's plugins/action/dnf.py). When the resolved
      # value is not a dnf-family backend (pkg_mgr: apt on an Ubuntu 22.04
      # target, round 5310001, kyleabenson.mssql's "Install the EPEL repo
      # rpm" yum: task), it returns a failed result carrying its
      # TWO-ELEMENT tuple msg and never dispatches the module: krikri used
      # to shell the yum binary instead and fail differently ("Failed to
      # install packages", a module-level failure). The tuple words
      # (including the stray `})` inside the second element - upstream
      # source's own typo, live-captured) render as the action-level
      # "Task failed: Action failed: (...)" [ERROR] block via
      # _ansible_error_detail, while the wire msg keeps the tuple's JSON
      # array form and ansible_facts mirrors real's on-result setup refresh.
      private def dnf_backend_resolution_failure : PluginResult?
        backend = @params["use_backend"]? || "auto"
        return nil unless backend.in?("auto", "yum")
        # Real resolves a MISSING pkg_mgr fact on demand here: the action
        # plugin runs `setup` with filter=ansible_pkg_mgr on the target and
        # uses whatever that reports - so a `gather_facts: false` host still
        # gets a pkg_mgr verdict, and on a non-dnf host (Debian's apt) the
        # action fails with the tuple below CARRYING that fact in
        # ansible_facts (issue #768's fact-less kpg chaos runs). A remote
        # module binary cannot invoke setup, but it RUNS ON the target, so
        # pkg_mgr_fact below computes the same pkg_mgr.py collector decision
        # on the machine this plugin executes on.
        fact = pkg_mgr_fact
        return nil if VALID_ACTION_BACKENDS.includes?(fact)
        msg1 = "Could not detect which major revision of dnf is in use, " \
               "which is required to determine module backend."
        msg2 = "You should manually specify use_backend to tell the module " \
               "whether to use the dnf4 or dnf5 backend})"
        PluginResult.new(
          changed: false,
          failed: true,
          native_msg: JSON::Any.new([JSON::Any.new(msg1), JSON::Any.new(msg2)]),
          ansible_facts: JSON::Any.new({"pkg_mgr" => JSON::Any.new(fact)}),
          _ansible_action_level: true,
          _ansible_error_detail: "Action failed: ('#{msg1}', '#{msg2}')"
        )
      end

      # The pkg_mgr fact the backend resolution dispatches on: the gathered
      # `ansible_pkg_mgr` when the play collected facts, otherwise the
      # on-demand value real's action plugin fetches with its `setup` call.
      # A remote module binary cannot run setup, but it RUNS ON the target,
      # so the detection below reproduces pkg_mgr.py's collector decision
      # directly. Memoized per plugin process - one task, one probe round
      # trip, shared by the failure verdict above and dnf.cr's dnf5-vs-dnf4
      # backend pick (so a fact-less dnf5 host keeps the dnf5 result shapes
      # the old symlink probe produced).
      @pkg_mgr_fact : String? = nil
      @pkg_mgr_fact_from_vars = false

      protected def pkg_mgr_fact : String
        @pkg_mgr_fact ||= begin
          fact = @vars["ansible_pkg_mgr"]?.try(&.as_s?)
          if fact.nil? || fact.empty? || fact == "auto"
            detect_pkg_mgr_fact
          else
            @pkg_mgr_fact_from_vars = true
            fact
          end
        end
      end

      # pkg_mgr.py's PKG_MGRS scan list (absolute paths only, which is why
      # `which`-style probes diverged from the fact elsewhere - see
      # package.cr's own detection note) - LAST existing entry wins, the
      # collector loop keeps overwriting.
      PKG_MGR_SCAN_PATHS = {
        "/usr/bin/rpm-ostree"    => "atomic_container",
        "/usr/bin/yum"           => "dnf",
        "/usr/bin/dnf-3"         => "dnf",
        "/usr/bin/dnf5"          => "dnf5",
        "/usr/bin/apt-get"       => "apt",
        "/usr/bin/zypper"        => "zypper",
        "/usr/sbin/urpmi"        => "urpmi",
        "/usr/bin/pacman"        => "pacman",
        "/bin/opkg"              => "opkg",
        "/usr/pkg/bin/pkgin"     => "pkgin",
        "/opt/local/bin/pkgin"   => "pkgin",
        "/opt/tools/bin/pkgin"   => "pkgin",
        "/opt/local/bin/port"    => "macports",
        "/usr/local/bin/brew"    => "homebrew",
        "/opt/homebrew/bin/brew" => "homebrew",
        "/sbin/apk"              => "apk",
        "/usr/sbin/pkg"          => "pkgng",
        "/usr/sbin/swlist"       => "swdepot",
        "/usr/bin/emerge"        => "portage",
        "/usr/sbin/pkgadd"       => "svr4pkg",
        "/usr/bin/pkg"           => "pkg5",
        "/usr/bin/xbps-install"  => "xbps",
        "/usr/local/sbin/pkg"    => "pkgng",
        "/usr/bin/swupd"         => "swupd",
        "/usr/sbin/sorcery"      => "sorcery",
        "/usr/bin/installp"      => "installp",
      }

      # os-release IDs Ansible's distribution facts map to the Debian family
      # (the only family whose pkg_mgr override the dnf action's fetch can
      # hit in practice, besides RedHat's own _check_rh_versions below).
      DEBIAN_FAMILY_IDS = {"debian", "ubuntu", "linuxmint", "kali", "devuan",
                           "raspbian", "pop", "deepin", "uos", "parrot",
                           "elementary", "zorin", "neon", "mx", "antix"}

      REDHAT_FAMILY_IDS = {"rhel", "centos", "rocky", "almalinux", "ol",
                           "fedora", "amzn", "openEuler", "alinux",
                           "tencentos", "cloudlinux", "virtuozzo", "rosa"}

      private def detect_pkg_mgr_fact : String
        result = remote_exec(<<-SH)
          if [ -e /run/ostree-booted ]; then
            echo "fact:atomic_container"
          elif [ -e /usr/bin/dnf ] || [ -e /usr/bin/microdnf ]; then
            if [ -e /usr/bin/dnf ]; then bin=/usr/bin/dnf; else bin=/usr/bin/microdnf; fi
            if [ "$(readlink -f "$bin")" = "/usr/bin/dnf5" ]; then echo "fact:dnf5"; else echo "fact:dnf"; fi
          else
            echo "fact:probe"
            . /etc/os-release 2>/dev/null
            echo "id:${ID:-}"
            echo "like:${ID_LIKE:-}"
            for p in #{PKG_MGR_SCAN_PATHS.keys.join(" ")}; do
              [ -e "$p" ] && echo "path:$p"
            done
            if [ -e /usr/bin/rpm ] && rpm -q --whatprovides /usr/bin/apt-get >/dev/null 2>&1; then
              echo "apt_rpm"
            fi
          fi
          SH
        parse_pkg_mgr_probe(result[:stdout].to_s)
      rescue ex : SpawnError
        # #704: a spawn failure must not read as "not dnf5" and silently
        # pick the wrong package-manager backend - re-raise.
        raise ex
      rescue
        "unknown"
      end

      private def parse_pkg_mgr_probe(output : String) : String
        fact_line = output.lines.map(&.strip).find { |line| line.starts_with?("fact:") }
        return "unknown" unless fact_line
        fact = fact_line.lchop("fact:")
        return fact unless fact == "probe"

        id = ""
        id_like = ""
        paths = [] of String
        apt_rpm = false
        output.each_line do |line|
          line = line.strip
          when_id = line.lchop("id:")
          if when_id != line
            id = when_id
            next
          end
          when_like = line.lchop("like:")
          if when_like != line
            id_like = when_like
            next
          end
          when_path = line.lchop("path:")
          if when_path != line
            paths << when_path
            next
          end
          apt_rpm = true if line == "apt_rpm"
        end

        # The family overrides, in pkg_mgr.py collect()'s order: RedHat's
        # _check_rh_versions only ever reads the dnf/microdnf symlinks (the
        # branches above), so a RedHat-family host without either reports
        # "unknown" even when /usr/bin/yum exists; Debian forces "apt"
        # regardless of what the scan found (upgraded to apt_rpm only when
        # rpm itself owns /usr/bin/apt-get); Altlinux turns its apt into
        # apt_rpm. Everything else keeps the scan's last-match value.
        return "unknown" if redhat_family?(id, id_like)
        if debian_family?(id, id_like)
          return apt_rpm ? "apt_rpm" : "apt"
        end
        return "apt_rpm" if altlinux_family?(id, id_like) && paths.includes?("/usr/bin/apt-get")

        name = "unknown"
        PKG_MGR_SCAN_PATHS.each do |path, mgr|
          name = mgr if paths.includes?(path)
        end
        name
      end

      private def debian_family?(id : String, id_like : String) : Bool
        return true if DEBIAN_FAMILY_IDS.includes?(id)
        id_like.split(/[ ,]+/).includes?("debian")
      end

      private def redhat_family?(id : String, id_like : String) : Bool
        return true if REDHAT_FAMILY_IDS.includes?(id)
        like = id_like.split(/[ ,]+/)
        like.includes?("rhel") || like.includes?("fedora") || like.includes?("centos")
      end

      private def altlinux_family?(id : String, id_like : String) : Bool
        id == "altlinux" || id_like.split(/[ ,]+/).includes?("altlinux")
      end

      # Ansible's dnf module surfaces libdnf's own repo error text
      # ("Failed to download metadata for repo ...") as the msg, without
      # the CLI's "Error: " prefix or a "Failed to update package cache:" wrapper.
      private def cache_failure_msg(stderr : String) : String
        if idx = stderr.index("Failed to download metadata for repo")
          return stderr[idx..].lines.first.strip
        end
        "Failed to update package cache: #{stderr}"
      end

      # dnf.py's transaction tail (the big try wrapping resolve(),
      # download_packages() and the rpm transaction) ends in a generic
      # handler: any dnf.exceptions.Error that is neither a DepsolveError
      # nor a DownloadError becomes msg "Unknown Error occurred: {e}" with
      # failure_response's otherwise-empty failures/results. The one that
      # reaches it in practice is download-time cache verification under
      # cacheonly: base.download_packages() first verifies every
      # transaction package against its cached copy, and a cache missing
      # (or corrupting) an rpm raises a PLAIN dnf.exceptions.Error - not a
      # DownloadError - so the dedicated "Failed to download packages"
      # catch never sees it and it lands in the generic handler
      # (dnf/base.py _select_remote_pkgs). failure_response only ever
      # collects missing-spec entries during install marking, so
      # `failures` stays empty, and `results` stays empty even though
      # resolve() had already succeeded (results go to the success
      # response, never to failure_response). The CLI prints the same
      # error as log lines - the "Package ... has incorrect checksum"
      # criticals and a final "Error: ..." - which are never module JSON,
      # so shelling the CLI must repack the failure into the module's
      # shape instead of dumping the raw lines (issue #769).
      private CACHEONLY_INVALID_CACHE_TEXT = "Some packages have invalid cache, but cannot be downloaded due to \"--cacheonly\" option"

      private def unknown_error_failure(result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult?
        combined = result[:stdout] + "\n" + result[:stderr]
        idx = combined.index(CACHEONLY_INVALID_CACHE_TEXT) || return nil
        line = combined[idx..].lines.first.strip
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unknown Error occurred: #{line}",
          include_empty_msg: true,
          failures: [] of String,
          results: [] of String,
          rc: result[:exit_code],
          key_order: DNF_FAILURE_ORDER
        )
      end

      private def early_result_for_empty_names(names : Array(String)) : PluginResult?
        return nil unless names.empty?

        if true?(@params["update_cache"]?)
          result = remote_exec("#{pkg_manager_binary} makecache")
          # changed: false even on success - same fix as dnf.cr's
          # identical branch (see its own comment): ansible-core's
          # dnf/yum module never reports changed for a cache-only
          # refresh. Found via round172's buluma.rpmfusion.
          # A failed refresh is ansible's fail_json from the libdnf
          # metadata error: rc 1 and the changed/msg/rc/results shape,
          # not the success shape's rc 0 (issue #301).
          if result[:exit_code] != 0
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: cache_failure_msg(result[:stderr]),
              include_empty_msg: true,
              results: [] of String,
              rc: 1,
              key_order: PluginHelpers::DnfInstallFailures::DNF_METADATA_FAILURE_ORDER
            )
          end
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: cache_updated_msg,
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
        # exactly as "nothing to install" as no name: at all, and
        # ansible-core's yum/dnf module reports ok/changed: false for it,
        # not a missing-parameter failure - found via trombik.redhat_repo's
        # "Install extra packages" task (round 601447), which failed here
        # outright while ansible-playbook reported ok. Mirrors
        # apt.cr's identical fix for the same bug class (round 84000).
        if @params["name"]? || @params["pkg"]?
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Nothing to do",
            include_empty_msg: true,
            results: [] of String,
            rc: 0,
            key_order: transaction_key_order
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

      # yumdnf_argument_spec's mutually_exclusive groups (ansible/module_utils/
      # yumdnf.py), shared by dnf, dnf5 and yum. AnsibleModule validates
      # mutually_exclusive groups right after the unsupported-parameter check
      # and BEFORE defaults are applied and type conversion runs
      # (module_utils/common/arg_spec.py: check_mutually_exclusive sits ahead
      # of _set_defaults and _validate_argument_types), so a collision needs
      # both keys EXPLICITLY passed - the `name: []` and `update_cache: False`
      # defaults do not count, which is also why the spec's required_one_of
      # (name, list, update_cache) can never fire. Presence is key presence
      # only: `best: false` + `nobest: false`, `list: ""` and even
      # `list: null` all collide (all live-verified against ansible-core
      # 2.19.11), and the `pkg` alias counts as `name`. Every colliding
      # group is reported in one message, groups joined by ", ", members by
      # "|": "parameters are mutually exclusive: name|list, best|nobest".
      private def yumdnf_mutual_exclusion_rejection : PluginResult?
        groups = [["name", "list"], ["best", "nobest"]]
        collisions = groups.select do |group|
          group.count { |key| @params.has_key?(key) || (key == "name" && @params.has_key?("pkg")) } > 1
        end
        return nil if collisions.empty?

        PluginResult.new(
          changed: false,
          failed: true,
          msg: "parameters are mutually exclusive: #{collisions.map { |group| group.join("|") }.join(", ")}"
        )
      end

      # yumdnf.py's YumDnf.__init__ sanity check, which runs after the whole
      # argument-spec validation (choices included) and before any module
      # body (the dnf5 backend's libdnf5 import probe included): an omitted
      # state defaults to "absent" when autoremove is set, and an explicit
      # state other than the literal "absent" fails - the "removed" alias
      # does NOT satisfy it because the check compares the raw parameter.
      # The fail_json carries an empty `results` list (yumdnf.py), so a
      # registered result has it between the fail_json kwargs and the
      # controller's changed: `results, failed, msg, changed`
      # (live-verified vs ansible-core 2.14.18 in a Rocky 9 container; the
      # check lives in the shared module_utils, so dnf and dnf5 fail alike).
      private def yumdnf_autoremove_rejection : PluginResult?
        return nil unless true?(@params["autoremove"]?)
        state = @params["state"]?
        return nil if state.nil? || state == "absent"

        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Autoremove should be used alone or with state=absent",
          results: [] of String,
          key_order: ["results", "failed", "msg", "changed"]
        )
      end

      # The request as written, before parse_package_names dedupes it.
      @requested_names : Array(String)? = nil

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

        # The install/remove commands take the deduped list, but the install
        # failure's `failures` entries follow the request as written - Ansible
        # reports one "No package X available." per requested spec, duplicates
        # kept (see DnfInstallFailures#parse_dnf_install_failures).
        @requested_names = names
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
      # Ansible.builtin.dnf/yum treat a scalar `list:` value as a
      # QUERY, never as packages to act on: `dnf: {list: updates}`
      # lists available updates and returns {"changed": false,
      # "results": [...]} where each result carries name/arch/epoch/
      # version/release/repo (+ nevra/envra). This plugin family
      # previously concatenated a scalar `list:` into the package
      # names (parse_package_names' rescue), so `dnf: {list: updates}`
      # ran `dnf install updates` and failed with "Error: Unable to
      # find a match: updates" where Ansible succeeded - found
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
        # list", where the equivalent FLAG form works. Ansible's dnf module
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
        when "installed"           then "--installed"
        when "available"           then "--available"
        when "updates", "upgrades" then "--upgrades"
        when "extras"              then "--extras"
        when "obsoletes"           then "--obsoletes"
        end
      end

      # Parses `dnf list <spec>` / `yum list <spec>` output into result
      # dicts shaped like Ansible's own dnf module list results:
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

          # Ansible's own per-package dict (dnf.py's _package_dict,
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
        # rendered output) is a plain STRING in ansible-core -
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

      # A name containing '://' is a remote RPM: ansible's dnf module
      # downloads it itself (dnf.py _parse_spec_group_file calls fetch_file
      # for every such name) before any transaction runs, so a failed fetch
      # surfaces as urllib-shaped "Failure downloading <url>, <msg>" with
      # the module's own msg-only result. Staging the file here hands dnf
      # the local path, as ansible does, instead of letting dnf's libdnf/curl
      # stack fetch the URL and fail with its own wording.
      private def handle_install(names : Array(String), options : String) : PluginResult
        with_staged_remote_rpms(names) do |local_names|
          with_installed_filename_results(handle_install_local(local_names, options), local_names)
        end
      end

      # Remote RPM staging shared by every install-shaped path: real's
      # dnf/yum module fetches an http(s) name itself (fetch_file) before
      # the transaction, regardless of state, so `state: latest` must
      # stage too - otherwise dnf's own curl stack reaches the URL and
      # reports its libdnf wording (issue #876).
      private def with_staged_remote_rpms(names : Array(String), &) : PluginResult
        staged = [] of String
        begin
          local_names = [] of String
          names.each do |name|
            unless remote_rpm_url?(name)
              local_names << name
              next
            end
            begin
              local_names << stage_remote_rpm(name.strip, staged)
            rescue ex
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failure downloading #{name}, #{remote_rpm_failure_detail(ex)}"
              )
            end
          end
          yield local_names
        ensure
          # Ansible deletes its fetched temp via add_cleanup_file at module
          # exit, so the staged RPM lives for the whole install and is only
          # removed here, after the transaction result is built.
          staged.each { |path| File.delete(path) rescue nil }
        end
      end

      private def remote_rpm_url?(name : String) : Bool
        stripped = name.strip
        stripped.starts_with?("http://") || stripped.starts_with?("https://") || stripped.starts_with?("ftp://")
      end

      # Fetch a remote RPM through the same HTTPDownload helper unarchive and
      # the apt deb: path use. The `.rpm` suffix matters: the local-file
      # branches of handle_install_local key off the name ending in `.rpm`.
      #
      # The staged name follows ansible's fetch_file
      # (module_utils/urls.py): prefix/suffix from
      # _split_multiext(basename(url), count=2) around an 8-character
      # random middle (tempfile.NamedTemporaryFile). The basename is what
      # dnf echoes back - issue #818's GPG failure surfaced ansible's
      # "Public key for epel-release-latest-9.noarch<rand8>.rpm" against
      # krikri's opaque ".krikri-playbook-rpm-<rand8>.rpm".
      private def stage_remote_rpm(url : String, staged : Array(String)) : String
        stem, ext = PluginHelpers::MultiextSplit.split(File.basename(URI.parse(url).path))
        path = PluginHelpers::FetchTempfile.create(stem, ext)
        staged << path
        PluginHelpers::HTTPDownload.download(url, path, remote_rpm_download_options)
        path
      end

      # ansible's fetch_url defaults (15s connect / 30s read, 5 redirects,
      # the ansible-httpget User-Agent), as in apt_deb_install.cr and unarchive.cr.
      # The proxy settings come from remote_rpm_proxy_env: fetch_url's
      # download goes through urllib's default ProxyHandler, which routes
      # through the module process's http_proxy/https_proxy env vars - the
      # env Ansible populates from the task's environment: keyword. Without
      # them a URL reachable only via a proxy fails the way issue #754 saw:
      # krikri downloads direct and dies on the origin's own error while
      # ansible fails (or succeeds) on the proxy's.
      private def remote_rpm_download_options : PluginHelpers::HTTPDownload::Options
        PluginHelpers::HTTPDownload::Options.new(
          connect_timeout: 15.seconds,
          read_timeout: 30.seconds,
          max_redirects: 5,
          headers: HTTP::Headers{"User-Agent" => "ansible-httpget"},
          http_proxy: remote_rpm_proxy_env("http_proxy"),
          https_proxy: remote_rpm_proxy_env("https_proxy"),
          no_proxy: remote_rpm_proxy_env("no_proxy"),
        )
      end

      # The module process's env as urllib's getproxies_environment sees
      # it: the ambient env, with the task's environment: overlay merged
      # on top (Ansible applies the overlay to the module process; the
      # overlay wins). Krikri's plugin process does not receive the
      # overlay in its own env (see LocalPluginDaemon's doc comment), so
      # it is read explicitly and layered over ENV. urllib lower-cases
      # every env name ending in _proxy, so the upper-case spellings count
      # on posix too.
      private def remote_rpm_proxy_env(key : String) : String?
        overlay = remote_rpm_env_overlay
        overlay[key]? || overlay[key.upcase]? || ENV[key]? || ENV[key.upcase]?
      end

      # The task's environment: overlay as a plain hash (empty when the
      # task set none or the blob is malformed - only specific keys are
      # read, so no key validation, unlike BasePlugin#task_environment).
      private def remote_rpm_env_overlay : Hash(String, String)
        raw = @params["_environment"]?
        return {} of String => String unless raw
        Hash(String, String).from_json(raw)
      rescue
        {} of String => String
      end

      # fetch_file interpolates fetch_url's info['msg'] verbatim, which is the
      # text HTTPDownload carries for UrlError, ConnectionFailure and HttpError.
      # A ContentCopy failure has no info['msg'] (fetch_url already returned),
      # so the exception's own reason is the closest honest detail.
      private def remote_rpm_failure_detail(ex : Exception) : String
        if ex.is_a?(PluginHelpers::HTTPDownload::FetchError)
          case ex.kind
          when .url_error?, .connection_failure?, .http_error?
            return ex.info_msg
          when .content_copy?
            return ex.reason unless ex.reason.empty?
          end
        end
        ex.message || ex.class.name
      end

      private def handle_install_local(names : Array(String), options : String) : PluginResult
        # Check if update_only is set
        update_only = true?(@params["update_only"]?)

        # A name ending .rpm (or a fetched URL) is a LOCAL RPM FILE: real's
        # dnf.py routes those through _install_remote_rpms
        # (base.add_remote_rpms), whose except wraps ANY failure -
        # including dnf's own "Could not open: <path>" for a file that
        # isn't there - as "Error occurred attempting remote rpm operation:
        # <e>" with results=[] and rc=1, NOT the failures-list shape
        # (robertdebock.atom, round 5410000; dnf.py:801/854-863). The
        # readability pre-check reproduces the witnessed shape.
        if rpm_file = names.find { |name| name.strip.ends_with?(".rpm") && !name.strip.starts_with?("http") && !File.exists?(name.strip.lchop("file://")) }
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Error occurred attempting remote rpm operation: Could not open: #{rpm_file.strip}",
            include_empty_msg: true,
            results: [] of String,
            rc: 1,
            key_order: %w[changed msg rc failed]
          )
        end

        classified = classify_install_packages(names, update_only)
        to_install = classified[:to_install]
        to_update = classified[:to_update]

        # --check: report what the transaction WOULD have done without
        # running it (Ansible's module resolves the goal, then stops).
        if check_mode?
          pending = to_install + to_update
          return transaction_result(false) if pending.empty?
          return check_mode_transaction_result(true, pending.map { |pkg| "Installed: #{candidate_nevra(pkg)}" })
        end

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

        # Ansible's no-op path reports NOTHING about the packages that were
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
            # An rpm file already installed at the very NEVRA its header
            # carries resolves to dnf's empty transaction (see
            # rpm_file_already_installed?) - but that empty transaction
            # still has to RUN through dnf in a real run: ansible's module
            # feeds the file to base.package_install unconditionally, and
            # dnf loads every enabled repo's metadata before resolving, so
            # a repo whose repodata fails to download fails the task even
            # though the file itself is a no-op (issue #813:
            # ahu-services.postgresql, pgdg-common repomd 404 - real
            # ansible fatal'd, this engine said ok). Only check mode
            # classifies it out: real --check reports the empty
            # transaction as ok (issue #781), and this engine has no repo
            # state to model a metadata failure inside its would-be plan.
            if rpm_file_already_installed?(pkg) && check_mode?
              already_installed << pkg
            else
              # For URLs/files, always try to install
              to_install << pkg
            end
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

        # Nothing to do - Ansible's no-op shape (results [], msg "Nothing to
        # do", rc 0), which says nothing about which packages were already
        # absent.
        if to_remove.empty?
          # With `autoremove: true` Ansible still runs the autoremove
          # transaction when every named package is already absent, so
          # leftover unneeded dependencies make the task `changed`
          # (antmelekhin.docker's cold run on Rocky).
          return handle_autoremove if true?(@params["autoremove"]?) && !check_mode?
          return transaction_result(false)
        end

        # Ansible's `results` entries name the RPM that was removed, so the
        # NEVRA has to be read BEFORE the transaction erases it.
        nevras = {} of String => String
        to_remove.each { |pkg| nevras[pkg] = rpm_nevra(pkg) }

        if check_mode?
          return check_mode_transaction_result(true, to_remove.map { |pkg| "Removed: #{nevras[pkg]? || pkg}" })
        end

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
            key_order: transaction_key_order
          )
        else
          failure_result(
            "Failed to remove packages",
            error_lines(result),
            result[:exit_code] == 0 ? 1 : result[:exit_code]
          )
        end
      end

      # Ansible's dnf/yum module `state: latest` installs a not-yet-
      # installed package (there is nothing to "update" yet) and upgrades
      # one that's already present - it never runs a bare `dnf/yum update
      # <name>` unconditionally, which fails outright ("No match for
      # argument", "No packages marked for upgrade") for any name not
      # already installed. Found via alvistack.openjdk (RHEL-family round
      # 60420): `dnf: {name: temurin-21-jdk, state: latest}` on a fresh
      # host installed fine under ansible-playbook but failed here.
      # Reuses the same classify/batch helpers `handle_install` already
      # gets right, just routing "not installed" to an install batch
      # instead of `already_installed`.
      private def handle_update(names : Array(String), options : String) : PluginResult
        with_staged_remote_rpms(names) do |local_names|
          handle_update_staged(local_names, options)
        end
      end

      private def handle_update_staged(names : Array(String), options : String) : PluginResult
        to_install = [] of String
        to_update = [] of String

        names.each do |pkg|
          if package_group?(pkg)
            to_install << pkg
          elsif url_or_file?(pkg)
            # `latest` is "same as installed" for filenames in real's dnf.py:
            # the identical already-installed NEVRA still resolves to dnf's
            # empty transaction - but like the present path above, that
            # empty transaction still has to run through dnf in a real
            # run, where a failing repo-metadata download fails the task
            # instead of reading as a no-op ok (issue #813). Check mode
            # keeps the no-op classification (issue #781).
            unless rpm_file_already_installed?(pkg) && check_mode?
              to_install << pkg
            end
          elsif package_installed?(pkg)
            to_update << pkg
          else
            to_install << pkg
          end
        end

        if check_mode?
          pending = to_install + to_update
          return with_installed_filename_results(transaction_result(false), names) if pending.empty?
          return with_installed_filename_results(check_mode_transaction_result(true, pending.map { |pkg| "Installed: #{candidate_nevra(pkg)}" }), names)
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

        # `state: latest` on an already-latest host is Ansible's ordinary
        # no-op (results [], msg "Nothing to do") - not a "Packages
        # already at latest version" summary of this engine's own making.
        with_installed_filename_results(transaction_result(changed, installed), names)
      end

      private def run_install_batch(to_install : Array(String), options : String) : BatchOutcome
        pkg_list = to_install.map { |pth| quote_package(pth) }.join(" ")
        cmd = "#{pkg_manager_binary} install #{options} #{pkg_list}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        if result[:exit_code] != 0
          # Ansible's dnf module reports a partially-unresolvable install
          # batch with its own canned msg ("Failed to install some of the
          # specified packages") and one "No package X available." entry
          # per requested spec (duplicates kept - dnf itself prints each
          # missing spec once) parsed out of dnf's output - NOT the
          # raw dnf stderr/stdout dump the fallback below keeps for
          # outputs nothing in parses (repo metadata/404-class errors).
          # Ansible's dnf fails the GPG check via a bare fail_json(msg=...)
          # with no rc/failures/results keys, unlike its depsolve failure
          # which does carry all three plus the failure key order its
          # module dict gets there (issue #216).
          if gpg_msg = gpg_validation_failure_msg(result[:stdout] + "\n" + result[:stderr])
            return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(changed: false, failed: true, msg: gpg_msg)}
          end
          if depsolve_msg = depsolve_failure_msg(result[:stdout] + "\n" + result[:stderr])
            return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(changed: false, failed: true, msg: depsolve_msg, failures: [] of String, results: [] of String, rc: result[:exit_code], key_order: PluginHelpers::DnfInstallFailures::DNF_DEPSOLVE_FAILURE_ORDER)}
          end
          # A repo-metadata download failure (the repo's repomd.xml
          # 404s) matches none of the parse lines and used to reach the
          # error-lines dump below; ansible's module reports just
          # libdnf's "Failed to download metadata for repo ..." text
          # with neither a stderr nor a failures key (issue #267).
          if metadata_msg = repo_metadata_failure_msg(result[:stdout] + "\n" + result[:stderr])
            return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(changed: false, failed: true, msg: metadata_msg, results: [] of String, rc: result[:exit_code], key_order: PluginHelpers::DnfInstallFailures::DNF_METADATA_FAILURE_ORDER)}
          end
          if failures = parse_dnf_install_failures(result[:stdout], result[:stderr], @requested_names)
            # Ansible's module marks the missing specs into `failures`
            # first and then STILL depsolves the survivors (issue #321)
            # - a DepsolveError raised there beats the canned
            # install-failure msg for that task. The CLI's own
            # missing-spec abort hides that verdict, so the retry below
            # goes and re-resolves without the specs it can't name.
            if depsolve_failure = depsolve_retry_failure(failures, to_install, options, result)
              return {changed: false, message: nil, output: result[:stdout], failure: depsolve_failure}
            end
            return {changed: false, message: nil, output: result[:stdout], failure: failure_result("Failed to install some of the specified packages", failures, result[:exit_code])}
          end
          if failure = unknown_error_failure(result)
            return {changed: false, message: nil, output: result[:stdout], failure: failure}
          end
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

      # Issue #321 (Rocky 9): ansible's dnf module never stops at the
      # missing-spec mark - every unresolvable spec is checked off into
      # `failures` and the transaction STILL depsolves the survivors, so
      # a DepsolveError in them (libcurl against the installed
      # libcurl-minimal) fails the task with the depsolve msg
      # "Depsolve Error occurred: \n Problem: ..." AND the per-spec
      # failures list, not the canned install-failure msg. The CLI
      # aborts at the missing spec before ever depsolving, so the
      # Problem block is hunted out with one re-install of the
      # remaining specs: --assumeno (no package can land, the
      # re-resolution still prints the block) - --setopt=strict=0 /
      # --skip-broken would suppress it, which is exactly what
      # ansible's depsolve catch reports as the msg. nil keeps the
      # caller's canned install-failure shape - nothing was stripped,
      # nothing remains, or the survivors re-resolve clean.
      private def depsolve_retry_failure(failures : Array(String), to_install : Array(String), options : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult?
        remaining = specs_without_missing(to_install, failures)
        return nil if remaining.empty? || remaining.size == to_install.size
        retry_list = remaining.map { |pth| quote_package(pth) }.join(" ")
        retry_result = remote_exec_tolerating_unknown_repo(
          "#{pkg_manager_binary} install #{options} --assumeno #{retry_list}"
        )
        depsolve_msg = depsolve_failure_msg(retry_result[:stdout] + "\n" + retry_result[:stderr]) || return nil
        PluginResult.new(
          changed: false,
          failed: true,
          msg: depsolve_msg,
          failures: failures,
          results: [] of String,
          rc: result[:exit_code],
          key_order: PluginHelpers::DnfInstallFailures::DNF_DEPSOLVE_FAILURE_ORDER
        )
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
      # reported changed: false under ansible-playbook (whose module
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
          # A repo-metadata download failure reaches the update batch the
          # same way it reaches the install one (issue #857:
          # tvandeveire.ekstack_metricbeat_packetbeat's `state: latest` on
          # an already-installed jre): ansible's module loads every
          # enabled repo's metadata before resolving either transaction,
          # so its fatal carries just libdnf's "Failed to download
          # metadata for repo ..." text with no failures key - the same
          # shape run_install_batch already reports for this (issue #267).
          if metadata_msg = repo_metadata_failure_msg(result[:stdout] + "\n" + result[:stderr])
            return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(changed: false, failed: true, msg: metadata_msg, results: [] of String, rc: result[:exit_code], key_order: PluginHelpers::DnfInstallFailures::DNF_METADATA_FAILURE_ORDER)}
          end
          if failure = unknown_error_failure(result)
            return {changed: false, message: nil, output: result[:stdout], failure: failure}
          end
          return {changed: false, message: nil, output: result[:stdout], failure: failure_result("Failed to update packages", error_lines(result), result[:exit_code])}
        end

        # Check if anything was actually updated
        if result[:stdout].includes?("Upgraded:") || result[:stdout].includes?("Installed:")
          {changed: true, message: "Updated: #{to_update.join(", ")}", output: result[:stdout], failure: nil}
        else
          {changed: false, message: nil, output: result[:stdout], failure: nil}
        end
      end

      # Ansible's failure shape carries the backend's own error lines in
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
      # an EMPTY results list instead of the package Ansible's own
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
          name.starts_with?("file://") ||
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

        # But never let a Provides: hit stand in for a name the repos
        # carry themselves: Ansible's dnf module hands `name:` to
        # python-dnf untouched, which resolves it to the repo package
        # of that exact name - a depsolve-level fatal on Rocky 9, where
        # `dnf: name: curl` on a host whose curl-minimal Provides:
        # "curl" fails the task (curl conflicts with curl-minimal;
        # zorlin.rust round round29879595, issue #280), not the
        # already-installed no-op this fallback used to answer. Asking
        # dnf/yum for the name itself separates those: a package of
        # this exact name is available -> report not-installed so the
        # install batch runs (and dnf reports its own failure through
        # the already-shaped depsolve/no-match paths); a purely
        # virtual name like RHEL 9's `php-json` has no repo row,
        # this listing fails (like every other error: no binary, dead
        # repos), and the `--whatprovides` fallback below keeps those.
        available = remote_exec("#{pkg_manager_binary} -q list --available #{shell_single_quote(base_name)} 2>/dev/null")
        return false if available[:exit_code] == 0

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
          # Ansible's autoremove has no prose summary of its own: it goes
          # through the very same transaction result as any other dnf
          # call, so a removal reports its `results` entries and a no-op
          # reports "Nothing to do".
          transaction_result(changed, autoremove_results(result[:stdout]))
        else
          failure_result("Autoremove failed", error_lines(result), result[:exit_code])
        end
      end

      # The packages an autoremove/upgrade transaction reported removing,
      # in Ansible's `results` spelling. The dnf transaction summary lists
      # them as "Removed:  <name>-<version>-<release>.<arch>", which is
      # already exactly the string Ansible's results array carries.
      private def autoremove_results(output : String) : Array(String)
        output.each_line.map(&.strip).select { |line| line.starts_with?("Removed:") }.map { |line| line.sub(/^Removed:\s*/, "") }.reject(&.empty?).to_a
      end

      private def handle_upgrade_all : PluginResult
        # ansible's dnf.py resolves `name: '*'` + `state: latest` via a bare
        # base.upgrade_all() on the Python API, whose Base() never reads
        # /etc/dnf/dnf.conf, so conf.best is False whatever `nobest` says
        # (the `conf.best = not self.nobest` forcing is per-package-spec
        # only). With best unset, conflicting updates are silently dropped
        # and the task succeeds; the CLI would pick up Rocky's dnf.conf
        # best=True and die with a Depsolve Error (issue #299).
        options = build_dnf_options(force_nobest: true)
        cmd = "#{pkg_manager_binary} upgrade #{options}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          changed = result[:stdout].includes?("Upgraded:") ||
                    result[:stdout].includes?("Installed:")
          transaction_result(changed, upgrade_results(result[:stdout]))
        else
          # Same dnf.exceptions.Error wrap as the install/update batches
          # above: cacheonly's download-time cache verification failure is
          # the generic "Unknown Error occurred" shape, not the raw dump.
          unknown_error_failure(result) ||
            failure_result("Failed to upgrade system", error_lines(result), result[:exit_code])
        end
      end

      # The packages an upgrade transaction touched, in Ansible's `results`
      # spelling - the transaction summary's own "Upgraded:" /
      # "Installed:" lines, which are already the exact strings real
      # puts in that array.
      private def upgrade_results(output : String) : Array(String)
        output.each_line.map(&.strip).select { |line| line.starts_with?("Upgraded:") || line.starts_with?("Installed:") }.reject(&.empty?).to_a
      end

      private def build_dnf_options(force_nobest : Bool = false) : String
        options = [] of String

        # Always use -y for non-interactive
        options << "-y"

        # Enable/disable repos - a blank entry (e.g. `enablerepo: "{{ some_var
        # | default('') }}"` resolving empty) is Ansible's own no-op,
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

        # GPG check - Ansible's dnf module explicitly sets BOTH
        # conf.gpgcheck AND conf.localpkg_gpgcheck to `not disable_gpg_check`
        # (verified in ansible-core's own dnf.py: "conf.localpkg_gpgcheck =
        # not disable_gpg_check"), overriding dnf's own actual default for
        # local/URL package installs, which is gpgcheck-OFF regardless of
        # the repo gpgcheck=1 setting in dnf.conf. Plain `--nogpgcheck` only
        # covers the repo-package path; without also forcing
        # `--setopt=localpkg_gpgcheck=1` here, a `name: https://.../foo.rpm`
        # install silently skipped signature verification (inherited dnf's
        # own default), diverging from ansible-playbook which
        # correctly refuses an RPM whose signing key isn't imported. Found
        # benchmarking geerlingguy.selenium's "Install Chrome (if
        # configured, RedHat)" task (direct google-chrome-stable RPM URL,
        # no imported key) - Ansible failed with "Failed to validate
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

        # Best/nobest. ansible-core's dnf module exposes only `nobest` in
        # the shared yumdnf argument spec - there is no `best:` parameter
        # (one was invented here briefly and had to go, Ansible rejects
        # it as an unsupported parameter) - and its best handling is
        # asymmetric: _configure_base only drives conf.best down (an
        # explicit nobest: true gives `conf.best = 0`), while the
        # per-package-spec branch forces `conf.best = not self.nobest`
        # explicitly so a named install/upgrade never runs best-less. So
        # on these paths an explicit nobest: false means "resolve with
        # best", which the CLI already spells --best (dnf's own built-in
        # default when dnf.conf leaves it alone) - kept for the not-given
        # case too - and nobest: true maps to --nobest. The one dnf.py
        # goal with no forcing at all, the bare upgrade_all, is pinned
        # --nobest through force_nobest instead (see handle_upgrade_all
        # for why no nobest value ever turns that path back to --best).
        if force_nobest
          options << "--nobest"
        elsif nobest = @params["nobest"]?
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
        # though ansible-core implements allow_downgrade in module
        # logic, not via this flag.)
        if true?(@params["allowerasing"]?)
          options << "--allowerasing"
        end

        # Run entirely from the local cache - no metadata download/update
        # (dnf's -C/--cacheonly; ansible-core sets conf.cacheonly,
        # dnf.py _configure_base).
        if true?(@params["cacheonly"]?)
          options << "--cacheonly"
        end

        # Alternate dnf.conf path (dnf's -c/--config). ansible-core
        # points conf.config_file_path at it and fails when unreadable
        # (dnf.py _configure_base); the CLI pass-through relies on dnf's
        # own equivalent read failure.
        if conf_file = @params["conf_file"]?
          options << "--config=#{shell_single_quote(conf_file)}" unless conf_file.strip.empty?
        end

        # Disable dnf.conf excludes entirely ("all"), just [main]'s
        # ("main"), or one repo's ("<repoid>") for this transaction (dnf's
        # --disableexcludes; ansible-core appends to
        # conf.disable_excludes, dnf.py _configure_base).
        if disable_excludes = @params["disable_excludes"]?
          options << "--disableexcludes=#{disable_excludes}" unless disable_excludes.strip.empty?
        end

        # Per-transaction plugin enable/disable (dnf's
        # --enableplugin/--disableplugin). ansible-core passes these
        # sets to base.init_plugins (dnf.py _base) - never persisted
        # beyond the transaction, exactly like the CLI flags.
        string_list_param("enable_plugin").each do |plugin|
          options << "--enableplugin=#{plugin}"
        end

        string_list_param("disable_plugin").each do |plugin|
          options << "--disableplugin=#{plugin}"
        end

        # Package name(s) to exclude from present/latest operations (dnf's
        # --exclude; ansible-core appends to conf.exclude, dnf.py
        # _configure_base - a list or comma-separated string, listified
        # exactly like enablerepo/disablerepo already are above). Quoted
        # so a glob like `kernel*` reaches dnf without the target shell
        # expanding it.
        string_list_param("exclude").each do |pkg|
          options << "--exclude=#{shell_single_quote(pkg)}"
        end

        # Alternate install root, relative to which all packages install
        # (dnf's --installroot; ansible-core sets conf.installroot,
        # dnf.py _configure_base, defaulting to "/"). "/" is dnf's own
        # default, so it isn't emitted.
        if installroot = @params["installroot"]?
          options << "--installroot=#{shell_single_quote(installroot)}" unless installroot.strip.empty? || installroot == "/"
        end

        # Install packages as if running a different OS release version
        # (dnf's --releasever; ansible-core overrides
        # conf.substitutions['releasever'], dnf.py _configure_base).
        if releasever = @params["releasever"]?
          options << "--releasever=#{shell_single_quote(releasever)}" unless releasever.strip.empty?
        end

        # Disable SSL validation of the repo servers for this transaction
        # (dnf's sslverify conf option via --setopt; ansible-core sets
        # conf.sslverify = sslverify, dnf.py _configure_base, default
        # true). Only the false case needs a flag - true is dnf's default.
        if false?(@params["sslverify"]?)
          options << "--setopt=sslverify=False"
        end

        # Download packages without installing (dnf's --downloadonly;
        # ansible-core sets conf.downloadonly, dnf.py _configure_base).
        if true?(@params["download_only"]?)
          options << "--downloadonly"
        end

        # Alternate package-download directory - only meaningful with
        # download_only, exactly as in ansible-core (conf.destdir is
        # only set when download_only is set, dnf.py _configure_base).
        if true?(@params["download_only"]?) && (download_dir = @params["download_dir"]?)
          options << "--downloaddir=#{shell_single_quote(download_dir)}" unless download_dir.strip.empty?
        end

        options.join(" ")
      end

      # List-typed params (`exclude:`, `enable_plugin:`, `disable_plugin:`)
      # arrive either as a JSON array string (the PluginManager serializes
      # list params with JSON's own .to_s) or as the comma-separated string
      # Ansible's yumdnf.listify_comma_sep_strings_in_list still
      # accepts for these same options ("It's possible someone passed a
      # comma separated string since it used to be a string type"). ONLY
      # valid JSON, though - never a Python-repr repair pass: a value that
      # merely LOOKS like a container is a plain STRING in
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
