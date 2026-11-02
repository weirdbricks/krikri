#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/dpkg_divert_command"
require "../src/krikri/plugin_helpers/run_command_failure"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  # dpkg_divert plugin - manages Debian dpkg file diversions via the
  # dpkg-divert tool, a native reimplementation of community.general.dpkg_divert
  # (read from a live collection install; Debian/Ubuntu is a supported
  # platform here).
  #
  # Follows the Ansible module's control flow:
  #   - `dpkg-divert --listpackage <path>` / `--truename <path>` read
  #     the current diversion (holder + diverted location); empty
  #     listpackage output == no diversion
  #   - state=present adds (or updates holder/divert), state=absent
  #     removes; updating an existing diversion's holder/divert is not
  #     something dpkg-divert can do in place, so the Ansible module
  #     removes and re-adds - ported as-is, including its
  #     avoid-orphaned-files rename of the diverted file
  #   - rename: true hands --rename to dpkg-divert; the Ansible module's
  #     own "forced renaming" fallback (unlinking the blocker, since
  #     dpkg-divert refuses to clobber) is matched too
  #   - check mode and the Ansible module's "just try and see" probe run
  #     the same command with --test inserted
  #
  # Portability note: --listpackage exists since dpkg 1.15.0 and
  # --no-rename since 1.19.1 - the Ansible module probes --version for
  # both; the version probe is kept (same failure message) but the
  # --no-rename support flag is hardcoded true: every dpkg since 2019
  # has it, same reasoning as lvol's --yes shortcut.
  class DpkgDivertPlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required argument: path") unless path

      state = @params["state"]? || "present"
      return PluginResult.new(changed: false, failed: true,
        msg: "state must be 'present' or 'absent', got '#{state}'") unless ["present", "absent"].includes?(state)

      rename = true?(@params["rename"]?)
      force = true?(@params["force"]?)
      holder = @params["holder"]?
      divert_param = @params["divert"]?

      # Real resolves dpkg-divert through get_bin_path(required=True) at
      # the top of main(), before anything shells out - a host without
      # the binary fails there, not with the version probe's wording.
      # The resolved path is also what the real module records: the
      # `commands` result carries it, and a run_command(check_rc=True)
      # failure reports it in cmd.
      dpkg_divert = find_required_binary("dpkg-divert")
      return PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::GetBinPath.missing_executable_error("dpkg-divert", @bin_searched_paths)) unless dpkg_divert

      version_result = remote_exec(PluginHelpers::DpkgDivertCommand.version_command(dpkg_divert))
      unless version_result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Unsupported dpkg version (<1.15.0).")
      end

      path_exists = remote_file_exists?(path)

      diversion_before = diversion_state(path, dpkg_divert)
      return diversion_before if diversion_before.is_a?(PluginResult)
      truename_exists = diversion_before["divert"] ? remote_file_exists?(diversion_before["divert"].not_nil!) : false

      options = PluginHelpers::DpkgDivertCommand::Options.new(
        state: state, holder: holder, divert: divert_param, rename: rename, force: force
      )
      main_command = PluginHelpers::DpkgDivertCommand.main_command(options, dpkg_divert, path)

      diversion_wanted : Hash(String, String?) = {
        "path" => path, "state" => state, "divert" => nil, "holder" => nil,
      }
      if state == "present"
        diversion_wanted["holder"] = (holder && holder != "LOCAL") ? holder : "LOCAL"
        diversion_wanted["divert"] = divert_param || "#{path}.distrib"
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      unchanged = diversion_wanted == diversion_before
      run_command = check_mode || unchanged ? PluginHelpers::DpkgDivertCommand.with_test(main_command) : main_command

      rc, stdout, stderr = exec_split(run_command)
      messages = [stdout.strip]

      if rc != 0
        if state != diversion_before["state"]
          # renaming conflict path: only legitimate blocker is the file
          # rename dpkg-divert refuses when both source and target exist
          blocker = state == "absent" ? diversion_before["divert"] : diversion_wanted["divert"]
          if rename && path_exists && ((state == "absent" && truename_exists) || (state == "present" && remote_file_exists?(blocker || "")))
            unless force
              return PluginResult.new(changed: false, failed: true,
                msg: "Set 'force' param to True to force renaming of files.", stderr: stderr, stdout: stdout)
            end
          else
            return PluginResult.new(changed: false, failed: true,
              msg: "Unexpected error while changing state of the diversion.", stderr: stderr, stdout: stdout)
          end

          if check_mode
            return PluginResult.new(changed: false, failed: true,
              msg: "Unexpected error while changing state of the diversion.", stderr: stderr, stdout: stdout)
          end

          unlink_result = remote_exec("rm -f #{shell_single_quote(blocker || "")}")
          if unlink_result[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Failed to remove #{blocker}: #{unlink_result[:stderr]}")
          end
          rerun = remote_exec(main_command)
          return failed_result("dpkg-divert failed: #{rerun[:stderr]}") if rerun[:exit_code] != 0
          messages = [rerun[:stdout].strip]
        else
          # updating holder/divert of an existing diversion: dpkg-divert
          # cannot do that in place - remove, then re-add
          rm_command = PluginHelpers::DpkgDivertCommand.remove_command(dpkg_divert, path)
          rm_command = PluginHelpers::DpkgDivertCommand.with_test(rm_command) if check_mode
          rm_result = remote_exec(rm_command)
          return failed_result("dpkg-divert failed: #{rm_result[:stderr]}") if rm_result[:exit_code] != 0

          if check_mode
            messages = [rm_result[:stdout].strip, "Running in check mode"]
          else
            rerun = remote_exec(main_command)
            return failed_result("dpkg-divert failed: #{rerun[:stderr]}") if rerun[:exit_code] != 0
            messages = [rm_result[:stdout].strip, rerun[:stdout].strip]

            old_divert = diversion_before["divert"]?
            new_divert = diversion_wanted["divert"]?
            if new_divert != old_divert && old_divert && new_divert &&
               remote_file_exists?(old_divert) && !remote_file_exists?(new_divert)
              remote_exec("mv #{shell_single_quote(old_divert)} #{shell_single_quote(new_divert)}")
            end
          end
        end
      end

      diversion_after = check_mode ? diversion_wanted : diversion_state(path, dpkg_divert)
      return diversion_after if diversion_after.is_a?(PluginResult)
      changed = diversion_after != diversion_before

      if diversion_after == diversion_wanted
        # Real dpkg_divert.py's success exit:
        # module.exit_json(changed=changed, diversion=diversion,
        # commands=commands, messages=messages, diff=diff) - no msg on
        # the success path (diff is {} outside --diff mode; live-verified
        # against Ansible 2.19.11 in the podman container).
        PluginResult.new(changed: changed, failed: false,
          diversion: diversion_after, commands: [main_command], messages: messages,
          key_order: ["changed", "diversion", "commands", "messages", "diff"])
      else
        PluginResult.new(changed: changed, failed: true,
          msg: "Unexpected error: see stdout and stderr for details.")
      end
    end

    # {"path" => ..., "state" => ..., "holder" => ...?, "divert" => ...?}
    # A PluginResult return is the real module's diversion_state lookup
    # failing under run_command(check_rc=True): a non-zero --listpackage
    # or --truename exit (dpkg-divert's own usage error, e.g. a relative
    # path like `80`) fails the module RIGHT THERE with run_command's
    # failure shape - msg is the bare stderr, cmd names the resolved
    # binary - and the main command below never runs. Swallowing the
    # failure here (the old behavior) sent a non-absolute path into the
    # main command's "Unexpected error while changing state of the
    # diversion." branch instead (issue #748).
    private def diversion_state(path : String, dpkg_divert : String) : Hash(String, String?) | PluginResult
      diversion : Hash(String, String?) = {
        "path" => path, "state" => "absent", "divert" => nil, "holder" => nil,
      }

      list_command = PluginHelpers::DpkgDivertCommand.listpackage_command(dpkg_divert, path)
      list_result = remote_exec(list_command)
      unless list_result[:exit_code] == 0
        return PluginHelpers::RunCommandFailure.nonzero_exit(
          list_command, list_result[:exit_code], list_result[:stdout], list_result[:stderr])
      end
      holder = list_result[:stdout].strip
      unless holder.empty?
        diversion["state"] = "present"
        diversion["holder"] = holder
        truename_command = PluginHelpers::DpkgDivertCommand.truename_command(dpkg_divert, path)
        truename = remote_exec(truename_command)
        unless truename[:exit_code] == 0
          return PluginHelpers::RunCommandFailure.nonzero_exit(
            truename_command, truename[:exit_code], truename[:stdout], truename[:stderr])
        end
        diversion["divert"] = truename[:stdout].strip
      end
      diversion
    end

    private def exec_split(command : String) : {Int32, String, String}
      result = remote_exec(command)
      {result[:exit_code], result[:stdout], result[:stderr]}
    end

    private def failed_result(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DpkgDivertPlugin.new(config)
plugin.run
