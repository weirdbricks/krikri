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
        return missing_jid_result
      end

      # The jid is joined into the async dir path by AsyncJobs - reject
      # anything path-shaped (traversal, separators) before that can
      # happen, for every mode, rather than letting a malformed jid turn
      # status mode into an arbitrary-file read or cleanup into an
      # arbitrary-file delete.
      unless AsyncJobs.valid_jid?(jid)
        return invalid_jid_result(jid)
      end

      status = AsyncJobs.read_status(jid)
      unless status
        # Real Ansible's own not-found shape (async_status.py's
        # fail_json call): msg without the jid interpolated, jid carried
        # separately as ansible_job_id, and started/finished as real
        # JSON booleans (ansible-core 2.19+ wording).
        return not_found_result(jid)
      end

      if @params["mode"]? == "cleanup"
        return cleanup_result(jid)
      end

      status_result(status, jid)
    end

    private def missing_jid_result : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required arguments: jid")
    end

    private def invalid_jid_result(jid : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "invalid jid: #{jid}",
        ansible_job_id: jid)
    end

    private def not_found_result(jid : String) : PluginResult
      # Real's result also carries the results_file path (the job file
      # that doesn't exist) plus empty stdout/stderr pairs with their
      # _lines companions - live-captured from real ansible-playbook
      # 2.19.11 against a never-started jid.
      PluginResult.new(changed: false, failed: true, msg: "could not find job",
        ansible_job_id: jid, started: true, finished: true,
        results_file: AsyncJobs.status_path(jid),
        stdout: "", stdout_lines: [] of String,
        stderr: "", stderr_lines: [] of String)
    end

    private def cleanup_result(jid : String) : PluginResult
      AsyncJobs.cleanup(jid)
      PluginResult.new(changed: false, failed: false, msg: "Cleaned up job file for #{jid}",
        ansible_job_id: jid, erased: AsyncJobs.status_path(jid))
    end

    # Real 2.19.11's async_status registered shapes (live-verified via
    # `{{ r.keys() | list | to_json }}` on registered status-mode tasks
    # against a running and a finished command job):
    #  - still running: started, finished, stdout, stderr, stdout_lines,
    #    stderr_lines, ansible_job_id, results_file, failed, changed -
    #    and NO msg key (the old "job is still running" msg was
    #    krikri-only; real's action plugin never carries one).
    #  - finished: the same base dict merged with the job file's module
    #    result - duplicates keep their base position, the module's own
    #    keys follow in file order (command: changed, rc, cmd, start,
    #    end, delta, msg, failed). The base dict is what
    #    ansible/plugins/action/async_status.py initializes (then
    #    coerces started/finished to booleans) before merge_hash with
    #    the module result; the key_order below mirrors that merge
    #    DYNAMICALLY from the file's own key order, so any module's
    #    shape lands in real's order rather than a command-only pin.
    # Real's msg key on a finished job is whatever the module's file
    # carried (an empty string for command) - present iff the file has
    # the key, hence include_empty_msg on the empty-string case.
    private def status_result(status : JSON::Any, jid : String) : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      finished = AsyncJobs.finished?(status)
      job_changed = status["changed"]?.try(&.as_bool) || false
      job_failed = status["failed"]?.try(&.as_bool) || false

      file_msg = status["msg"]?
      result = if file_msg && (file_msg_s = file_msg.as_s?)
                 PluginResult.new(changed: finished && job_changed,
                   failed: finished && job_failed,
                   msg: file_msg_s,
                   include_empty_msg: true)
               elsif file_msg
                 PluginResult.new(changed: finished && job_changed,
                   failed: finished && job_failed,
                   msg: "", native_msg: file_msg)
               else
                 PluginResult.new(changed: finished && job_changed,
                   failed: finished && job_failed)
               end

      # Normalize started/finished into the RESULT so a finished poll
      # never omits the key (the until:/retries machinery keys off
      # `poll_result.finished`; a finished poll that omits it would
      # retry until retries exhausted - found live: modules_systems.yml's
      # async probe polled a finished job 30 times, then reported a
      # result with no finished key at all). Real ansible-core 2.19.11
      # carries BOTH as JSON booleans (live-verified: the registered var
      # of a finished async_status: poll renders finished=True,
      # started=true - the old 0/1 ints rendered as 1/0 instead).
      result.extra["started"] = JSON::Any.new(true)
      result.extra["finished"] = JSON::Any.new(finished)
      # Real's action-plugin base dict: empty stdout/stderr pairs (and
      # their _lines companions) plus the jid echo and the job-file path
      # - present on the running shape, overwritten in place by the
      # module file's own values on the finished one (same insertion
      # position, like merge_hash).
      result.extra["stdout"] = JSON::Any.new("")
      result.extra["stderr"] = JSON::Any.new("")
      result.extra["stdout_lines"] = JSON.parse("[]")
      result.extra["stderr_lines"] = JSON.parse("[]")
      result.extra["ansible_job_id"] = JSON::Any.new(jid)
      result.extra["results_file"] = JSON::Any.new(AsyncJobs.status_path(jid))
      status.as_h.each do |key, value|
        next if ["changed", "failed", "msg", "started", "finished"].includes?(key)
        result.extra[key] = value
      end

      order = ["started", "finished", "stdout", "stderr", "stdout_lines",
               "stderr_lines", "ansible_job_id", "results_file"]
      status.as_h.each_key do |key|
        next if ["started", "finished"].includes?(key)
        order << key unless order.includes?(key)
      end
      # A file without its own failed/changed (or the still-running
      # stub, which has neither) trails them like the executor's
      # failed/changed backfill would; a running job's registered shape
      # is ... results_file, failed, changed (live-verified).
      order << "failed" unless order.includes?("failed")
      order << "changed" unless order.includes?("changed")
      result.key_order = order
      result
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::AsyncStatusPlugin.new(config)
plugin.run
