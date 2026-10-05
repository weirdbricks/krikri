#!/usr/bin/env crystal

# assemble module (ansible.builtin.assemble) - concatenates fragment files
# from a `src` directory into one `dest` file, alphabetically by filename.
# `remote_src` defaults to true (unlike copy:/template:/unarchive:) - most
# real-world uses assemble fragments that were already templated/copied
# onto the target in an earlier task (e.g. a sudoers.d/ or sshd_config.d/
# style drop-in directory), reading `src` directly on whatever filesystem
# this process is actually running on (the remote target for a real SSH
# host, same as every other plugin - see native_stat's own comment on why
# plain File/Dir calls are always correct here). `remote_src: false`
# instead has TaskExecutor#stage_assemble_dir SCP the whole src directory
# tree up first, same pattern as copy:'s stage_directory_copy_source.
#
# Parameters:
#   src (required): directory containing fragment files
#   dest (required): file to assemble them into
#   delimiter (optional): inserted between fragments
#   regexp (optional): only fragments whose filename matches this regex
#   ignore_hidden (optional bool, default false): skip dotfiles
#   backup (optional bool, default false)
#   owner/group/mode (optional): applied to dest
#   validate (optional): shell command template containing %s, run against
#     the ASSEMBLED temp content before it's moved to dest; non-zero exit
#     fails the task without touching dest (real assemble.py's own
#     `validate % path` + module.run_command, matching copy.cr/replace.cr's
#     established %s-template convention in this codebase)
#   remote_src (optional bool, default true, accept-and-ignore): real
#     Ansible's action plugin decides whether src needs transferring from
#     the controller first - krikri's own TaskExecutor#stage_assemble_dir
#     already handles the remote_src: false transfer case externally (see
#     __cleanup_after_assemble below), so this plugin itself always just
#     reads src wherever this process runs, matching remote_src: true's
#     semantics inherently
#   decrypt (optional bool, default true, accept-and-ignore): vault
#     decryption is an action-plugin/controller-side concern with no
#     analogous step inside this plugin

require "json"
require "digest/md5"
require "digest/sha1"
require "file_utils"
require "../src/krikri/base_plugin"

