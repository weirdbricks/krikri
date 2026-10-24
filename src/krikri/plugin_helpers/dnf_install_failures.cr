require "json"

module Krikri
  module PluginHelpers
    # Shared parser for dnf/yum (dnf4-backend) install-failure output,
    # turning the CLI's own stderr/stdout text into Ansible's dnf-module
    # `failures` list (observed live on Rocky, dnf 2.19 backend):
    #
    #   "Error: Unable to find a match: redhat-lsb-core"  and
    #   "No match for argument: redhat-lsb-core"          become
    #     "No package redhat-lsb-core available."
    #
    #   "All matches were filtered out by modular filtering for
    #    argument: mysql-devel"                            becomes
    #     "mysql-devel All matches were filtered out by modular
    #      filtering for argument: mysql-devel"
    #
    # (Ansible prefixes the modular-filtering line with the spec; a
    # missing-spec entry is its own canned wording, not the dnf line.)
    #
    # Ansible emits one failures entry PER REQUESTED SPEC, in request
    # order, duplicates kept (observed live: cloud3rsio.phpbuild lists
    # libmcrypt-devel twice and real Ansible reported 11 entries where
    # krikri reported 10) - dnf itself only prints each missing spec
    # once, so when the caller passes `requested` the parsed entries are
    # re-expanded against that list. Without `requested` the parsed
    # entries are returned deduped, as callers that can't supply the
    # request list have always seen.
    #
    # Returns nil when nothing in the output matches any known failure
    # line (repo-metadata/404 class errors), so the caller can keep its
    # pre-existing raw-output failure shape instead of guessing.
    module DnfInstallFailures
      # Ansible's module failure key order for a transaction that failed
      # to install some of the requested packages - no stderr key.
      DNF_INSTALL_FAILURE_ORDER = %w[msg failures results rc failed]

      # Ansible's observed depsolve-failure key order (live on Rocky,
      # dnf4 backend): alphabetical - changed, failures, msg, rc,
      # results - with no stderr key, and the controller-appended
      # `failed` trailing like every other registered order.
      DNF_DEPSOLVE_FAILURE_ORDER = %w[changed failures msg rc results failed]

      # Ansible's observed repo-metadata-failure key order (live on
      # Rocky, dnf4 backend): alphabetical - changed, msg, rc, results -
      # with neither a stderr key NOR a `failures` key (the module's
      # metadata-download except block does a bare fail_json(msg=, rc=1)
      # - a metadata failure carries no per-spec failure list), the
      # controller-appended `failed` trailing like every other
      # registered order (issue #267).
      DNF_METADATA_FAILURE_ORDER = %w[changed msg rc results failed]

      def parse_dnf_install_failures(stdout : String, stderr : String, requested : Array(String)? = nil) : Array(String)?
        # dnf reports the same missing spec on both stderr and stdout
        # (per-argument line + summary line), so parsing itself still
        # dedupes; re-expansion against `requested` happens afterwards.
        parsed = [] of String
        add = ->(entry : String) { parsed << entry unless parsed.includes?(entry) }

        # dnf reports the per-argument lines on stdout and the summary
        # "Error:" line on stderr (matching error_lines' stderr-first
        # read order for the fallback path).
        stderr.each_line do |line|
          parse_line(line.strip, add)
        end
        stdout.each_line do |line|
          parse_line(line.strip, add)
        end

        return nil if parsed.empty?

        if req = requested
          # Ansible's failures array is one entry per requested spec, in
          # request order, duplicates kept - not one entry per dnf output
          # line, which dnf emits deduped.
          failures = [] of String
          req.each do |spec|
            entry = "No package #{spec} available."
            failures << entry if parsed.includes?(entry)
          end
          # Parsed entries with no requested counterpart (e.g. the
          # modular-filtering wording) trail in parse order.
          parsed.each { |entry| failures << entry unless failures.includes?(entry) }
          failures
        else
          parsed
        end
      end

      # Ansible's dnf module catches the libdnf DepsolveError and fails with
      # "Depsolve Error occurred: " + str(exception), which is the whole
      # "Problem: ..." block (every "- ..." detail line) and not the CLI's
      # trailing "(try to add '--allowerasing' ...)" hint (issue #60).
      def depsolve_failure_msg(output : String) : String?
        lines = output.lines.map(&.rstrip)
        start = lines.index { |line| line.lstrip.starts_with?("Problem") && line.includes?(":") }
        return nil unless start
        block = [] of String
        lines[start..].each do |line|
          # The compound `dnf ... || yum ...` prints a second "Error:" block
          # when the hint line is missing from one copy; ansible never sees it.
          break if line.lstrip.starts_with?("(try to add") || line.starts_with?("Error") || line.strip.empty?
          block << line
        end
        "Depsolve Error occurred: \n" + block.join("\n")
      end

      # Issue #321 (Rocky 9): ansible's dnf module marks every requested
      # spec the repos can't name into `failures` FIRST, then STILL
      # depsolves the survivors - a DepsolveError there (libcurl against
      # the installed libcurl-minimal) fails the task with the depsolve
      # msg AND that per-spec failures list, while the CLI aborts at the
      # missing spec before ever reaching that depsolve. Only THIS exact
      # canned wording names a spec worth re-trying without: the
      # modular-filtering form carries its own different verdict, so
      # those specs stay in the batch.
      def missing_specs_from_failures(failures : Array(String)) : Array(String)
        specs = [] of String
        failures.each do |entry|
          if m = entry.match(/^No package (.+) available\.$/)
            specs << m[1] unless specs.includes?(m[1])
          end
        end
        specs
      end

      # The batch that still depsolves what ansible depsolved: the
      # requested specs minus the ones the repos can't name, so a
      # --assumeno re-run can surface the Problem block the first
      # missing-spec abort hid.
      def specs_without_missing(specs : Array(String), failures : Array(String)) : Array(String)
        missing = missing_specs_from_failures(failures)
        return specs if missing.empty?
        specs.reject { |spec| spec.in?(missing) }
      end

      # Ansible's dnf module reports a repo-metadata download failure
      # (the repo's repodata/repomd.xml 404s) as JUST libdnf's own error
      # text - its "Failed to download metadata for repo 'x': ..."
      # summary line with dnf's "Error: " prefix stripped (issue #267)
      # - and NOT the per-spec failures shape above: a metadata failure
      # carries no failures list at all. The compound `dnf ... || yum
      # ...` prints the line once per package-manager binary (yum's
      # retry replays the identical failure against the same dead
      # repo), so only the first hit - the task's own dnf attempt - is
      # what ansible's msg holds.
      def repo_metadata_failure_msg(output : String) : String?
        lines = output.lines.map(&.rstrip)
        return nil unless line = lines.find { |candidate| candidate.includes?("Failed to download metadata for repo") }
        stripped = line.strip
        stripped = stripped[7..] if stripped.starts_with?("Error: ")
        stripped.strip
      end

      private def parse_line(stripped : String, add : Proc(String, Nil)) : Nil
        return if stripped.empty?
        if m = stripped.match(/All matches were filtered out by modular filtering for argument: (.+)\z/)
          add.call("#{m[1]} #{stripped}")
        elsif m = stripped.match(/No match for argument: (.+)\z/)
          add.call("No package #{m[1]} available.")
        elsif m = stripped.match(/Error: Unable to find a match: (.+)\z/)
          # dnf4 space-joins the unresolved specs in its summary line
          # ("Error: Unable to find a match: foo bar"), while the
          # per-argument "No match for argument:" lines above already
          # carry each spec verbatim; the split keeps both shapes
          # yielding one entry per spec (re-expanded per requested
          # occurrence by the caller when it can supply the list).
          m[1].split(/\s+/).each { |spec| add.call("No package #{spec} available.") }
        end
      end
    end
  end
end
