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
    # Returns nil when nothing in the output matches any known failure
    # line (repo-metadata/404 class errors), so the caller can keep its
    # pre-existing raw-output failure shape instead of guessing.
    module DnfInstallFailures
      # Ansible's module failure key order for a transaction that failed
      # to install some of the requested packages - no stderr key.
      DNF_INSTALL_FAILURE_ORDER = %w[msg failures results rc failed]

      def parse_dnf_install_failures(stdout : String, stderr : String) : Array(String)?
        failures = [] of String
        add = ->(entry : String) { failures << entry unless failures.includes?(entry) }

        # dnf reports the per-argument lines on stdout and the summary
        # "Error:" line on stderr (matching error_lines' stderr-first
        # read order for the fallback path).
        stderr.each_line do |line|
          parse_line(line.strip, add)
        end
        stdout.each_line do |line|
          parse_line(line.strip, add)
        end

        failures.empty? ? nil : failures
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
          # yielding one entry per spec (deduped by the caller).
          m[1].split(/\s+/).each { |spec| add.call("No package #{spec} available.") }
        end
      end
    end
  end
end
