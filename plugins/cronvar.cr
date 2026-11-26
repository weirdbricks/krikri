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
  # Real cronvar passes no supports_check_mode=True to its AnsibleModule,
  # so basic.py's __init__ gate skips it under --check (see #execute).
  # This plugin used to compute the would-be result without writing
  # instead, which turned a skipped task into an ok one and flipped any
  # following `when: r is not skipped` from skipped into a run.
  class CronVarPlugin < BasePlugin
    # argument_spec's `state` choices, in the Ansible module's order (the
    # wording "value of state must be one of: absent, present, got: X"
    # is ansible-core's own choices error, not a cronvar-specific one).
    STATE_CHOICES = ["absent", "present"]

    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      state = @params["state"]? || "present"
      value = @params["value"]?

      # Ansible validates in argument-spec order: mutually_exclusive
      # first (arg_spec.py), then the per-parameter type/choices checks
      # (parameters.py), and only then the module's own body checks
      # ("You must specify 'value'..."). Verified live against
      # ansible-core 2.19.11: insertbefore+insertafter beats a bogus
      # state, a bogus state beats a missing cron_file parent dir.
      insertafter = @params["insertafter"]?
      insertbefore = @params["insertbefore"]?
      if insertafter && insertbefore
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: insertbefore|insertafter")
      end

      unless STATE_CHOICES.includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: #{STATE_CHOICES.join(", ")}, got: #{state}")
      end

      # basic.py's gate sits AFTER argument-spec validation (so a bogus
      # state still fails above) but BEFORE CronVar.__init__'s
      # parent-directory guard and main()'s "You must specify 'value'"
      # check - live-verified vs 2.21.6: under --check both of those
      # answer with this skip instead. The registered result comes out
      # changed, failed, skipped, msg on both engines (the controller
      # backfills changed/failed ahead of the skip text).
      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "community.general.cronvar"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true,
          omit_changed: true, key_order: ["skipped", "msg"])
      end

      # Real CronVar.__init__ resolves cron_file (absolute as-is, relative
      # against /etc/cron.d) and fails when its parent directory is not
      # one - a check that runs inside the constructor, i.e. BEFORE
      # main()'s own "You must specify 'value'" check and before anything
      # is written. This plugin used to CREATE the missing parent
      # directory instead (cron.cr's behavior), which silently diverged
      # on every cron_file under a nonexistent directory.
      cron_file = @params["cron_file"]?
      if failure = missing_parent_failure(cron_file)
        return failure
      end

      if state == "present" && !value
        return PluginResult.new(changed: false, failed: true, msg: "You must specify 'value' to insert a new cron variable")
      end

      cron_file ? execute_file(cron_file, name, value, state, insertbefore, insertafter) : execute_user_crontab(name, value, state, insertbefore, insertafter)
    end

    # Real CronVar.__init__'s parent-directory guard, or nil when the
    # cron_file's parent is a directory (or there is no cron_file at all).
    private def missing_parent_failure(cron_file : String?) : PluginResult?
      return nil unless cron_file
      resolved = cron_file.starts_with?("/") ? cron_file : File.join("/etc/cron.d", cron_file)
      parent = File.dirname(resolved)
      return nil if parent.empty? || File.directory?(parent)

      PluginResult.new(changed: false, failed: true,
        msg: "Parent directory '#{parent}' does not exist for cron_file: '#{cron_file}'")
    end

    private def execute_file(raw_cron_file : String, name : String, value : String?, state : String, insert_before : String?, insert_after : String?) : PluginResult
      # Ansible resolves a relative cron_file: against /etc/cron.d -
      # only an absolute path is used as-is (CronVar.__init__).
      path = raw_cron_file.starts_with?("/") ? raw_cron_file : File.join("/etc/cron.d", raw_cron_file)

      original_content = File.exists?(path) ? File.read(path) : ""
      new_content, changed = PluginHelpers::CronVar.upsert(original_content, name, state == "absent" ? nil : value, insert_before, insert_after)

      backup_file = ""
      if changed
        backup_file = write_backup(path) if should_backup?(path)
        if failure = write_file_failure(path, new_content)
          return failure
        end
      end

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: change_msg(changed),
        name: name,
        vars: PluginHelpers::CronVar.var_names(new_content),
        cron_file: path,
        # Ansible 2.19.11 registered cronvar result (live-verified, changed
        # and unchanged identical): vars, changed, failed.
        key_order: ["vars", "changed"]
      )
      # Ansible module includes backup_file only when a backup was actually
      # retained (changed && backup; its None default is dropped by
      # exit_json).
      result.extra["backup_file"] = JSON::Any.new(backup_file) unless backup_file.empty?
      result
    end

    private def execute_user_crontab(name : String, value : String?, state : String, insert_before : String?, insert_after : String?) : PluginResult
      target_user = @params["user"]?
      crontab_target = target_user ? "-u #{target_user}" : ""

      # A user with no crontab yet makes `crontab -l` exit non-zero
      # ("no crontab for <user>") - not a real error, just "start from
      # empty" (same as cron.cr / Ansible's CronTab.read).
      list_result = remote_exec("crontab #{crontab_target} -l 2>/dev/null")
      original_content = list_result[:exit_code] == 0 ? list_result[:stdout] : ""

      new_content, changed = PluginHelpers::CronVar.upsert(original_content, name, state == "absent" ? nil : value, insert_before, insert_after)

      if changed
        failure = install_user_crontab(crontab_target, new_content)
        return failure if failure
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: change_msg(changed),
        name: name,
        vars: PluginHelpers::CronVar.var_names(new_content),
        state: state,
        key_order: ["vars", "changed"]
      )
    end

    # Install the updated crontab via a tmp file. Returns the failure
    # result when `crontab` rejects it, nil on success.
    private def install_user_crontab(crontab_target : String, new_content : String) : PluginResult?
      tmp_path = create_crontab_tmpfile(new_content)
      begin
        install_result = remote_exec("crontab #{crontab_target} #{tmp_path}")
        unless install_result[:exit_code] == 0
          # Real CronVar.write() hands `crontab`'s stderr straight to
          # fail_json(msg=err) - verbatim, trailing newline and all, with
          # no prefix of its own.
          return PluginResult.new(changed: false, failed: true, msg: install_result[:stderr])
        end
      ensure
        File.delete(tmp_path) rescue nil
      end

      nil
    end

    # Real CronVar.write() stages the new crontab through
    # tempfile.mkstemp(prefix="crontab"): "/tmp/crontab" plus eight random
    # characters, mode 0600, created exclusively. The installer stamps
    # that path AND the wall clock into the crontab file's own
    # "# (/tmp/crontabXXXXXXXX installed on ...)" header, so the name's
    # 20-character shape is part of what lands on the host - a longer
    # ".krikri-playbook-crontab-" File.tempfile name left krikri a
    # 213-byte crontab where Ansible leaves 194 (kpg cronvar chaos #22,
    # issue #1854). O_EXCL keeps File.tempfile's guarantee that a path
    # planted in /tmp cannot be followed.
    #
    # An empty crontab is written as an EMPTY file, not a literal "\n":
    # real render() returns "" when the insert target never matched or
    # the last variable was removed, `crontab <empty-file>` installs that
    # fine, and a newline instead becomes a body line `crontab -l` lists
    # back - the same bug cron.cr's own installer fixed for state=absent.
    private def create_crontab_tmpfile(content : String) : String
      chars = "abcdefghijklmnopqrstuvwxyz0123456789_"
      10.times do
        name = String.build(15) do |builder|
          builder << "crontab"
          8.times { builder << chars[Random::Secure.rand(chars.size)] }
        end
        candidate = File.join("/tmp", name)
        fd = LibC.open(candidate, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        next if fd == -1
        LibC.close(fd)
        File.write(candidate, content)
        return candidate
      end
      raise "unable to create a temporary crontab file in /tmp"
    end

    private def should_backup?(path : String) : Bool
      true?(@params["backup"]?) && File.exists?(path)
    end

    # Real CronVar.write() opens the cron file with a bare
    # `open(self.cron_file, "w")` - no try/except - so a file it may not
    # write (a cron.d target the module does not own) ends the module with
    # an UNCAUGHT OSError, which the controller reports under the generic
    # "Task failed: Module failed: " brief with the errno text.
    private def write_file_failure(path : String, content : String) : PluginResult?
      File.write(path, content)
      nil
    rescue ex : File::Error
      message = ex.message || ""
      errno_text = if ex.is_a?(File::AccessDeniedError)
                     "[Errno 13] Permission denied: '#{path}'"
                   elsif message.includes?("Not a directory")
                     "[Errno 20] Not a directory: '#{path}'"
                   elsif message.includes?("Is a directory")
                     "[Errno 21] Is a directory: '#{path}'"
                   else
                     "[Errno 2] No such file or directory: '#{path}'"
                   end
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{errno_text}", _ansible_error_detail: errno_text)
    end

    private def write_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
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
