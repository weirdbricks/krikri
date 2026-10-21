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