module Krikri
  class AssemblePlugin < BasePlugin
    # ansible.builtin.assemble's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.assemble). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    #
    # remote_src is deliberately ABSENT: Ansible's action plugin reads it
    # through boolean(remote_src, strict=False) FIRST and only dispatches
    # the assemble module when that answers True - i.e. only for
    # BOOLEANS_TRUE spellings/natives, where the module's own strict
    # type: bool conversion can then only ever succeed. Every other value
    # (falsy spellings, invalid strings like 'timjjr', explicit None,
    # native 2) takes the action's controller-side branch instead, so the
    # assemble module - and its strict remote_src conversion with it -
    # never runs at all (live-verified vs 2.19.11).
    protected def bool_params : Array(String)
      %w[backup decrypt ignore_hidden unsafe_writes]
    end

    def execute : PluginResult
      validate_bool_params!
      src = @params["src"]?
      dest = @params["dest"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: src") unless src
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: dest") unless dest

      # remote_src the action plugin treats as falsy (boolean(strict=False)
      # - see Krikri.lenient_boolean_true? and the bool_params comment)
      # runs assemble's controller-side action plugin first - its isdir()
      # check is a plain AnsibleActionFail ("Source (..) is not a
      # directory", no "Module failed." chain segment). With the default
      # remote_src (or a BOOLEANS_TRUE value) the module itself reports
      # missing vs not-a-dir separately (assemble.py:232/235).
      unless Dir.exists?(src)
        if remote_src_delegated?
          return PluginResult.new(changed: false, failed: true, msg: "Source (#{src}) is not a directory",
            _ansible_action_level: true)
        end
        msg = File.exists?(src) ? "Source (#{src}) is not a directory" : "Source (#{src}) does not exist"
        return PluginResult.new(changed: false, failed: true, msg: msg)
      end

      ignore_hidden = true?(@params["ignore_hidden"]?)
      regexp = @params["regexp"]?.try { |rval| Regex.new(rval) rescue nil }
      delimiter = @params["delimiter"]?

      content = assembled_content(src, ignore_hidden, regexp, delimiter)

      existing = File.exists?(dest) ? File.read(dest) : nil
      changed = existing != content
      check_mode = true?(@params["_ansible_check_mode"]?)
      diff_mode = true?(@params["_ansible_diff"]?)

      diff = diff_mode ? generate_unified_diff(existing || "", content, dest, dest) : nil
      backup_file = ""

      if changed
        if validate_cmd = @params["validate"]?
          if failure = validate_assembled(content, validate_cmd)
            return failure
          end
        end

        unless check_mode
          result = write_assembled(dest, content, existing)
          # Ansible's module crashes INSIDE atomic_move for a dest whose
          # parent directory doesn't exist (or a bare relative name) -
          # the failure surfaces after the dest file itself was already
          # renamed into place, and no attributes are ever applied.
          return result if result.is_a?(PluginResult)
          backup_file = result
        end
      end

      # __cleanup_after_assemble - set by TaskExecutor#stage_assemble_dir
      # when remote_src: false SCP'd a whole controller-side directory up
      # to a scratch path first. Best-effort, mirrors copy.cr's own
      # __cleanup_after_copy_dir.
      if @params["__cleanup_after_assemble"]? == "true"
        FileUtils.rm_rf(src) rescue nil
      end

      attrs_changed = !check_mode && File.exists?(dest) && apply_owner_group_mode_changed(dest)

      result = PluginResult.new(
        changed: changed || attrs_changed,
        failed: false,
        msg: "OK",
        diff: diff,
        dest: dest,
        checksum: Digest::SHA1.hexdigest(content),
        md5sum: Digest::MD5.hexdigest(content),
        key_order: SUCCESS_KEY_ORDER
      )
      # Ansible's result echoes the src: param and carries backup_file only
      # when a backup was actually taken (live-verified vs 2.19.11 at -v).
      result.extra["src"] = JSON::Any.new(src)
      result.extra["backup_file"] = JSON::Any.new(backup_file) unless backup_file.empty?
      # Ansible's add_path_info runs at module-exit regardless of check
      # mode - an existing dest's stat fields ride the check-mode
      # result too (live-verified vs 2.19.11 at -v); a not-yet-existing
      # dest gets no fields, which add_path_info handles itself.
      add_path_info(result, dest)
      result
    end

    # Ansible.builtin.assemble's registered-result key order
    # (live-verified vs 2.19.11 via `{{ r | to_json }}` on registered
    # assemble: tasks): src, dest, checksum, md5sum, then backup_file
    # only when a backup was taken, then changed, msg, the stat block
    # and failed - IDENTICAL on changed and unchanged runs (the
    # checksums ride the no-op result too). No diff key outside --diff
    # mode. In check mode against a not-yet-existing dest the stat block
    # is absent and the same constant reduces to src, dest, checksum,
    # md5sum, changed, msg, failed.
    private SUCCESS_KEY_ORDER = %w[src dest checksum md5sum backup_file changed msg uid gid owner group mode state size failed]

    # Whether Ansible's action plugin takes its controller-side branch for
    # this task's remote_src: PRESENT and boolean(remote_src, strict=False)
    # not True. The plugin-side view of Krikri.lenient_boolean_true? - the
    # demoted @params text has already lost the parser's non-string marker,
    # so native literals (1.0 is TRUE, 2 is not) come from
    # #non_string_param instead of the plain spelling check.
    private def remote_src_delegated? : Bool
      return false unless @params.has_key?("remote_src")
      truthy = if native = non_string_param("remote_src")
                 case native.raw
                 when Bool    then native.as_bool
                 when Int64   then native.as_i64 == 1
                 when Float64 then native.as_f == 1.0
                 else              false
                 end
               else
                 %w[y yes on 1 true t].includes?(@params["remote_src"].downcase.strip)
               end
      !truthy
    end

    # An unhandled module exception (atomic_move's FileNotFoundError /
    # the rename failure it wraps): real renders it as "Task failed:
    # Module failed: <detail>" in both the [ERROR] block and the fatal
    # msg, with base_plugin's own "exception": "(traceback unavailable)"
    # bookkeeping - same shape mount.cr/apt.cr use for their module
    # crashes.
    private def module_crash_result(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
    end

    # Runs validate: (with %s substituted by a temp file holding the
    # assembled content, staged same-directory as dest so a later
    # rename/move never crosses a filesystem boundary - see replace.cr's
    # own write_with_optional_validate for the identical convention and
    # the cross-device-rename bug this specifically avoids) before dest
    # is ever touched. Returns the failure result, or nil on success.
    private def validate_assembled(content : String, validate_cmd : String) : PluginResult?
      dest = @params["dest"].not_nil!
      unless validate_cmd.includes?("%s")
        return PluginResult.new(changed: false, failed: true, msg: "validate must contain %s: #{validate_cmd}")
      end

      temp_file = File.join(File.dirname(dest), ".krikri-playbook-assemble-#{Random::Secure.hex(8)}.tmp")
      begin
        # SECURITY: created EMPTY at 0600 and settled to 0644 & ~umask
        # (narrowed by the task's numeric mode:) BEFORE the assembled
        # content lands - see BasePlugin#create_staging_temp. This temp
        # is deleted after validation, it never becomes dest, so it
        # never inherits a dest mode. The old write-first shape held the
        # bytes at 0644 & ~umask for the whole validate run.
        create_staging_temp(temp_file, staging_temp_mode(dest, 0o644, preserve_dest_mode: false))
        File.write(temp_file, content, perm: 0o600)
        cmd = validate_cmd.gsub("%s", shell_single_quote(temp_file))
        output = IO::Memory.new
        result = Process.run("/bin/sh", ["-c", cmd], output: output, error: output)
        unless result.exit_code == 0
          return PluginResult.new(changed: false, failed: true, msg: "failed to validate: rc:#{result.exit_code} error:#{output.to_s.strip}")
        end
      ensure
        File.delete(temp_file) if File.exists?(temp_file)
      end
      nil
    end

    # apply_owner_group_mode doesn't report whether it changed anything -
    # compare dest's stat before/after so `changed:` reflects an
    # attribute-only update on an otherwise-identical dest, matching real
    # Ansible's own set_fs_attributes_if_different contribution to changed.
    private def apply_owner_group_mode_changed(dest : String) : Bool
      before = File.info?(dest, follow_symlinks: false)
      apply_owner_group_mode(dest, @params["owner"]?, @params["group"]?, @params["mode"]?)
      after = File.info?(dest, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions || before.owner_id != after.owner_id || before.group_id != after.group_id
    end

    # Collect the sorted fragment files from src and join their contents
    private def assembled_content(src : String, ignore_hidden : Bool, regexp : Regex?, delimiter : String?) : String
      fragments = Dir.children(src).sort.select do |name|
        next false if ignore_hidden && name.starts_with?('.')
        full = File.join(src, name)
        next false unless File.file?(full)
        regexp.nil? || regexp.try(&.matches?(name)) || false
      end

      assembled = fragments.map { |name| File.read(File.join(src, name)) }
      delimiter ? assembled.join(delimiter.includes?("\n") ? delimiter : "#{delimiter}\n") : assembled.join
    end

    # Write the assembled content to dest, backing up the previous file
    # when requested; returns the backup file path ("" when none), or a
    # failed PluginResult when Ansible's atomic_move would crash the module
    # (module_crash_result). Ansible's atomic_move:
    # os.rename(temp, dest) first, then - only when dest did not exist
    # ("creating") - os.stat(os.path.dirname(dest)). A dest whose parent
    # directory is missing fails the rename with ENOENT ("Could not
    # replace ..."), and a BARE relative filename's dirname is b'' -
    # "[Errno 2] No such file or directory: b''" AFTER the rename already
    # created the file (live-verified vs 2.19.11 for relative/int/bool/
    # float/list dests; the dest file is left behind in both engines).
    private def write_assembled(dest : String, content : String, existing : String?) : PluginResult | String
      backup_file = ""
      if existing && true?(@params["backup"]?)
        # backup_local stamps LOCAL time (same as copy/template's backups)
        backup_file = "#{dest}.#{Process.pid}.#{Time.local.to_s("%Y-%m-%d@%H:%M:%S")}~"
        File.write(backup_file, existing)
      end

      return backup_file if File.exists?(dest)

      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        # The rename fails ENOENT (not one of atomic_move's workaround
        # errnos) and the module dies with the chained errno text. The
        # temp source path is module-tmpdir-specific and differs between
        # two Ansible runs by construction, so byte parity is impossible
        # here - krikri mirrors the message shape with its own temp name.
        tmp_src = File.join(Dir.tempdir, "tmp#{Random::Secure.hex(5)}")
        return module_crash_result(
          "Could not replace '#{dest}' with '#{tmp_src}': " \
          "[Errno 2] No such file or directory: b'#{tmp_src}' -> b'#{dest}'")
      end

      if dest_dir == "."
        # A bare relative filename: the rename onto the bare name
        # succeeds (creating the file in the cwd), then the creating-
        # branch os.stat(os.path.dirname(b_dest)) stats b'' and fails.
        # SECURITY: created EMPTY at 0600 and settled to its final mode
        # (0666 & ~umask - Ansible's atomic_move opens the source at
        # Python's default 0666 and the umask trims it; live-verified
        # vs 2.19.11: umask 002 -> mode "0664" on the assembled dest -
        # narrowed by the task's numeric mode:) before
        # the assembled content lands - see BasePlugin#create_staging_temp.
        create_staging_temp(dest, staging_temp_mode(dest, 0o666, preserve_dest_mode: false))
        File.write(dest, content, perm: 0o600)
        return module_crash_result("[Errno 2] No such file or directory: b''")
      end

      # SECURITY: a not-yet-existing dest is created EMPTY at 0600 and
      # settled to its final mode (0666 & ~umask - see the bare-relative
      # case above for the real-Ansible reading) before the assembled
      # content lands - see BasePlugin#create_staging_temp. An existing
      # dest's mode is untouched by opening it for writing (and the
      # task's mode:/owner: are applied to dest after this returns, as
      # before).
      unless File.exists?(dest)
        create_staging_temp(dest, staging_temp_mode(dest, 0o666, preserve_dest_mode: false))
      end
      File.write(dest, content, perm: 0o600)
      backup_file
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::AssemblePlugin.new(config)
plugin.run
