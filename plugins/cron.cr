#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/cron_table"

module CrystalPlay
  # Cron plugin - manages a named entry in a crontab-style file
  # Compatible with (a subset of) Ansible's ansible.builtin.cron module
  #
  # Parameters:
  #   name (required): Unique identifier for the entry - stored as a
  #     "#Ansible: <name>" comment marker so the entry can be found again
  #   job (required unless state: absent): The command to run
  #   minute/hour/day/month/weekday (optional, default "*")
  #   special_time (optional): reboot/yearly/annually/monthly/weekly/daily/hourly
  #     - overrides minute/hour/day/month/weekday
  #   state (optional): present (default) or absent
  #   disabled (optional): comment the entry out instead of removing it
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

      cron_file = @params["cron_file"]?
      cron_file ? execute_file(name, cron_file) : execute_user_crontab(name)
    end

    private def execute_file(name : String, raw_cron_file : String) : PluginResult
      # Real Ansible resolves a relative cron_file: against /etc/cron.d -
      # only an absolute path is used as-is (cron.py's CronTab#__init__).
      cron_file = raw_cron_file.starts_with?("/") ? raw_cron_file : File.join("/etc/cron.d", raw_cron_file)
      state = @params["state"]? || "present"
      job = @params["job"]?

      new_line = if state == "present"
                   return PluginResult.new(changed: false, failed: true, msg: "job parameter required when state=present") unless job
                   build_line(job, include_user: true)
                 end

      check_mode = is_true?(@params["check_mode"]?)

      original_content = File.exists?(cron_file) ? File.read(cron_file) : ""
      new_content, changed = PluginHelpers::CronTable.upsert(original_content, name, new_line)

      if changed && !check_mode
        dir = File.dirname(cron_file)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(cron_file, new_content)
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Cron entry #{state == "present" ? "added/updated" : "removed"}" : "Cron entry already up to date",
        name: name,
        cron_file: cron_file,
        state: state
      )
    end

    private def execute_user_crontab(name : String) : PluginResult
      state = @params["state"]? || "present"
      job = @params["job"]?
      target_user = @params["user"]?
      crontab_target = target_user ? "-u #{target_user}" : ""

      new_line = if state == "present"
                   return PluginResult.new(changed: false, failed: true, msg: "job parameter required when state=present") unless job
                   build_line(job, include_user: false)
                 end

      check_mode = is_true?(@params["check_mode"]?)

      # A user with no crontab yet makes `crontab -l` exit non-zero
      # ("no crontab for <user>") - not a real error, just "start from
      # empty" (matches real Ansible's own CronTab.read behavior).
      list_result = remote_exec("crontab #{crontab_target} -l 2>/dev/null")
      original_content = list_result[:exit_code] == 0 ? list_result[:stdout] : ""

      new_content, changed = PluginHelpers::CronTable.upsert(original_content, name, new_line)

      if changed && !check_mode
        tmp_path = "/tmp/.crystal-ansible-crontab-#{Random.rand(100000..999999)}"
        begin
          # CronTable.upsert already appends its own single trailing "\n"
          # to a non-empty new_content - adding another here produced a
          # blank line at the end of the installed crontab, which
          # `crontab -l` then read back verbatim, making the very next
          # run's own upsert see a "changed" diff against itself
          # forever (never converging to idempotent).
          File.write(tmp_path, new_content.empty? ? "\n" : new_content)
          install_result = remote_exec("crontab #{crontab_target} #{tmp_path}")
          unless install_result[:exit_code] == 0
            return PluginResult.new(changed: false, failed: true, msg: "crontab install failed: #{install_result[:stderr]}")
          end
        ensure
          File.delete(tmp_path) rescue nil
        end
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Cron entry #{state == "present" ? "added/updated" : "removed"}" : "Cron entry already up to date",
        name: name,
        state: state
      )
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

      PluginHelpers::CronTable.render_line(schedule, job, include_user ? @params["user"]? : nil, is_true?(@params["disabled"]?))
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::CronPlugin.new(config)
plugin.run
