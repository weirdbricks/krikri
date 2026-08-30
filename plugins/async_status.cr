#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/async_jobs"

module Krikri
  # async_status plugin - checks on a background job started by a task
  # with async:. Compatible with Ansible's ansible.builtin.async_status.
  #
  # Supported parameters:
  # - jid: the ansible_job_id to check (required)
  #
  # Reads the same ~/.ansible_async/<jid> status file TaskExecutor#
  # execute_async's spawned __async_run background process writes to on
  # completion - see AsyncJobs. Only "status" mode is implemented; "cleanup"
  # (deleting the job's status file) is not.
  #
  # Forwards the underlying job's own changed: verbatim once finished
  # (verified against real ansible-playbook: an async_status: on a
  # finished command: job shows changed: [host], matching the command
  # module's own changed status, not a hardcoded false) - false while
  # still running, since there's nothing changed to report yet.
  class AsyncStatusPlugin < BasePlugin
    def execute : PluginResult
      jid = @params["jid"]?
      unless jid
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: jid")
      end

      status = AsyncJobs.read_status(jid)
      unless status
        return PluginResult.new(changed: false, failed: true, msg: "could not find job #{jid}", finished: 1)
      end

      finished = AsyncJobs.finished?(status)
      job_changed = status["changed"]?.try(&.as_bool) || false
      job_failed = status["failed"]?.try(&.as_bool) || false
      msg = status["msg"]?.try(&.as_s) || (finished ? "job finished" : "job is still running")

      result = PluginResult.new(changed: finished && job_changed, failed: finished && job_failed, msg: msg)
      status.as_h.each do |key, value|
        next if ["changed", "failed", "msg"].includes?(key)
        result.extra[key] = value
      end
      result
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::AsyncStatusPlugin.new(config)
plugin.run
