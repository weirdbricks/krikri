#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # WaitForConnection plugin - matches ansible.builtin.wait_for_connection.
  #
  # Entirely unimplemented before - robertdebock.test_connection's own
  # "Wait_for_connection" task silently dropped instead of running.
  #
  # Real Ansible's own module retries the actual connection plugin
  # (SSH/local/etc) until it succeeds or `timeout:` is exceeded, sleeping
  # `sleep:` seconds between attempts, waiting `delay:` seconds before the
  # very first attempt. This codebase's plugins already run ON the
  # target, dispatched over the exact connection (SSH session, or a
  # local subprocess for `ansible_connection=local`) this module would
  # otherwise be testing - by the time this plugin's own process is
  # running at all, that connection has already succeeded, so the real
  # module's retry loop has nothing left to do. Only `delay:` has an
  # observable effect here (a real wait before reporting success);
  # `connect_timeout:`/`sleep:`/`timeout:` are accepted but unused.
  class WaitForConnectionPlugin < BasePlugin
    def execute : PluginResult
      delay = @params["delay"]?.try(&.to_i?) || 0
      sleep delay.seconds if delay > 0

      PluginResult.new(changed: false, failed: false, msg: "")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::WaitForConnectionPlugin.new(config)
plugin.run
