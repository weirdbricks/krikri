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
  # for the retry loop ONLY - real Ansible's action plugin sleeps the
  # full delay first and starts the deadline clock afterwards, so a
  # delay: larger than timeout: is applied in full and only then times
  # out (the deadline never absorbs the delay).
  # connect_timeout: bounds each individual attempt's own connection
  # wait, reusing SSHManager#exec's own process-timeout parameter -
  # the real module has this as a distinct, smaller-than-timeout knob
  # specifically so one hung attempt can't eat the whole budget.
  # Check mode short-circuits to skipped before any probe (real
  # Ansible's own action plugin does the same), and every result
  # carries elapsed: whole seconds since task start, success or
  # timeout alike - real Ansible always sets it too.
  class WaitForConnectionPlugin < BasePlugin
    def execute : PluginResult
      # Real module converts each arg with int() before anything else,
      # so a non-numeric value fails the task (even in check mode)
      # rather than silently falling back to the default.
      delay = int_arg("delay", 0)
      return invalid_int_result("delay") unless delay

      sleep_interval = int_arg("sleep", 1)
      return invalid_int_result("sleep") unless sleep_interval

      timeout = int_arg("timeout", 600)
      return invalid_int_result("timeout") unless timeout

      connect_timeout = int_arg("connect_timeout", 5)
      return invalid_int_result("connect_timeout") unless connect_timeout

      start_monotonic = Time.monotonic

      if true?(@params["_ansible_check_mode"]?)
        return PluginResult.new(changed: false, failed: false,
          msg: "`wait_for_connection` did not execute due to check mode",
          skipped: true)
      end

      # One unconditional sleep before the loop, matching real Ansible.
      sleep delay.seconds if delay > 0

      deadline = Time.monotonic + timeout.seconds

      loop do
        if probe_connection(connect_timeout)
          return PluginResult.new(changed: false, failed: false, msg: "",
            elapsed: elapsed_since(start_monotonic))
        end

        return timeout_result(start_monotonic) if Time.monotonic >= deadline

        remaining = (deadline - Time.monotonic).total_seconds
        sleep [sleep_interval, remaining.to_i].min.clamp(0..).seconds
      end
    end

    private def int_arg(name : String, default : Int32) : Int32?
      raw = @params[name]?
      return default unless raw
      raw.to_i?
    end

    private def invalid_int_result(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "invalid integer value for #{name}")
    end

    # Real Ansible's action plugin raises
    # TimedOutException("timed out waiting for ping module test: ping
    # test failed") and turns that into the failed result's msg (plus
    # elapsed, whole seconds since task start).
    private def timeout_result(start_monotonic : Time::Span) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "timed out waiting for ping module test: ping test failed",
        elapsed: elapsed_since(start_monotonic)
      )
    end

    # Whole seconds, matching real Ansible's own `elapsed.seconds`
    # timedelta read (not total_seconds - values wrap past hours there
    # too).
    private def elapsed_since(start_monotonic : Time::Span) : Int32
      (Time.monotonic - start_monotonic).seconds
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
