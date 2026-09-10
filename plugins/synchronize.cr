#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/synchronize_rsync"

module Krikri
  # synchronize plugin (ansible.posix.synchronize) - the standalone binary
  # half of the port. The normal task-execution path never reaches this:
  # synchronize is controller-side there (SynchronizeActionPlugin, which
  # munges src/dest into remote `user@host:path` form and runs rsync from
  # the controller/delegate). This binary implements the MODULE half for
  # `--async`/manual invocation on whatever host the "local" rsync end is:
  # it takes FINAL src/dest (already munged - plain local paths, or
  # user@host:path specs for rsync's own remote-shell transport) and
  # shells out to the `rsync` CLI with the real module's argument
  # construction, via the shared SynchronizeRsync helper. Idempotency
  # (changed: false on a no-op rsync run) comes from rsync's own itemized
  # output - see SynchronizeRsync's changed-detection comment.
  class SynchronizePlugin < BasePlugin
    def execute : PluginResult
      src = @params["src"]?
      dest = @params["dest"]?

      if src.nil? || src.empty? || dest.nil? || dest.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "synchronize requires both src and dest parameters are set")
      end

      private_key = @params["private_key"]? || @vars["ansible_ssh_private_key_file"]?.try(&.as_s?)
      dest_port = resolve_dest_port

      argv = SynchronizeRsync.build_argv(src, dest, @params, private_key, dest_port)
      result = SynchronizeRsync.run(argv)
      cmd_str = argv.join(" ")

      unless result.rc == 0
        msg = result.error.empty? ? result.output : result.error
        return PluginResult.new(changed: false, failed: true, msg: msg,
          rc: result.rc, cmd: cmd_str)
      end

      changed = SynchronizeRsync.changed?(result.output, !SynchronizeRsync.parse_list(@params["link_dest"]?).empty?)
      out_clean = SynchronizeRsync.clean_output(result.output)

      PluginResult.new(changed: changed, failed: false, msg: out_clean,
        rc: 0, cmd: cmd_str, stdout_lines: out_clean.lines)
    end

    private def resolve_dest_port : Int32?
      return @params["dest_port"].not_nil!.strip.to_i if @params["dest_port"]?.try { |v| v.strip =~ /\A\d+\z/ }
      return @vars["ansible_port"].as_i if @vars["ansible_port"]?.try(&.as_i?)
      @host.port
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SynchronizePlugin.new(config)
plugin.run
