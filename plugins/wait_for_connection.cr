#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # WaitForConnection plugin - matches ansible.builtin.wait_for_connection.
  #
  # Controller-only (see plugin_manager.cr's own CONTROLLER_ONLY_PLUGINS
  # comment for the full story) - this plugin never gets uploaded to and
  # executed ON the target, since that would require the very connection
  # it exists to wait for. Instead it runs here, on the controller, and
  # retries the actual connection attempt itself via #remote_exec
  # (SSHManager for a real remote host, LocalExecutor for
  # ansible_connection=local) - the same thing real Ansible's own module
  # does by retrying its connection plugin.
  #
  # delay: seconds to wait before the FIRST attempt (real Ansible: give
  # a just-triggered reboot/service-restart a head start before even
  # trying). sleep: seconds between retries. timeout: overall deadline
  # from when this task started (not from the first attempt, matching
  # real Ansible - a delay: that itself exceeds timeout: fails
  # immediately with zero attempts made, same as there).
  # connect_timeout: bounds each individual attempt's own connection
  # wait, reusing SSHManager#exec's own process-timeout parameter -
  # the real module has this as a distinct, smaller-than-timeout knob
  # specifically so one hung attempt can't eat the whole budget.
  class WaitForConnectionPlugin < BasePlugin
    def execute : PluginResult
      delay = @params["delay"]?.try(&.to_i?) || 0
      sleep_interval = @params["sleep"]?.try(&.to_i?) || 1
      timeout = @params["timeout"]?.try(&.to_i?) || 600
      connect_timeout = @params["connect_timeout"]?.try(&.to_i?) || 5

      deadline = Time.monotonic + timeout.seconds

      if delay > 0
        return timeout_result(delay) if Time.monotonic + delay.seconds > deadline
        sleep delay.seconds
      end

      loop do
        result = probe_connection(connect_timeout)
        return PluginResult.new(changed: false, failed: false, msg: "") if result

        return timeout_result(timeout) if Time.monotonic >= deadline

        remaining = (deadline - Time.monotonic).total_seconds
        sleep [sleep_interval, remaining.to_i].min.clamp(0..).seconds
      end
    end

    private def timeout_result(timeout : Int32) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "timed out waiting for last boot time check (timeout=#{timeout})"
      )
    end

    # A trivial no-op command, same purpose as real Ansible's own
    # connection-plugin ping: succeeds iff the connection itself works,
    # regardless of what's actually on the target. Any exception (SSH
    # process spawn failure, refused connection, DNS not yet up after a
    # reboot) is treated as "not connected yet", not a plugin crash.
    private def probe_connection(connect_timeout : Int32) : Bool
      remote_exec("true", timeout: connect_timeout)[:exit_code] == 0
    rescue
      false
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::WaitForConnectionPlugin.new(config)
plugin.run
