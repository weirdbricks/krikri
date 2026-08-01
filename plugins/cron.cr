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
  #   user (optional): included as a field in the entry line (cron.d style)
  #   cron_file (required): path to the crontab-style file to manage.
  #
  # This intentionally does NOT manage a live user crontab via the
  # `crontab` command (Ansible's default when cron_file: is omitted) -
  # only file-based management (cron_file:, matching Ansible's /etc/cron.d
  # style) is implemented, since editing this process's real login
  # crontab as a side effect of an automated test run is not something
  # tests here are willing to risk.
  class CronPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      cron_file = @params["cron_file"]?
      return missing_param("cron_file") unless cron_file

      state = @params["state"]? || "present"
      job = @params["job"]?

      new_line = if state == "present"
                   return PluginResult.new(changed: false, failed: true, msg: "job parameter required when state=present") unless job
                   build_line(job)
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

    private def build_line(job : String) : String
      schedule = PluginHelpers::CronTable.schedule(
        @params["minute"]? || "*",
        @params["hour"]? || "*",
        @params["day"]? || "*",
        @params["month"]? || "*",
        @params["weekday"]? || "*",
        @params["special_time"]?
      )

      PluginHelpers::CronTable.render_line(schedule, job, @params["user"]?, is_true?(@params["disabled"]?))
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
