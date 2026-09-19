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
  # completion - see AsyncJobs. mode: cleanup is implemented too (real Ansible's own mode): deletes the
  # job's status/config files - or, with jid: ALL (or no jid at all), every
  # job file in the async dir, which previously grew without bound.
  # (deleting the job's status file) is not.
  #
  # Forwards the underlying job's own changed: verbatim once finished
  # (verified against real ansible-playbook: an async_status: on a
  # finished command: job shows changed: [host], matching the command
  # module's own changed status, not a hardcoded false) - false while
  # still running, since there's nothing changed to report yet.
  class AsyncStatusPlugin < BasePlugin
    def execute : PluginResult
      # Real async_status.py: jid is required=True for EVERY mode (cleanup
      # included), and the job-file existence check runs BEFORE the mode
      # check - so cleanup on a jid that never ran fails with the same
      # "could not find job" shape as a status lookup, not a silent
      # success (confirmed via the podman-diff async_status cases, D2b).
      jid = @params["jid"]?
      unless jid
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: jid")
      end

      # The jid is joined into the async dir path by AsyncJobs - reject
      # anything path-shaped (traversal, separators) before that can
      # happen, for every mode, rather than letting a malformed jid turn
      # status mode into an arbitrary-file read or cleanup into an
      # arbitrary-file delete.
      unless AsyncJobs.valid_jid?(jid)
        return PluginResult.new(changed: false, failed: true, msg: "invalid jid: #{jid}",
          ansible_job_id: jid)
      end

      status = AsyncJobs.read_status(jid)
      unless status
        # Real Ansible's own not-found shape (async_status.py's
        # fail_json call): msg without the jid interpolated, jid carried
        # separately as ansible_job_id, and started/finished as real
        # JSON booleans (ansible-core 2.19+ wording).
        return PluginResult.new(changed: false, failed: true, msg: "could not find job",
          ansible_job_id: jid, started: true, finished: true)
      end

      if @params["mode"]? == "cleanup"
        AsyncJobs.cleanup(jid)
        return PluginResult.new(changed: false, failed: false, msg: "Cleaned up job file for #{jid}",
          ansible_job_id: jid, erased: AsyncJobs.status_path(jid))
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
