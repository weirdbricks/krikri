#!/usr/bin/env crystal

# hostname module (ansible.builtin.hostname) - manages the system hostname.
#
# Sets the hostname persistently. Without `use:`, auto-detects: hostnamectl
# (systemd - the expected mechanism on modern Linux: Ubuntu 16.04+, Debian
# 9+, etc.) with a fallback to /etc/hostname + the hostname(1) command for
# non-systemd systems.
#
# `use:` overrides auto-detection (real Ansible's STRATS dict), mapping to
# the same strategy classes real Ansible uses:
# - systemd/debian -> SystemdStrategy: hostnamectl. Permanent first
#   (`--pretty --static set-hostname`), then transient (`--transient
#   set-hostname`); both reads (`--transient status`/`--static status`)
#   happen even in check mode; a >64-char name fails at the actual set
#   only (check mode reports would-change regardless, live-verified).
#   Unlike the auto-detect path, an explicitly requested systemd strategy
#   FAILS when hostnamectl is absent (real Ansible's get_bin_path,
#   live-verified "Failed to find required executable ..." text) rather
#   than falling back.
# - redhat -> RedHatStrategy: edits only /etc/sysconfig/network's
#   HOSTNAME= line (appends one if absent); no transient hostname, no
#   /etc/hostname, no commands. Fails (even in check mode, even when the
#   name already matches) when the file has no HOSTNAME entry -
#   live-verified "Unable to locate HOSTNAME entry in
#   /etc/sysconfig/network".
# - alpine -> AlpineStrategy: runs `hostname -F /etc/hostname` FIRST (with
#   the file's OLD content - live-verified command order) and only then
#   writes /etc/hostname. Idempotency comes from the file alone.
# - openrc -> OpenRCStrategy: edits /etc/conf.d/hostname's hostname="..."
#   line. A file without a hostname= line crashes real Ansible (its
#   get_permanent_hostname returns None and the diff build raises
#   TypeError, live-verified) - replicated as a failure here. A missing
#   file reads as "" and the write path produces a lone "\n" exactly like
#   real Ansible (live-verified).
# - generic -> fails: real Ansible's Base strategy raises
#   NotImplementedError on every operation (live-verified raw traceback),
#   so there is no working behavior to replicate.
#
# Out of scope (deliberately, this is a Linux-only engine): use: values
# freebsd/macos/macosx/darwin/openbsd/solaris/sles select non-Linux
# platform strategies (the first six genuinely non-Linux; sles targets a
# distro outside krikri's supported set). They are rejected with an
# explicit error rather than silently mis-executed. Note real Ansible
# would actually run them on Linux; that divergence is krikri's
# Linux-only stance, not an oversight.
#
# Idempotent: compares against the current hostname per the selected
# strategy (auto path: System.hostname). Returns ansible_facts
# (ansible_hostname, ansible_nodename, ansible_fqdn, ansible_domain)
# matching real Ansible's convention.
#
# Verified against real ansible-playbook behavior (not ansible-doc alone):
# - Returns ansible_facts at the result top level, not nested under a
#   separate key.
# - ansible_hostname is the short name (first component before '.').
# - ansible_fqdn falls back to the short name if hostname -f fails (returns
#   only "hostname: Name or service not known" stderr exit code 1 on hosts
#   with no FQDN configured), matching the facts module's own behavior.
# - check_mode reports would-change without executing hostnamectl.

require "json"
require "../src/krikri/base_plugin"

