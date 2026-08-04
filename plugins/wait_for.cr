#!/usr/bin/env crystal

require "json"
require "socket"
require "../src/crystal_play/base_plugin"

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
  # Not implemented: `drained` (active TCP connection draining - needs
  # /proc/net-style connection-state inspection with no faithful native
  # Crystal equivalent), `exclude_hosts`/`active_connection_states`
  # (drained-only options), `search_regex` matched against an open socket
  # (only file-content matching is implemented, per this entry's own
  # original scope) - all lower-value than the core port/path/regex-in-file
  # polling path.
  class WaitForPlugin < BasePlugin
    def execute : PluginResult
      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: false, failed: false, msg: "remote module (wait_for) does not support check mode", skipped: true)
      end

      port = @params["port"]?.try(&.to_i)
      path = @params["path"]?
      if error = validate(port, path)
        return error
      end

      delay = (@params["delay"]? || "0").to_i
      timeout = (@params["timeout"]? || "300").to_i
      started = Time.monotonic
      sleep(delay.seconds) if delay > 0

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

    private def validate(port : Int32?, path : String?) : PluginResult?
      if port && path
        return PluginResult.new(changed: false, failed: true, msg: "path and port are mutually exclusive parameters")
      end

      if (@params["state"]? || "started") == "drained"
        return PluginResult.new(changed: false, failed: true, msg: "state: drained is not implemented")
      end

      nil
    end

    private def poll_until_satisfied(port : Int32?, path : String?, timeout : Int32, started : Time::Span) : PluginResult
      up = (@params["state"]? || "started").in?("started", "present")
      sleep_interval = (@params["sleep"]? || "1").to_i.seconds
      deadline = Time.monotonic + timeout.seconds

      loop do
        satisfied, match = check_condition(port, path, up)
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
        "Timeout when waiting for #{host}:#{port}"
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
    private def check_condition(port : Int32?, path : String?, up : Bool) : {Bool, Regex::MatchData?}
      if port
        {port_connectable?(port) == up, nil}
      elsif path
        check_path(path, up)
      else
        raise "unreachable"
      end
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
