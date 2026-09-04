#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/cron_var"

module Krikri
  # Cronvar plugin - manages a named environment-variable assignment
  # (NAME=value line) in a crontab-style file
  # Compatible with (a subset of) Ansible's ansible.builtin.cronvar module
  #
  # Parameters:
  #   name (required): Variable name (exact, case-sensitive token match -
  #     `FOO` matches `FOO=bar` but not `FOOBAR=baz`)
  #   value: The value to set (required unless state: absent)
  #   state: present (default) or absent
  #   cron_file (optional): path to a crontab-style file; a relative
  #     path resolves against /etc/cron.d (real CronVar.__init__). When
  #     omitted, edits a live user crontab via the `crontab` command.
  #   user (optional): which user's live crontab to edit via
  #     `crontab -u <user>` (only meaningful without cron_file:; a
  #     cron.d variable file has no user column)
  #   insertafter / insertbefore (optional, mutually exclusive): position
  #     a NEW variable relative to the named existing one; like the real
  #     module, naming a nonexistent variable silently drops the insert
  #     (while still reporting changed - real cronvar's own quirk)
  #   backup (optional): write a timestamped backup before changing
  #
  # Unlike the real module (supports_check_mode=False, so real Ansible
  # skips the task under --check), this plugin honors check_mode by
  # computing the would-be result without writing - consistent with
  # every other check_mode-aware plugin here, and strictly safer than
  # real cronvar's "run it for real or skip" behavior.
  #
  # Deliberately NOT supported: the real module always writes via the
  # `crontab` binary even for cron_file: targets whose parent directory
  # must already exist (community.general's added parent-dir check);
  # here a missing parent directory is created, matching cron.cr.
  class CronVarPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      state = @params["state"]? || "present"
      value = @params["value"]?

      if state == "present" && !value
        return PluginResult.new(changed: false, failed: true, msg: "You must specify 'value' to insert a new cron variable")
      end

      insertafter = @params["insertafter"]?
      insertbefore = @params["insertbefore"]?
      if insertafter && insertbefore
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: (insertbefore|insertafter)")
      end

      check_mode = true?(@params["check_mode"]?)

      cron_file = @params["cron_file"]?
      cron_file ? execute_file(cron_file, name, value, state, insertbefore, insertafter, check_mode) : execute_user_crontab(name, value, state, insertbefore, insertafter, check_mode)
    end

    private def execute_file(raw_cron_file : String, name : String, value : String?, state : String, insert_before : String?, insert_after : String?, check_mode : Bool) : PluginResult
      # Real Ansible resolves a relative cron_file: against /etc/cron.d -
      # only an absolute path is used as-is (CronVar.__init__).
      path = raw_cron_file.starts_with?("/") ? raw_cron_file : File.join("/etc/cron.d", raw_cron_file)

      original_content = File.exists?(path) ? File.read(path) : ""
      new_content, changed = PluginHelpers::CronVar.upsert(original_content, name, state == "absent" ? nil : value, insert_before, insert_after)

      backup_file = ""
      if changed && !check_mode
        backup_file = write_backup(path) if should_backup?(path)
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, new_content)
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: change_msg(changed),
        name: name,
        vars: PluginHelpers::CronVar.var_names(new_content),
        cron_file: path,
        backup_file: backup_file
      )
    end

    private def execute_user_crontab(name : String, value : String?, state : String, insert_before : String?, insert_after : String?, check_mode : Bool) : PluginResult
      target_user = @params["user"]?
      crontab_target = target_user ? "-u #{target_user}" : ""

      # A user with no crontab yet makes `crontab -l` exit non-zero
      # ("no crontab for <user>") - not a real error, just "start from
      # empty" (same as cron.cr / real Ansible's CronTab.read).
      list_result = remote_exec("crontab #{crontab_target} -l 2>/dev/null")
      original_content = list_result[:exit_code] == 0 ? list_result[:stdout] : ""

      new_content, changed = PluginHelpers::CronVar.upsert(original_content, name, state == "absent" ? nil : value, insert_before, insert_after)

      if changed && !check_mode
        failure = install_user_crontab(crontab_target, new_content)
        return failure if failure
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: change_msg(changed),
        name: name,
        vars: PluginHelpers::CronVar.var_names(new_content),
        state: state
      )
    end

    # Install the updated crontab via a tmp file. Returns the failure
    # result when `crontab` rejects it, nil on success.
    private def install_user_crontab(crontab_target : String, new_content : String) : PluginResult?
      tmp_path = "/tmp/.krikri-playbook-crontab-#{Random.rand(100000..999999)}"
      begin
        File.write(tmp_path, new_content.empty? ? "\n" : new_content)
        install_result = remote_exec("crontab #{crontab_target} #{tmp_path}")
        unless install_result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "crontab install failed: #{install_result[:stderr]}")
        end
      ensure
        File.delete(tmp_path) rescue nil
      end

      nil
    end

    private def should_backup?(path : String) : Bool
      true?(@params["backup"]?) && File.exists?(path)
    end

    private def write_backup(path : String) : String
      timestamp = Time.local.to_s("%Y%m%d-%H%M%S")
      backup_file = "#{path}.#{timestamp}.bak"
      File.copy(path, backup_file)
      backup_file
    end

    private def change_msg(changed : Bool) : String
      changed ? "Cron variable added/updated/removed" : "Cron variable already up to date"
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::CronVarPlugin.new(config)
plugin.run
