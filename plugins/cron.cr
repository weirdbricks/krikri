#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/cron_table"

module Krikri
  # Cron plugin - manages a named entry in a crontab-style file
  # Compatible with (a subset of) Ansible's ansible.builtin.cron module
  #
  # Parameters:
  #   name (required): Unique identifier for the entry - stored as a
  #     "#Ansible: <name>" comment marker so the entry can be found again.
  #     With env: true this is instead the NAME of a crontab environment
  #     variable (see env below).
  #   job (required unless state: absent): The command to run. With
  #     env: true, the variable's VALUE instead.
  #   minute/hour/day/month/weekday (optional, default "*")
  #   special_time (optional): reboot/yearly/annually/monthly/weekly/daily/hourly
  #     - overrides minute/hour/day/month/weekday
  #   state (optional): present (default) or absent
  #   disabled (optional): comment the entry out instead of removing it
  #   env (optional, default false): manage a crontab ENVIRONMENT VARIABLE
  #     line instead of a scheduled job - writes `NAME="value"` (job is the
  #     value), with no marker comment. A NEW variable defaults to the TOP
  #     of the crontab (real cron.py's add_env), insertafter/insertbefore
  #     position it relative to another declared variable (naming a
  #     nonexistent one is a hard failure, "Variable named '%s' not
  #     found.", unlike real cronvar's silent drop), and a name containing
  #     a space is rejected ("Invalid name for environment variable").
  #   insertafter/insertbefore (optional, mutually exclusive; env: yes
  #     and state: present only - real cron.py fails with "Insertafter
  #     and insertbefore parameters are valid only with env=yes"
  #     otherwise): position a NEW env variable relative to the named
  #     existing one.
  #   backup (optional, default false): before modifying the crontab,
  #     save a copy to a "/tmp/crontabXXXXXXXX" file (real cron.py's
  #     tempfile.mkstemp(prefix='crontab') convention, 0600 perms) and
  #     report its path as `backup_file` in the result - only when
  #     something actually changed (real module deletes the backup
  #     otherwise). Never taken in check mode.
  #   user (optional): included as a field in the entry line when
  #     cron_file: is given (cron.d style); when cron_file: is omitted,
  #     selects WHICH user's live crontab to edit instead (`crontab -u
  #     <user>`) and is NOT itself part of the rendered line (a user's
  #     own personal crontab has no user column) - defaults to whatever
  #     user this plugin process is already running as.
  #   cron_file (optional): path to a crontab-style file under
  #     /etc/cron.d to manage instead of a live user crontab - real
  #     Ansible's own default (this param omitted) edits the live
  #     crontab via the `crontab` command.
  #
  # Real bug found benchmarking geerlingguy.certbot's own "Add cron job
  # for certbot renewal" task, which uses exactly the default (no
  # cron_file:) form - this was a documented, deliberate scope cut
  # ("editing this process's real login crontab as a side effect of an
  # automated test run is not something tests here are willing to
  # risk"), narrower than it needed to be: the risk is real for THIS
  # process's own crontab specifically, not for managing an arbitrary
  # target user's crontab via `crontab -u`, which is exactly what this
  # module needs to do when actually deployed. Implemented by shelling
  # out to `crontab -u <user> -l`/`crontab -u <user> <tmpfile>` (same
  # PluginHelpers::CronTable upsert logic the cron_file: path already
  # uses) rather than adding a live-crontab spec that could still
  # corrupt whoever runs this test suite's own real crontab.
  class CronPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      env = true?(@params["env"]?)
      insertafter = @params["insertafter"]?
      insertbefore = @params["insertbefore"]?
      if insertafter && insertbefore
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: insertafter|insertbefore")
      end

      state = @params["state"]? || "present"
      job = @params["job"]?

      if failure = validate_present_params(state, job, env, insertafter, insertbefore)
        return failure
      end

      if env && name.includes?(" ")
        return PluginResult.new(changed: false, failed: true, msg: "Invalid name for environment variable")
      end

      cron_file = @params["cron_file"]?
      if env
        cron_file ? execute_env_file(cron_file, name, job, state, insertafter, insertbefore) : execute_env_user_crontab(name, job, state, insertafter, insertbefore)
      else
        cron_file ? execute_file(name, cron_file) : execute_user_crontab(name)
      end
    end

    # Shared state=present validation (job required; insertafter/
    # insertbefore are env-only). Returns the failure result, or nil.
    private def validate_present_params(state : String, job : String?, env : Bool, insertafter : String?, insertbefore : String?) : PluginResult?
      return nil unless state == "present"
      return PluginResult.new(changed: false, failed: true, msg: "job parameter required when state=present") unless job
      if (insertafter || insertbefore) && !env
        return PluginResult.new(changed: false, failed: true, msg: "Insertafter and insertbefore parameters are valid only with env=yes")
      end
      nil
    end

    private def execute_file(name : String, raw_cron_file : String) : PluginResult
      # Real Ansible resolves a relative cron_file: against /etc/cron.d -
      # only an absolute path is used as-is (cron.py's CronTab#__init__).
      cron_file = resolve_cron_file(raw_cron_file)
      state = @params["state"]? || "present"
      job = @params["job"]?

      new_line = state == "present" ? build_line(job || "", include_user: true) : nil

      check_mode = true?(@params["check_mode"]?)

      original_content = File.exists?(cron_file) ? File.read(cron_file) : ""
      new_content, changed = PluginHelpers::CronTable.upsert(original_content, name, new_line)

      backup_file, failure = persist_file(cron_file, original_content, new_content, changed, check_mode)
      return failure if failure

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Cron entry #{state == "present" ? "added/updated" : "removed"}" : "Cron entry already up to date",
        name: name,
        cron_file: cron_file,
        state: state
      )
      report_backup(result, backup_file)
    end

    private def execute_user_crontab(name : String) : PluginResult
      state = @params["state"]? || "present"
      job = @params["job"]?
      target_user = @params["user"]?
      crontab_target = target_user ? "-u #{shell_single_quote(target_user)}" : ""

      new_line = state == "present" ? build_line(job || "", include_user: false) : nil

      check_mode = true?(@params["check_mode"]?)

      # A user with no crontab yet makes `crontab -l` exit non-zero
      # ("no crontab for <user>") - not a real error, just "start from
      # empty" (matches real Ansible's own CronTab.read behavior).
      list_result = remote_exec("crontab #{crontab_target} -l 2>/dev/null")
      original_content = list_result[:exit_code] == 0 ? list_result[:stdout] : ""

      new_content, changed = PluginHelpers::CronTable.upsert(original_content, name, new_line)

      backup_file, failure = persist_user_crontab(crontab_target, original_content, new_content, changed, check_mode)
      return failure if failure

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Cron entry #{state == "present" ? "added/updated" : "removed"}" : "Cron entry already up to date",
        name: name,
        state: state
      )
      report_backup(result, backup_file)
    end

    private def execute_env_file(raw_cron_file : String, name : String, job : String?, state : String, insertafter : String?, insertbefore : String?) : PluginResult
      cron_file = resolve_cron_file(raw_cron_file)
      check_mode = true?(@params["check_mode"]?)

      original_content = File.exists?(cron_file) ? File.read(cron_file) : ""
      new_content, changed, missing_target = PluginHelpers::CronTable.upsert_env(
        original_content, name, env_decl(name, job, state), insertafter, insertbefore
      )
      return missing_insert_target(missing_target) if missing_target

      backup_file, failure = persist_file(cron_file, original_content, new_content, changed, check_mode)
      return failure if failure

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Cron environment variable #{state == "present" ? "added/updated" : "removed"}" : "Cron environment variable already up to date",
        name: name,
        cron_file: cron_file,
        state: state
      )
      report_backup(result, backup_file)
    end

    private def execute_env_user_crontab(name : String, job : String?, state : String, insertafter : String?, insertbefore : String?) : PluginResult
      target_user = @params["user"]?
      crontab_target = target_user ? "-u #{shell_single_quote(target_user)}" : ""
      check_mode = true?(@params["check_mode"]?)

      list_result = remote_exec("crontab #{crontab_target} -l 2>/dev/null")
      original_content = list_result[:exit_code] == 0 ? list_result[:stdout] : ""

      new_content, changed, missing_target = PluginHelpers::CronTable.upsert_env(
        original_content, name, env_decl(name, job, state), insertafter, insertbefore
      )
      return missing_insert_target(missing_target) if missing_target

      backup_file, failure = persist_user_crontab(crontab_target, original_content, new_content, changed, check_mode)
      return failure if failure

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Cron environment variable #{state == "present" ? "added/updated" : "removed"}" : "Cron environment variable already up to date",
        name: name,
        state: state
      )
      report_backup(result, backup_file)
    end

    # Applies a computed change to a cron.d-style file: backup first
    # (backup: true), then write. Returns {backup_file, failure}.
    private def persist_file(path : String, original_content : String, new_content : String, changed : Bool, check_mode : Bool) : {String?, PluginResult?}
      return {nil, nil} if !changed || check_mode

      backup_file = should_backup? ? write_backup(original_content) : nil
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(path, new_content)
      {backup_file, nil}
    end

    # Applies a computed change to a live user crontab: backup first
    # (backup: true), then install. Returns {backup_file, failure}.
    private def persist_user_crontab(crontab_target : String, original_content : String, new_content : String, changed : Bool, check_mode : Bool) : {String?, PluginResult?}
      return {nil, nil} if !changed || check_mode

      backup_file = should_backup? ? write_backup(original_content) : nil
      failure = install_user_crontab(crontab_target, new_content)
      return {backup_file, failure} if failure
      {backup_file, nil}
    end

    private def resolve_cron_file(raw_cron_file : String) : String
      raw_cron_file.starts_with?("/") ? raw_cron_file : File.join("/etc/cron.d", raw_cron_file)
    end

    # env: true renders NAME="value" (state: absent needs no decl, hence
    # the nilable job and return). Callers only ask for a decl when
    # execute's validation already established job is present.
    private def env_decl(name : String, job : String?, state : String) : String?
      return nil unless state == "present"
      PluginHelpers::CronTable.env_decl(name, job || "")
    end

    private def missing_insert_target(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Variable named '#{name}' not found.")
    end

    # Install the updated crontab via a tmp file. Returns the failure
    # result when `crontab` rejects it, nil on success.
    private def install_user_crontab(crontab_target : String, new_content : String) : PluginResult?
      # Random::Secure (not Random.rand): the predictable numeric suffix
      # let any local user pre-create/symlink the path and get root to
      # write through it. Same class of fix copy.cr already made.
      tmp_path = "/tmp/.krikri-playbook-crontab-#{Random::Secure.hex(8)}"
      begin
        # CronTable.upsert already appends its own single trailing "\n"
        # to a non-empty new_content - adding another here produced a
        # blank line at the end of the installed crontab, which
        # `crontab -l` then read back verbatim, making the very next
        # run's own upsert see a "changed" diff against itself
        # forever (never converging to idempotent).
        File.write(tmp_path, new_content.empty? ? "\n" : new_content)
        File.chmod(tmp_path, 0o600)
        install_result = remote_exec("crontab #{crontab_target} #{shell_single_quote(tmp_path)}")
        unless install_result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "crontab install failed: #{install_result[:stderr]}")
        end
      ensure
        File.delete(tmp_path) rescue nil
      end

      nil
    end

    private def should_backup? : Bool
      true?(@params["backup"]?)
    end

    # Real cron.py's backup convention: tempfile.mkstemp(prefix='crontab')
    # - a "/tmp/crontabXXXXXXXX" path, created 0600 - written with the
    # pre-modification crontab content and reported as `backup_file`,
    # but only retained when something actually changed (the module
    # deletes the backup itself when nothing did, so only creating it on
    # a real change is observably identical).
    private def write_backup(content : String) : String
      backup_file = File.join("/tmp", "crontab#{Random::Secure.hex(4)}")
      File.write(backup_file, content)
      File.chmod(backup_file, 0o600)
      backup_file
    end

    private def report_backup(result : PluginResult, backup_file : String?) : PluginResult
      result.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      result
    end

    private def build_line(job : String, include_user : Bool) : String
      schedule = PluginHelpers::CronTable.schedule(
        @params["minute"]? || "*",
        @params["hour"]? || "*",
        @params["day"]? || "*",
        @params["month"]? || "*",
        @params["weekday"]? || "*",
        @params["special_time"]?
      )

      PluginHelpers::CronTable.render_line(schedule, job, include_user ? @params["user"]? : nil, true?(@params["disabled"]?))
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::CronPlugin.new(config)
plugin.run
