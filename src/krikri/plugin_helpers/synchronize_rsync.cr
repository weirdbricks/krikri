require "json"
require "process"

module Krikri
  # The rsync-invocation core of ansible.posix.synchronize, shared by both
  # entry points that need it:
  #
  #   - SynchronizeActionPlugin (controller-side action plugin - the normal
  #     task-execution path; see its own file for why synchronize is
  #     controller-side here, same as real Ansible)
  #   - plugins/synchronize.cr (the standalone/fat plugin binary, kept for
  #     `--async`/manual invocation on whatever host the "local" rsync end
  #     is - same split as debug/pause)
  #
  # Ported from real ansible.posix's plugins/modules/synchronize.py (the
  # module half; the action-plugin half only munges src/dest into remote
  # `user@host:path` form and resolves the private key/port before handing
  # over). Argument order, flag spelling, and the itemize-changes protocol
  # all follow that source verbatim:
  #
  #   - every flag rsync gets is the real module's own (including the
  #     non-obvious ones: --delete-after for delete:, --delay-updates -F
  #     by default, --archive plus explicit --no-X for each toggle that
  #     was EXPLICITLY turned off under a default-on archive:)
  #   - changed detection is rsync's own: the command always runs with
  #     `--out-format=<<CHANGED>>%i %n%L`, so every item rsync actually
  #     created/updated/attribute-changed/deleted gets a `<<CHANGED>>`-
  #     prefixed itemize line and an untouched tree prints nothing at
  #     all - "any marker line => changed" is exactly real Ansible's own
  #     `changed = changed_marker in out` test (with the documented
  #     link_dest exception, where a leading `.` itemize char means
  #     "hard-linked, no change")
  module SynchronizeRsync
    CHANGED_MARKER = "<<CHANGED>>"

    struct RsyncResult
      property rc : Int32
      property output : String
      property error : String
      property command : Array(String)

      def initialize(@rc : Int32, @output : String, @error : String, @command : Array(String))
      end
    end

    # Builds the full rsync argv for one synchronize invocation. *src* and
    # *dest* must already be FINAL (the caller munged remote ends into
    # user@host:path form first); everything else is read from *params*
    # with the real module's own defaults. *private_key*/*dest_port* are
    # the caller-resolved connection values (param override, then
    # inventory vars) that feed the `--rsh=` ssh command when either path
    # is remote (contains ':').
    def self.build_argv(src : String, dest : String, params : Hash(String, String),
                        private_key : String? = nil, dest_port : Int32? = nil) : Array(String)
      argv = ["rsync"]

      # delay_updates defaults true, compress defaults true (real module
      # argument_spec), both explicit-false suppressible.
      argv << "--delay-updates" << "-F" if bool(params["delay_updates"]?, default: true)
      argv << "--compress" if bool(params["compress"]?, default: true)
      argv << "--timeout=#{params["rsync_timeout"]}" if int?(params["rsync_timeout"]?)
      argv << "--delete-after" if bool(params["delete"]?)
      argv << "--existing" if bool(params["existing_only"]?)
      argv << "--checksum" if bool(params["checksum"]?)
      argv << "--copy-links" if bool(params["copy_links"]?)

      archive = bool(params["archive"]?, default: true)
      if archive
        argv << "--archive"
        # Each toggle defaults to archive's value; only an EXPLICIT false
        # cancels its half of --archive (real module: --no-recursive etc.
        # under the archive branch) - absent means "follow archive", so
        # the tri-state bool_opt (nil for absent) is load-bearing here.
        argv << "--no-recursive" if bool_opt(params["recursive"]?) == false
        argv << "--no-links" if bool_opt(params["links"]?) == false
        argv << "--no-perms" if bool_opt(params["perms"]?) == false
        argv << "--no-times" if bool_opt(params["times"]?) == false
        argv << "--no-owner" if bool_opt(params["owner"]?) == false
        argv << "--no-group" if bool_opt(params["group"]?) == false
      else
        argv << "--recursive" if bool_opt(params["recursive"]?) == true
        argv << "--links" if bool_opt(params["links"]?) == true
        argv << "--perms" if bool_opt(params["perms"]?) == true
        argv << "--times" if bool_opt(params["times"]?) == true
        argv << "--owner" if bool_opt(params["owner"]?) == true
        argv << "--group" if bool_opt(params["group"]?) == true
      end
      argv << "--dirs" if bool(params["dirs"]?)

      link_dest = parse_list(params["link_dest"]?)

      if needs_rsh?(src, dest)
        has_rsh_opt = parse_list(params["rsync_opts"]?).any?(&.includes?("--rsh"))
        # Real module: `ssh -S none` (no multiplexing by default), the
        # private key, the port, and - unless verify_host: - the same
        # no-host-key-check pair its own non-interactive runs use.
        unless has_rsh_opt
          ssh_cmd = "ssh -S none"
          ssh_cmd += " -i #{private_key}" if private_key
          ssh_cmd += " -o Port=#{dest_port}" if dest_port
          unless bool(params["verify_host"]?)
            ssh_cmd += " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
          end
          argv << "--rsh=#{ssh_cmd}"
        end
      end

      argv << "--rsync-path=#{params["rsync_path"]}" if params["rsync_path"]? && !params["rsync_path"].empty?
      argv.concat(parse_list(params["rsync_opts"]?))
      argv << "--partial" if bool(params["partial"]?)

      unless link_dest.empty?
        argv << "-H"
        argv << "-vv"
        link_dest.each do |entry|
          argv << "--link-dest=#{File.expand_path(entry)}"
        end
      end

      argv << "--out-format=#{CHANGED_MARKER}%i %n%L"
      argv << src
      argv << dest
      argv
    end

    def self.run(argv : Array(String)) : RsyncResult
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      process = Process.new(argv[0], argv[1..], output: out_io, error: err_io)
      status = process.wait
      RsyncResult.new(
        rc: status.exit_code || 1,
        output: out_io.to_s,
        error: err_io.to_s,
        command: argv
      )
    end

    # True when either final path is an rsync remote spec (`host:path`,
    # `user@host:path`, or rsync:// URL) - the real module's
    # is_rsh_needed. Two plain local paths (the delegate_to: localhost
    # idiom) need no remote shell.
    def self.needs_rsh?(src : String, dest : String) : Bool
      return false if src.starts_with?("rsync://") && dest.starts_with?("rsync://")
      src.includes?(':') || dest.includes?(':')
    end

    # The real module's changed test: any itemize line at all - except the
    # link_dest case, where rsync prints a leading-`.` itemize char for
    # each file it hard-linked WITHOUT changing, and the real module's own
    # test is literally `(changed_marker + '.') not in out`.
    def self.changed?(output : String, link_dest : Bool = false) : Bool
      if link_dest
        !output.includes?("#{CHANGED_MARKER}.")
      else
        output.includes?(CHANGED_MARKER)
      end
    end

    # Strips the markers back off, keeping one itemize line (marker
    # removed) per real change - the real module's msg/stdout_lines/diff
    # payload.
    def self.clean_output(output : String) : String
      output.lines.reject(&.empty?).map do |line|
        line.starts_with?(CHANGED_MARKER) ? line[CHANGED_MARKER.size..] : line
      end.join("\n")
    end

    # _format_rsync_rsh_target - builds `user@host:path` for the remote
    # end, preserving an already-qualified path (user@host:path as written
    # in the task, or an rsync:// URL) untouched. IPv6 hosts get the
    # [user@addr]:path bracket form rsync's ssh transport requires.
    def self.format_rsh_target(host_addr : String, path : String, user : String?) : String
      return path if path.starts_with?("rsync://")

      user_prefix = user ? "#{user}@" : ""
      if host_addr.includes?(':')
        return "[#{user_prefix}#{host_addr}]:#{path}"
      end

      unless path.includes?(':')
        return "#{user_prefix}#{host_addr}:#{path}"
      end

      return "#{user_prefix}#{path}" unless path.includes?('@')
      path
    end

    def self.bool(value : String?, default : Bool = false) : Bool
      return default unless value
      normalized = value.strip.downcase
      return true if ["true", "yes", "on", "1"].includes?(normalized)
      return false if ["false", "no", "off", "0"].includes?(normalized)
      default
    end

    # Tri-state form: nil when the param is absent (the caller decides
    # what "absent" follows - for the archive toggles that's archive's
    # own value, per the real module's type: bool-without-default spec).
    def self.bool_opt(value : String?) : Bool?
      return nil unless value
      normalized = value.strip.downcase
      return true if ["true", "yes", "on", "1"].includes?(normalized)
      return false if ["false", "no", "off", "0"].includes?(normalized)
      nil
    end

    private def self.int?(value : String?) : Bool
      return false unless value
      value.strip =~ /\A[1-9]\d*\z/ ? true : false
    end

    # List-shaped params arrive as strings (the wire format every plugin
    # gets) - either a JSON array or comma-separated. Same defensive
    # re-parse find.cr/apt.cr document (a YAML one-element list otherwise
    # becomes ONE string containing literal brackets/quotes).
    def self.parse_list(value : String?) : Array(String)
      return [] of String unless value
      trimmed = value.strip
      # Tolerate double-encoded JSON (a JSON string wrapping the JSON array
      # - the wire format's to_json applied twice): unwrap and re-parse.
      parsed = begin
        String.from_json(trimmed)
      rescue
        nil
      end
      return parse_list(parsed) if parsed && !parsed.empty?
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        parsed ||= begin
          Array(String).from_json(trimmed.gsub('\'', '"'))
        rescue
          nil
        end
        return parsed.map(&.strip).reject(&.empty?) if parsed
      end
      trimmed.split(",").map(&.strip).reject(&.empty?)
    end
  end
end
