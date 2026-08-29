#!/usr/bin/env crystal

require "json"
require "socket"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/proc_net_tcp"

module CrystalPlay
  # wait_for plugin (ansible.builtin.wait_for) - polls until a port becomes
  # connectable/closed, a file appears/disappears, or a regex is found in a
  # file, gating a later task on readiness.
  #
  # Real Ansible's wait_for has no check-mode support at all (verified
  # against a real ansible-playbook --check run, not assumed - same
  # "remote module (wait_for) does not support check mode" skip text this
  # plugin reuses verbatim) and never reports changed - it only ever waits,
  # never mutates anything.
  #
  # state: drained polls /proc/net/tcp (IPv4 only - see
  # PluginHelpers::ProcNetTcp's own class doc for why IPv6 is a scope
  # cut) directly, matching real Ansible's own `LinuxTCPConnectionInfo`
  # strategy - the file's own hex encoding (byte-reversed IP octets, a
  # plain 4-digit hex port, and a two-digit connection-state code) was
  # verified against this machine's own real /proc/net/tcp output, and
  # the state-code mapping against ansible/modules/wait_for.py's own
  # source, not assumed. `active_connection_states:` (default
  # ESTABLISHED/FIN_WAIT1/FIN_WAIT2/SYN_RECV/SYN_SENT/TIME_WAIT, matching
  # real Ansible's own default) and `exclude_hosts:` (IPv4 literals only,
  # same scope cut as `host:` itself - no DNS resolution) are both
  # supported. `host:` must resolve to a literal IPv4 address for
  # `drained:` specifically (this plugin's other states already default
  # `host:` to a literal, so this only matters if a hostname is passed
  # explicitly) - fails clearly rather than silently matching nothing.
  #
  # `search_regex` also works against an open socket, not just a file -
  # verified against real ansible/modules/wait_for.py's own source:
  # connects, then reads (accumulating bytes) until the regex matches,
  # the connection closes, or the poll iteration's own remaining timeout
  # budget passes - see `#check_port_regex`'s own doc comment for the
  # exact behavior matched (and the one simplification: a single read
  # loop per connection attempt bounded by the overall deadline, rather
  # than replicating real Ansible's own `select()`-based remaining-time
  # tracking byte-for-byte - functionally equivalent, reconnects via the
  # same outer poll/sleep loop on any timeout/disconnect either way).
  class WaitForPlugin < BasePlugin
    def execute : PluginResult
      if true?(@params["check_mode"]?)
        return PluginResult.new(changed: false, failed: false, msg: "remote module (wait_for) does not support check mode", skipped: true)
      end

      port = @params["port"]?.try(&.to_i)
      path = @params["path"]?.try { |raw| expand_tilde(raw) }
      state = @params["state"]? || "started"
      if error = validate(port, path, state)
        return error
      end

      delay = (@params["delay"]? || "0").to_i
      timeout = (@params["timeout"]? || "300").to_i
      started = Time.monotonic
      sleep(delay.seconds) if delay > 0

      if result = try_drained(port, state, timeout, started)
        return result
      end

      # With no port/path given, wait_for is just a plain sleep for the
      # full timeout - matches real Ansible's own documented behavior
      # ("used without other conditions it is equivalent of just
      # sleeping"), verified against a real ansible-playbook run (it does
      # not return early).
      if port.nil? && path.nil?
        sleep(timeout.seconds)
        return success_result(nil, nil, started)
      end

      poll_until_satisfied(port, path, timeout, started)
    end

    # Returns nil (fall through to the ordinary port/path polling below)
    # unless state: is drained - #validate already confirmed a drained:
    # request has both a port: and a host: that resolves to a literal
    # IPv4 address, but re-checking here (rather than asserting with
    # `not_nil!`) keeps the compiler's own narrowing doing the work
    # instead. Split out of #execute to keep its own branch count down
    # (ameba's cyclomatic-complexity budget).
    private def try_drained(port : Int32?, state : String, timeout : Int32, started : Time::Span) : PluginResult?
      return nil unless state == "drained"
      return nil unless (drained_port = port) && (host_hex = PluginHelpers::ProcNetTcp.ipv4_to_hex(@params["host"]? || "127.0.0.1"))

      poll_drained(drained_port, host_hex, timeout, started)
    end

    private def validate(port : Int32?, path : String?, state : String) : PluginResult?
      if port && path
        return PluginResult.new(changed: false, failed: true, msg: "path and port are mutually exclusive parameters")
      end

      if state == "drained"
        unless port
          return PluginResult.new(changed: false, failed: true, msg: "state: drained should only be used for checking a port in the wait_for module")
        end
        unless PluginHelpers::ProcNetTcp.ipv4_to_hex(@params["host"]? || "127.0.0.1")
          return PluginResult.new(changed: false, failed: true, msg: "state: drained only supports a literal IPv4 host:")
        end
      elsif @params["exclude_hosts"]?
        return PluginResult.new(changed: false, failed: true, msg: "exclude_hosts should only be with state=drained")
      end

      nil
    end

    # Polls /proc/net/tcp until no active connection matches host:/port:
    # (see PluginHelpers::ProcNetTcp's own class doc for the exact
    # matching rules and IPv4-only scope).
    private def poll_drained(port : Int32, host_hex : String, timeout : Int32, started : Time::Span) : PluginResult
      host = @params["host"]? || "127.0.0.1"
      port_hex = PluginHelpers::ProcNetTcp.port_to_hex(port)
      active_states = @params["active_connection_states"]?.try { |raw| raw.split(',').map(&.strip) } || PluginHelpers::ProcNetTcp::DEFAULT_ACTIVE_STATES
      exclude_hexes = @params["exclude_hosts"]?.try { |raw| raw.split(',').map(&.strip).compact_map { |excluded| PluginHelpers::ProcNetTcp.ipv4_to_hex(excluded) } } || [] of String
      sleep_interval = (@params["sleep"]? || "1").to_i.seconds
      deadline = Time.monotonic + timeout.seconds

      loop do
        connections = PluginHelpers::ProcNetTcp.parse(read_proc_net_tcp)
        active = PluginHelpers::ProcNetTcp.count_active(connections, host_hex, port_hex, active_states, exclude_hexes)
        return success_result(nil, nil, started) if active == 0

        break if Time.monotonic >= deadline
        sleep(sleep_interval)
      end

      PluginResult.new(
        changed: false, failed: true,
        msg: @params["msg"]? || "Timeout when waiting for #{host}:#{port} to drain",
        elapsed: (Time.monotonic - started).total_seconds.to_i
      )
    end

    private def read_proc_net_tcp : String
      File.exists?("/proc/net/tcp") ? File.read("/proc/net/tcp") : ""
    end

    private def poll_until_satisfied(port : Int32?, path : String?, timeout : Int32, started : Time::Span) : PluginResult
      up = (@params["state"]? || "started").in?("started", "present")
      sleep_interval = (@params["sleep"]? || "1").to_i.seconds
      deadline = Time.monotonic + timeout.seconds

      loop do
        satisfied, match = check_condition(port, path, up, deadline)
        return success_result(path, match, started) if satisfied

        break if Time.monotonic >= deadline
        sleep(sleep_interval)
      end

      PluginResult.new(
        changed: false, failed: true,
        msg: @params["msg"]? || timeout_message(port, path),
        elapsed: (Time.monotonic - started).total_seconds.to_i
      )
    end

    private def success_result(path : String?, match : Regex::MatchData?, started : Time::Span) : PluginResult
      result = PluginResult.new(changed: false, failed: false, msg: "", path: path, elapsed: (Time.monotonic - started).total_seconds.to_i)
      groups = match.try(&.to_a[1..].compact.map { |group| JSON::Any.new(group) }) || [] of JSON::Any
      result.extra["match_groups"] = JSON::Any.new(groups)
      result.extra["match_groupdict"] = JSON::Any.new(Hash(String, JSON::Any).new)
      result
    end

    private def timeout_message(port : Int32?, path : String?) : String
      if port
        host = @params["host"]? || "127.0.0.1"
        if regex = @params["search_regex"]?
          "Timeout when waiting for search string #{regex} in #{host}:#{port}"
        else
          "Timeout when waiting for #{host}:#{port}"
        end
      elsif path
        if regex = @params["search_regex"]?
          "Timeout when waiting for search string #{regex} in #{path}"
        else
          "Timeout when waiting for file #{path}"
        end
      else
        "Timeout when waiting for condition"
      end
    end

    # Returns {satisfied, match} - match is only ever set for a successful
    # search_regex hit (used to populate match_groups/match_groupdict).
    # Only called with a port or a path - the no-condition "just sleep"
    # case is handled directly in execute before this is ever reached.
    private def check_condition(port : Int32?, path : String?, up : Bool, deadline : Time::Span) : {Bool, Regex::MatchData?}
      if port
        if up && (regex = @params["search_regex"]?)
          check_port_regex(port, regex, deadline)
        else
          {port_connectable?(port) == up, nil}
        end
      elsif path
        check_path(path, up)
      else
        raise "unreachable"
      end
    end

    # search_regex matched against data read from an open socket, not
    # just a file - verified against real ansible/modules/wait_for.py's
    # own source: connects, then reads (accumulating bytes) until the
    # regex matches, the connection closes, or *deadline* (this poll
    # iteration's own overall timeout budget, not a fresh per-call one)
    # passes - matching real Ansible's own single-connection read loop
    # bounded by its own remaining-time budget, not a fixed per-attempt
    # timeout. A connection refused/reset, a read timeout, or a closed
    # connection with no match all fall through to {false, nil} - the
    # outer poll loop (already implemented) reconnects and retries after
    # its own sleep: interval, same as real Ansible's outer while loop
    # does on any not-yet-satisfied iteration.
    private def check_port_regex(port : Int32, regex : String, deadline : Time::Span) : {Bool, Regex::MatchData?}
      host = @params["host"]? || "127.0.0.1"
      connect_timeout = (@params["connect_timeout"]? || "5").to_i.seconds
      compiled = Regex.new(regex, Regex::CompileOptions::MULTILINE)

      socket = TCPSocket.new(host, port, connect_timeout: connect_timeout)
      begin
        remaining = deadline - Time.monotonic
        socket.read_timeout = remaining > Time::Span.zero ? remaining : 1.milliseconds

        data = IO::Memory.new
        buf = Bytes.new(4096)
        loop do
          bytes_read = socket.read(buf)
          break {false, nil} if bytes_read == 0 # server closed, no match

          data.write(buf[0, bytes_read])
          if match = compiled.match(String.new(data.to_slice))
            break {true, match}
          end

          break {false, nil} if Time.monotonic >= deadline
        end
      ensure
        socket.close rescue nil
      end
    rescue
      {false, nil}
    end

    private def port_connectable?(port : Int32) : Bool
      host = @params["host"]? || "127.0.0.1"
      connect_timeout = (@params["connect_timeout"]? || "5").to_i.seconds

      socket = TCPSocket.new(host, port, connect_timeout: connect_timeout)
      socket.close
      true
    rescue
      false
    end

    private def check_path(path : String, up : Bool) : {Bool, Regex::MatchData?}
      exists = File.exists?(path)

      if regex = @params["search_regex"]?
        return {false, nil} unless up # search_regex only makes sense for present/started
        return {false, nil} unless exists

        match = Regex.new(regex, Regex::CompileOptions::MULTILINE).match(File.read(path))
        {!match.nil?, match}
      else
        {exists == up, nil}
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::WaitForPlugin.new(config)
plugin.run
