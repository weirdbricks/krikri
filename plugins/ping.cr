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

      PluginResult.new(changed: false, failed: false, msg: "", ping: data)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PingPlugin.new(config)
plugin.run