module Krikri
  class HostnamePlugin < BasePlugin
    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    # Real Ansible's STRATS dict (ansible/modules/hostname.py), in its own
    # insertion order - used both for choice validation (exact error text)
    # and strategy dispatch.
    private USE_CHOICES = %w[alpine debian freebsd generic macos macosx darwin
      openbsd openrc redhat sles solaris systemd]

    def execute : PluginResult
      # Required param: name (the desired hostname). Real Ansible checks
      # required arguments before choice validation (live-verified:
      # name-less + invalid-use fails with the missing-name message).
      desired = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: name") unless desired

      use = @params["use"]?
      return auto_detect_strategy(desired) unless use

      case use
      when "systemd", "debian"
        systemd_strategy(desired)
      when "redhat"
        redhat_strategy(desired)
      when "alpine"
        alpine_strategy(desired)
      when "openrc"
        openrc_strategy(desired)
      when "generic"
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "use: generic is broken in real Ansible's hostname module (its Base strategy raises NotImplementedError on every operation); failing for parity",
        )
      when "freebsd", "macos", "macosx", "darwin", "openbsd", "solaris", "sles"
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "use: '#{use}' selects a non-Linux platform strategy, which this Linux-only engine does not implement",
        )
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "value of use must be one of: #{USE_CHOICES.join(", ")}, got: #{use}",
        )
      end
    end

    # Build the standard ansible hostname facts hash.
    # Matches the facts plugin's gather_hostname output structure exactly:
    # - ansible_hostname: short name (first label before the first '.');
    #   equals the full name when there is no dot.
    # - ansible_nodename:  the name passed in (the system's node name).
    # - ansible_fqdn:      the live system FQDN from `hostname -f`, falling
    #   back to ansible_hostname when hostname -f fails (hosts with no FQDN
    #   configured return exit 1 + stderr "Name or service not known",
    #   matching the facts module's own behavior).
    # - ansible_domain:    the suffix after the first '.' of the FQDN, or "".
    private def build_facts(hostname : String) : Hash(String, String)
      dot = hostname.index('.')
      short = dot ? hostname[0...dot] : hostname

      fqdn = begin
        output = capture("hostname", ["-f"]).strip
        output.empty? ? short : output
      rescue
        short
      end

      dot_fqdn = fqdn.index('.')
      domain = dot_fqdn ? fqdn[(dot_fqdn + 1)..] : ""

      {
        "ansible_hostname" => short,
        "ansible_nodename" => hostname,
        "ansible_fqdn"     => fqdn,
        "ansible_domain"   => domain,
      }
    end

    # Auto-detect path (no use: given) - the original behavior.
    # Tries hostnamectl first (systemd), falls back to /etc/hostname +
    # hostname(1) for non-systemd systems.
    private def auto_detect_strategy(name : String) : PluginResult
      current = System.hostname

      # Build facts (same shape as the facts plugin's gather_hostname)
      hostname_facts = build_facts(name)

      if current == name
        return PluginResult.new(
          changed: false,
          failed: false,
          ansible_facts: hostname_facts,
          msg: "hostname is already #{name}",
        )
      end

      # Store old facts for diff
      old_facts = build_facts(current)

      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          ansible_facts: hostname_facts,
          diff: generate_attribute_diff(old_facts, hostname_facts),
          msg: "would change hostname from #{current} to #{name}",
        )
      end

      # Actually set the hostname
      set_hostname(name)

      # Re-read to verify (and get the actual resulting hostname, since
      # hostnamectl may normalize it - trimming trailing dots, etc.)
      actual = System.hostname
      actual_facts = build_facts(actual)

      PluginResult.new(
        changed: true,
        failed: false,
        ansible_facts: actual_facts,
        diff: generate_attribute_diff(old_facts, actual_facts),
        msg: "hostname changed from #{current} to #{actual}",
      )
    end

    # SystemdStrategy (use: systemd / use: debian - real Ansible's STRATS
    # maps both to Systemd). Reads even happen in check mode; the permanent
    # hostname is set before the transient one (real Ansible's own ordering
    # to avoid NetworkManager complaints), each preceded by its >64-char
    # guard so the guard only fires when that half actually needs setting.
    private def systemd_strategy(name : String) : PluginResult
      # Real Ansible resolves hostnamectl via get_bin_path at strategy
      # construction - an explicitly requested systemd strategy fails
      # outright when the binary is missing (live-verified message),
      # unlike the auto-detect path's fallback.
      probe = remote_exec("command -v hostnamectl >/dev/null 2>&1")
      if probe[:exit_code] != 0
        path_list = remote_exec("printf '%s' \"$PATH\"")[:stdout]
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to find required executable \"hostnamectl\" in paths: #{path_list}:/sbin:/usr/sbin:/usr/local/sbin",
        )
      end

      transient = read_hostnamectl("--transient status")
      return transient if transient.is_a?(PluginResult)
      permanent = read_hostnamectl("--static status")
      return permanent if permanent.is_a?(PluginResult)

      transient_name = transient.as(String)
      permanent_name = permanent.as(String)

      changed = transient_name != name || permanent_name != name
      hostname_facts = build_facts(name)

      unless changed
        return PluginResult.new(
          changed: false,
          failed: false,
          ansible_facts: hostname_facts,
          msg: "hostname is already #{name}",
        )
      end

      old_facts = build_facts(transient_name)

      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          ansible_facts: hostname_facts,
          diff: generate_attribute_diff(old_facts, hostname_facts),
          msg: "would change hostname from #{transient_name} to #{name}",
        )
      end

      set_failure = systemd_set_phase(name, transient_name, permanent_name)
      return set_failure if set_failure

      PluginResult.new(
        changed: true,
        failed: false,
        ansible_facts: hostname_facts,
        diff: generate_attribute_diff(old_facts, hostname_facts),
        msg: "hostname changed from #{transient_name} to #{name}",
      )
    end

    # The set-phase half of the systemd strategy: permanent first, then
    # transient, each with its own >64-char guard (only fired when that
    # half actually needs setting). Returns nil on success.
    private def systemd_set_phase(name : String, transient_name : String, permanent_name : String) : PluginResult?
      if permanent_name != name
        return too_long_failure(name) if name.size > 64
        result = remote_exec("hostnamectl --pretty --static set-hostname #{Shell.single_quote(name)}")
        return command_failure(result) if result[:exit_code] != 0
      end

      if transient_name != name
        return too_long_failure(name) if name.size > 64
        result = remote_exec("hostnamectl --transient set-hostname #{Shell.single_quote(name)}")
        return command_failure(result) if result[:exit_code] != 0
      end

      nil
    end

    # RedHatStrategy (use: redhat) - edits ONLY /etc/sysconfig/network's
    # HOSTNAME= line. No transient change, no /etc/hostname, no commands.
    # A file without a HOSTNAME entry (or missing entirely) fails even in
    # check mode and even when the name already matches - real Ansible
    # reads the permanent hostname unconditionally first (live-verified).
    private def redhat_strategy(name : String) : PluginResult
      network_file = "/etc/sysconfig/network"
      permanent = ""
      found = false

      if File.exists?(network_file)
        File.each_line(network_file) do |line|
          stripped = line.strip
          next unless stripped.starts_with?("HOSTNAME")
          eq = stripped.index('=')
          permanent = eq ? stripped[(eq + 1)..].strip : ""
          found = true
          break
        end
      end

      unless found
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unable to locate HOSTNAME entry in /etc/sysconfig/network",
        )
      end

      hostname_facts = build_facts(name)

      if permanent == name
        return PluginResult.new(
          changed: false,
          failed: false,
          ansible_facts: hostname_facts,
          msg: "hostname is already #{name}",
        )
      end

      old_facts = build_facts(permanent)

      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          ansible_facts: hostname_facts,
          diff: generate_attribute_diff(old_facts, hostname_facts),
          msg: "would change hostname from #{permanent} to #{name}",
        )
      end

      # Real Ansible's set_permanent_hostname: rewrite the file line by
      # line, replacing the HOSTNAME= line (appending one if somehow
      # absent - unreachable past the read guard above, kept for shape
      # fidelity), preserving everything else including line endings.
      lines = File.read(network_file).split('\n')
      replaced = false
      lines = lines.map do |line|
        if !replaced && line.strip.starts_with?("HOSTNAME")
          replaced = true
          "HOSTNAME=#{name}"
        else
          line
        end
      end
      unless replaced
        had_trailing_newline = lines.last == ""
        lines.insert(had_trailing_newline ? lines.size - 1 : lines.size, "HOSTNAME=#{name}")
      end
      begin
        File.write(network_file, lines.join('\n'))
      rescue ex : File::Error
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to update hostname: #{python_os_error_message(ex)}")
      end

      PluginResult.new(
        changed: true,
        failed: false,
        ansible_facts: hostname_facts,
        diff: generate_attribute_diff(old_facts, hostname_facts),
        msg: "hostname changed from #{permanent} to #{name}",
      )
    end

    # AlpineStrategy (use: alpine) - runs `hostname -F /etc/hostname` FIRST
    # (with the file's OLD content, live-verified: real Ansible's
    # AlpineStrategy extends FileStrategy, so its set_current_hostname
    # no-ops and only the -F call runs), then writes the file.
    # Idempotency comes from the file content alone.
    private def alpine_strategy(name : String) : PluginResult
      hostname_file = "/etc/hostname"

      probe = remote_exec("command -v hostname >/dev/null 2>&1")
      if probe[:exit_code] != 0
        path_list = remote_exec("printf '%s' \"$PATH\"")[:stdout]
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to find required executable \"hostname\" in paths: #{path_list}:/sbin:/usr/sbin:/usr/local/sbin",
        )
      end

      permanent = File.exists?(hostname_file) ? File.read(hostname_file).strip : ""
      hostname_facts = build_facts(name)

      if permanent == name
        return PluginResult.new(
          changed: false,
          failed: false,
          ansible_facts: hostname_facts,
          msg: "hostname is already #{name}",
        )
      end

      old_facts = build_facts(permanent)

      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          ansible_facts: hostname_facts,
          diff: generate_attribute_diff(old_facts, hostname_facts),
          msg: "would change hostname from #{permanent} to #{name}",
        )
      end

      result = remote_exec("hostname -F #{Shell.single_quote(hostname_file)}")
      return command_failure(result) if result[:exit_code] != 0

      begin
        File.write(hostname_file, name + "\n")
      rescue ex : File::Error
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to update hostname: #{python_os_error_message(ex)}")
      end

      PluginResult.new(
        changed: true,
        failed: false,
        ansible_facts: hostname_facts,
        diff: generate_attribute_diff(old_facts, hostname_facts),
        msg: "hostname changed from #{permanent} to #{name}",
      )
    end

    # OpenRCStrategy (use: openrc) - edits /etc/conf.d/hostname's
    # hostname="..." line. Real Ansible's reader slices line[10:] (one
    # character PAST the opening quote, so an unquoted `hostname=x` loses
    # its first character) and returns nil when no hostname= line exists,
    # which crashes real Ansible's diff build with a TypeError
    # (live-verified) - replicated as a failure here. A missing file reads
    # as "" and the write path produces a lone "\n" (live-verified); a
    # missing /etc/conf.d directory fails the write with real Ansible's
    # "failed to update hostname: [Errno 2] ..." text (live-verified).
    private def openrc_strategy(name : String) : PluginResult
      conf_file = "/etc/conf.d/hostname"
      permanent : String? = nil

      if File.exists?(conf_file)
        File.each_line(conf_file) do |line|
          stripped = line.strip
          if stripped.starts_with?("hostname=")
            permanent = stripped[10..].to_s.strip('"')
            break
          end
        end
      else
        permanent = ""
      end

      if permanent.nil?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unable to read hostname from /etc/conf.d/hostname: no hostname= line (real Ansible crashes here with a TypeError)",
        )
      end

      hostname_facts = build_facts(name)

      if permanent == name
        return PluginResult.new(
          changed: false,
          failed: false,
          ansible_facts: hostname_facts,
          msg: "hostname is already #{name}",
        )
      end

      old_facts = build_facts(permanent)

      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          ansible_facts: hostname_facts,
          diff: generate_attribute_diff(old_facts, hostname_facts),
          msg: "would change hostname from #{permanent} to #{name}",
        )
      end

      lines = File.exists?(conf_file) ? File.read(conf_file).lines.map(&.strip) : [] of String
      replaced = false
      lines = lines.map do |line|
        if !replaced && line.starts_with?("hostname=")
          replaced = true
          "hostname=\"#{name}\""
        else
          line
        end
      end
      begin
        File.write(conf_file, lines.join('\n') + "\n")
      rescue ex : File::Error
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to update hostname: #{python_os_error_message(ex)}")
      end

      PluginResult.new(
        changed: true,
        failed: false,
        ansible_facts: hostname_facts,
        diff: generate_attribute_diff(old_facts, hostname_facts),
        msg: "hostname changed from #{permanent} to #{name}",
      )
    end

    # Run one of the strategy's hostnamectl reads; returns the stripped
    # output or a PluginResult failure shaped like real Ansible's
    # "Command failed rc=%d, out=%s, err=%s" (live-verified).
    private def read_hostnamectl(args : String) : String | PluginResult
      result = remote_exec("hostnamectl #{args}")
      if result[:exit_code] != 0
        return command_failure(result)
      end
      result[:stdout].strip
    end

    # Format a File::Error the way Python's str(OSError) renders it - real
    # Ansible's file-write failure paths fail_json with
    # "failed to update hostname: %s" % to_native(e), where e is the raw
    # OSError, e.g. "[Errno 2] No such file or directory: '/etc/conf.d/hostname'"
    # (live-verified against ansible-core 2.19.4 in a container).
    private def python_os_error_message(ex : File::Error) : String
      os = ex.os_error
      if os.is_a?(Errno)
        "[Errno #{os.value}] #{os.message}: '#{ex.file}'"
      else
        ex.message.to_s
      end
    end

    private def too_long_failure(name : String) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "name cannot be longer than 64 characters on systemd servers, try a shorter name",
      )
    end

    private def command_failure(result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Command failed rc=#{result[:exit_code]}, out=#{result[:stdout]}, err=#{result[:stderr]}",
      )
    end

    # Set the system hostname persistently (auto-detect path only).
    private def set_hostname(name : String) : Nil
      # Try systemd's hostnamectl first - detect failure via exit status.
      # capture swallows errors and returns "", so a failed hostnamectl call
      # is indistinguishable from an empty-stdout success on its own; the
      # status check below is what actually drives the fallback.
      if run_succeeds?("hostnamectl", ["set-hostname", name])
        return
      end

      # Legacy fallback: write /etc/hostname and run hostname(1)
      File.write("/etc/hostname", name + "\n")
      capture("hostname", [name])
    end

    # Run *command* with *args* directly (no shell). Returns true iff the
    # process exited 0 (binary found and succeeded). stderr is discarded; a
    # missing binary or nonzero exit => false.
    private def run_succeeds?(command : String, args : Array(String) = [] of String) : Bool
      status = Process.run(command, args, error: Process::Redirect::Close)
      status.success?
    rescue
      false
    end

    # Run *command* with *args* directly (no shell), capturing stdout only
    # (stderr discarded). Returns "" if the binary can't be found or
    # execution otherwise fails - matches facts.cr's/service_facts.cr's own
    # `capture` helper (the plugin binary itself already executes on the
    # target host, so a plain local Process.run is correct here, not
    # remote_exec).
    private def capture(command : String, args : Array(String) = [] of String) : String
      output = IO::Memory.new
      Process.run(command, args, output: output, error: Process::Redirect::Close)
      output.to_s
    rescue
      ""
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::HostnamePlugin.new(config)
plugin.run
