#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Ping plugin - trivial connectivity check, matches
  # ansible.builtin.ping exactly.
  #
  # Entirely unimplemented before - robertdebock.test_connection's own
  # "Ping with become" task silently dropped instead of running.
  #
  # Real module: returns {"ping": data} where data defaults to "pong",
  # UNLESS data == "crash", which raises an exception (a real, deliberate
  # module-level failure path used to test error handling, not something
  # normal roles trigger). Never reports changed.
  class PingPlugin < BasePlugin
    def execute : PluginResult
      data = @params["data"]? || "pong"

      if data == "crash"
        return PluginResult.new(changed: false, failed: true, msg: "boom")
      end

      # Real's registered ping result runs ping, failed, changed
      # (live-verified vs 2.19.11 via `{{ r | to_json }}`). Real's module
      # wire carries ONLY {ping} - exit_json passes no changed, and the
      # task executor backfills failed, changed at the tail - so the
      # wire omits changed too (omit_changed) and normalize_module_result
      # appends the same failed, changed tail on register.
      PluginResult.new(changed: false, failed: false, msg: "", ping: data, omit_changed: true, key_order: ["ping"])
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PingPlugin.new(config)
plugin.run
