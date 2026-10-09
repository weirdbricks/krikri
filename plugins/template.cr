#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "digest/sha1"
require "file_utils"
require "../src/krikri/base_plugin"

module Krikri
  # Template plugin - writes pre-rendered template content to files
  #
  # This plugin ONLY works with action plugins.
  # The template_action_plugin reads and renders the template on the controller,
  # then sends the rendered content to this plugin to write to the remote.
  #
  # Parameters:
  #   content (required): Pre-rendered template content from action plugin
  #   dest (required): Destination path on remote host
  #   owner (optional): File owner
  #   group (optional): File group
  #   mode (optional): File permissions (octal or symbolic)
  #   backup (optional): Create backup before overwriting
  #   validate (optional): Command to validate file before moving to dest
  #   check_mode (optional): Dry-run mode
  #   follow (optional, default False): write through a symlink at dest
  #     instead of replacing the symlink with a regular file
  #   force (optional, default True): overwrite dest when it exists with
  #     different content
  #   newline_sequence (consumed by the controller-side action plugin,
  #     passed through harmlessly): "\n"/"\r"/"\r\n"
  #   output_encoding (optional, default utf-8): encoding used to WRITE
  #     dest (the source template is always read as utf-8)
  #   attributes/attr (optional): chattr-style file flags
  #   seuser/serole/setype/selevel (optional): SELinux context parts -
  #     graceful no-op on non-SELinux hosts, real chcon when enabled
  #   unsafe_writes (optional, default False): allow a non-atomic,
  #     in-place write when the destination directory is not writable
  #
  # This is a simplified version that delegates all rendering to the action plugin.
  class TemplatePlugin < BasePlugin
    # ansible.builtin.template's `type: bool` options that real forwards
    # to the copy module for validation, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.template).
    # trim_blocks/lstrip_blocks are deliberately absent: the template
    # ACTION plugin consumes them before the module sees any args, so
    # Ansible never argspec-validates them (live-verified against
    # ansible-core 2.19.11: `trim_blocks: blah` renders fine).
    # `follow` is absent for the same reason: the action plugin reads it
    # through boolean(value, strict=False) and passes the COERCED boolean
    # to the copy module it delegates to (template.py), so a spelling real
    # would reject never reaches that module's spec - `follow: hcsjhk`
    # deploys the template (live-verified vs 2.19.11), and paired with a
    # typo'd option it is that typo which fails the task. Validated
    # by BasePlugin#validate_bool_params! - see its block comment.
    protected def bool_params : Array(String)
      %w[backup force unsafe_writes]
    end

    # Ansible.builtin.template's registered-result key orders (the
    # template ACTION plugin delegates to the copy module, so the module
    # result is copy-shaped; live-verified vs 2.19.11 via `{{ r | to_json }}`
    # on registered template: tasks - the -v dump sorts alphabetically):
    #
    # - changed path (fresh and backup: alike): diff, dest, src, md5sum,
    #   checksum, changed (, backup_file), then the add_path_info stat
    #   block and failed: false - identical to copy's changed order.
    #   `src` is Ansible's staged .source.txt tempfile path; krikri echoes
    #   the rendered-source path the action plugin sent along
    #   (_rendered_from_template).
    # - equal-content rerun: diff, path, changed, the stat block, then
    #   the checksum and dest echo - copy's unchanged order.
    # - force: false against an existing dest: ONLY {dest, src, changed}
    #   (live-verified; no msg, no stat fields) - copy's noop order.
    # - check-mode would-change: the action-level bare {diff, changed}
    #   (live-verified) - copy's check order.
    private CHANGED_KEY_ORDER   = %w[diff dest src md5sum checksum changed backup_file uid gid owner group mode state size failed]
    private UNCHANGED_KEY_ORDER = %w[diff path changed uid gid owner group mode state size checksum dest failed]
    private NOOP_KEY_ORDER      = %w[dest src changed failed]
    private CHECK_KEY_ORDER     = %w[diff changed failed]

    property? check_mode : Bool
    property? diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
      @diff_mode = true?(@params["_ansible_diff"]?)
    end

    def execute : PluginResult
      result = execute_template
      # Real template's wire result ALWAYS carries a `diff` key - an empty
      # LIST when no diff data was computed (live-verified vs 2.19.11 at
      # -vvv, run and --check alike; the display layer strips it below
      # -vvv). A real diff payload (diff mode) keeps the computed content.
      if result.diff.nil? && !result.failed?
        result.diff = JSON::Any.new([] of JSON::Any)
      end
      result
    end

    private def execute_template : PluginResult
      # Get destination (required)
      dest = @params["dest"]?
      unless dest
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: dest"
        )
      end
      # A non-string YAML literal dest (`dest: true`) is coerced through
      # Python str() by Ansible's action plugin - bools render as
      # "True"/"False" (live-verified: Ansible writes a file literally named
      # "True"; int/float spellings already match the demoted text). See
      # NON_STRING_PARAM_PREFIX.
      if native = non_string_param("dest")
        dest = Krikri.python_str_scalar(native)
      end

      # AnsibleModule validates bool-typed params at module setup,
      # after the required-args gate (see BasePlugin#validate_bool_params!).
      # Under --check Ansible's copy action plugin returns as soon as it sees
      # the checksums differ (copy.py:288-293) and otherwise dispatches the
      # file module with copy's copy-only options stripped, so the copy
      # spec never runs and cannot reject anything (live-verified vs
      # 2.19.11: `template: backup: notabool` under --check reports
      # changed, not a bool error). Same rule as the controller-side gate
      # in TaskExecutor#argspec_validation_result.
      validate_bool_params! unless @check_mode
      dest = expand_tilde(dest)

      # Ansible.builtin.template, like copy: a dest that signals a
      # directory (an existing directory, or an explicit trailing "/")
      # gets the template's own basename appended - the rendered file
      # lands at <dest>/<basename of src>, not on the directory path
      # itself. _rendered_from_template is the controller-side src path
      # the action plugin sends along (src itself is stripped before
      # upload), so its basename is the real template filename. Found
      # benchmarking l3d.unbound, whose config-fragment tasks pass
      # `dest: /etc/unbound/unbound.conf.d/` - previously the raw
      # slash-terminated dest reached the final move and failed with
      # "Not a directory" where Ansible succeeded.
      dest_signaled_dir = dest.ends_with?('/')
      if (template_src = @params["_rendered_from_template"]?.presence) && (Dir.exists?(dest) || dest_signaled_dir)
        dest = File.join(dest, File.basename(template_src))
      end

      # follow: (Ansible's copy-writer semantics, default False):
      # when True, a symlink at dest: is written THROUGH - the symlink's
      # target gets the rendered content and the symlink itself stays -
      # while the default replaces the symlink with a regular file.
      # Live-verified against ansible-core 2.19.4: follow=true writes the
      # target (link still a link afterwards), follow=false replaces the
      # link. Resolution happens BEFORE the identical-content check so
      # idempotency compares against the target's content, matching
      # Ansible's own comparison of the followed path's checksum. A
      # dangling symlink is deliberately NOT resolved (File.exists?
      # returns false for one) - Ansible's default path unlinks and
      # replaces it, which the move below does anyway.
      if true?(@params["follow"]?) && File.symlink?(dest) && File.exists?(dest)
        dest = File.realpath(dest)
      end

      # Get content (required - should come from action plugin)
      content = @params["content"]?
      unless content
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: content. This plugin requires the template_action_plugin to render the template on the controller first."
        )
      end

      # output_encoding: Ansible's template module writes the
      # rendered content to dest in this encoding (default utf-8; the
      # source template is always READ as utf-8, so this only shapes the
      # write). Verified byte-level against ansible-core 2.19.4:
      # output_encoding=latin-1 with a template containing "é" writes
      # the single byte 0xe9 (not UTF-8's 0xc3 0xa9), and an unknown
      # codec name fails the task ("unknown encoding: ..."). Crystal
      # strings are UTF-8 internally, so the write-time conversion is
      # String#encode into a byte slice; idempotency and checksums are
      # computed over the encoded bytes, not the UTF-8 string, so a
      # latin-1-written file re-runs as ok/changed: false.
      output_encoding = @params["output_encoding"]?.presence || "utf-8"
      content_bytes, encoding_error = encode_output(content, output_encoding)
      if encoding_error
        return PluginResult.new(changed: false, failed: true, msg: encoding_error)
      end

      # Calculate MD5 of the encoded content (see output_encoding above);
      # the RESULT's checksum is Ansible's SHA1 of the dest content.
      content_md5 = Digest::MD5.hexdigest(content_bytes)
      content_sha1 = Digest::SHA1.hexdigest(content_bytes)

      # Get existing content for diff and idempotency - read as raw
      # BYTES, not File.read: a file previously written in a non-UTF-8
      # output_encoding is not valid UTF-8, and decoding it would either
      # raise or corrupt the comparison. The diff still needs text (best
      # effort - invalid bytes are skipped, which only affects the
      # cosmetic diff for non-UTF-8 output, never the write).
      existing_content = ""
      existing_bytes = Slice(UInt8).empty
      if File.exists?(dest)
        begin
          existing_bytes = File.open(dest, "rb", &.getb_to_end)
          existing_content = String.new(existing_bytes, "UTF-8", invalid: :skip)
        rescue
          # File exists but can't read - continue anyway
        end
      end

      # Check if content is identical (idempotency)
      changed = true
      if File.exists?(dest)
        existing_md5 = Digest::MD5.hexdigest(existing_bytes)
        if existing_md5 == content_md5
          # Content is identical - no change needed!
          changed = false
        end
      end

      # Ansible's copy module (template: shares it) unconditionally
      # replaces a SYMLINK at dest with a regular file when follow: is
      # not set - even when the link's target already has identical
      # content (copy.py's `checksum_src != checksum_dest or
      # os.path.islink(b_dest)` write condition, which forces the write
      # branch for ANY symlink). Live-verified against ansible-core
      # 2.19.4: a symlink dest with byte-identical target content still
      # reports changed: true and ends up a regular file.
      if !true?(@params["follow"]?) && File.symlink?(dest)
        changed = true
      end

      # force: (Ansible's copy-writer default True): when dest
      # already exists with DIFFERENT content and force: is explicitly
      # false, Ansible leaves the file untouched and reports plain
      # ok/changed: false - NOT a failure (live-verified against
      # ansible-core 2.19.4). force: false only guards an OVERWRITE of an
      # EXISTING file - it never blocks the initial CREATE of a dest that
      # doesn't exist yet (Ansible's copy.py only takes this branch
      # inside its own `if os.path.exists(dest)` check). Missing the
      # `File.exists?(dest)` guard here (copy.cr's own #handle_file_copy
      # already has it, at the `unless force` check nested inside `if
      # File.exists?(dest)`) meant a template: task with force: false
      # skipped creating a BRAND NEW dest on its very first cold run,
      # reporting "File already exists" for a file that never existed
      # (round 811059/812xxx, cchurch.uwsgi's own `uwsgi_conf_force:
      # false` default) - Ansible creates it fine.
      if changed && File.exists?(dest) && !true?(@params["force"]?, default: true)
        # Ansible's result here is ONLY {dest, src, changed} - no msg key at
        # all (live-verified vs 2.19.11 via a registered result: src is
        # the rendered-source path, here the action plugin's
        # _rendered_from_template). The old "File already exists" msg was
        # an extra success key Ansible does not emit.
        return PluginResult.new(
          changed: false,
          failed: false,
          dest: dest,
          src: @params["_rendered_from_template"]?.presence || "template",
          key_order: NOOP_KEY_ORDER
        )
      end

      # Generate diff if in diff mode and content changed
      diff_data = nil
      if @diff_mode && changed
        # Real template's diff headers (live-verified vs 2.19.11): the
        # before side is `before: <dest>` when the dest file already
        # exists and bare `before` when it does not; the after side is
        # `after:` plus the staged copy of the source the module rendered
        # (here: krikri's resolved source path).
        src_name = @params["_rendered_from_template"]? || "template"
        diff_data = generate_unified_diff(
          existing_content,
          content,
          File.exists?(dest) ? "before: #{dest}" : "before",
          "after: #{src_name}"
        )
      end

      # CHECK MODE: Report what would change
      if @check_mode
        if changed
          return PluginResult.new(
            changed: true,
            failed: false,
            diff: diff_data,
            key_order: CHECK_KEY_ORDER
          )
        else
          # Ansible's equal-content check run still executes the module
          # (the early check-mode return in copy's action plugin only
          # fires on a checksum MISMATCH), so its result carries the
          # module's dest/checksum echo like the real run does
          # (live-verified vs 2.19.11 via a registered result). The
          # changed branch above is the action-level early return: no
          # dest there.
          result = PluginResult.new(
            changed: false,
            failed: false,
            diff: diff_data,
            dest: dest,
            checksum: content_sha1,
            key_order: UNCHANGED_KEY_ORDER
          )
          add_path_info(result, dest)
          result.extra["path"] = JSON::Any.new(dest)
          return result
        end
      end

      # If content is identical, just update attributes if requested - and
      # report changed if that reconciliation actually fixed anything. This
      # used to hardcode changed: false even when apply_file_attributes had
      # just fixed a stale mode/owner/group - the same identical-content
      # bug as copy.cr's (found on bitintheskud.ansible-role-ecs-agent:
      # anything re-breaking the mode between runs made the task silently
      # report ok forever while fixing it on disk; Ansible reports
      # `changed` once, then ok - live-verified against ansible-core 2.19).
      unless changed
        begin
          attributes_fixed = apply_file_attributes(dest)
        rescue ex
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to apply file attributes: #{ex.message}"
          )
        end
        result = PluginResult.new(
          changed: attributes_fixed,
          failed: false,
          dest: dest,
          checksum: content_sha1,
          key_order: UNCHANGED_KEY_ORDER
        )
        add_path_info(result, dest)
        result.extra["path"] = JSON::Any.new(dest)
        return result
      end

      # Content will change - create backup if requested
      backup_file = ""
      if true?(@params["backup"]?) && File.exists?(dest)
        backup_file = create_backup(dest)
      end

      # Ansible's template/copy modules do NOT create a missing
      # destination directory - they fail with this exact message
      # ("Destination directory X does not exist"). This plugin used to
      # silently `Dir.mkdir_p` it instead, diverging from Ansible
      # only when the parent genuinely didn't exist yet (the common case
      # - dest already inside an existing dir like /etc/nginx - never hit
      # this path). Found benchmarking bertvv.mariadb's own "Add official
      # MariaDB repository (yum)" task templating into /etc/yum.repos.d
      # on Ubuntu, where that directory never exists: Ansible
      # refused the task; krikri quietly created the directory and wrote
      # the file, reporting `changed` where Ansible reported
      # `failed`.
      # dest is already resolved past the directory-signal step above, so
      # a trailing-"/" dest has its basename appended before this check.
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        if dest_signaled_dir
          begin
            # Real creates the missing directory through copy.py's
            # `dest.endswith(os.sep)` makedirs branch (template's action
            # plugin runs the copy module with _original_basename) and
            # applies owner:/group:/directory_mode: to what it created -
            # not a bare mkdir (round 5210220
            # Azulinho.azulinho-yum-repo-epel).
            create_missing_dest_dir(dest_dir, @params["owner"]?, @params["group"]?, @params["directory_mode"]?)
          rescue ex : OwnerLookupFailure
            raise ex
          rescue ex
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to create destination directory #{dest_dir}: #{ex.message}"
            )
          end
        else
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Destination directory #{dest_dir} does not exist"
          )
        end
      end

      # Ansible's copy module (template: shares it) pre-checks the
      # destination directory's writability and fails with exactly
      # "Destination <dir> not writable" when it isn't - live-verified
      # against ansible-core 2.19.4, including the observable effect:
      # a read-only directory containing a WRITABLE file fails the task
      # by default (the atomic temp-file+rename cannot work without
      # directory write permission), and unsafe_writes: true bypasses
      # the check, falling back to a direct, non-atomic in-place write
      # (Ansible's _unsafe_writes). Note the check is on the
      # DIRECTORY, not the file: a writable dir with an
      # existing-file-dest proceeds normally.
      unless true?(@params["unsafe_writes"]?)
        unless File::Info.writable?(dest_dir)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Destination #{dest_dir} not writable"
          )
        end
      end

      # Write to temporary file first (for atomic write + validation).
      # Staged in a remote_tmp-style location (`/tmp`), matching
      # Ansible's own `~/.the Ansible module` staging - NOT
      # dest_dir, which this plugin used previously. That dest-adjacent
      # staging was itself a fix for a real cross-device `File.rename`
      # bug (`/tmp` is very commonly its own separate tmpfs mount, so
      # renaming a /tmp staging file onto a destination elsewhere on
      # disk hit "Invalid cross-device link" - found via
      # konstruktoid-hardening's "Configure sshd using sshd_config.d"
      # task writing to /usr/lib/tmpfiles.d/ssh.conf) but it diverges
      # from Ansible in a way that's independently observable: a
      # `validate:` command confined by AppArmor/SELinux to only the
      # target program's OWN real config paths (e.g. dhcpd's profile
      # permits /etc/dhcp/ but not a temp file dropped next to it) can
      # see a different validation outcome than Ansible's own
      # /root/.ansible/tmp-confined run (found via bertvv.dhcp round
      # 312). Moving back to /tmp restores Ansible's location
      # without reintroducing the cross-device bug: `FileUtils.mv`
      # (stdlib) already falls back to copy-then-delete on
      # `Errno::EXDEV`/`EPERM`, exactly the fallback needed - see its
      # use below instead of a raw `File.rename`.
      temp_file = File.join("/tmp", ".krikri-playbook-template-#{Random::Secure.hex(8)}.tmp")

      begin
        # SECURITY: the temp is created EMPTY at 0600 and settled to its
        # final mode (0644 & ~umask, narrowed by the task's numeric
        # mode: - the rename carries this temp's mode onto dest, it does
        # not inherit an existing dest's, matching the old default-perm
        # File.write) BEFORE the rendered bytes land - see
        # BasePlugin#create_staging_temp. The old write-first shape held
        # a rendered secret (vault-decrypted values interpolated in) at
        # 0644 & ~umask for the whole write + validate + move span.
        create_staging_temp(temp_file, staging_temp_mode(dest, 0o666, preserve_dest_mode: false))
        # Write the OUTPUT-ENCODED bytes (see output_encoding above) -
        # not the UTF-8 string. perm 0600 only matters if the temp
        # vanished between creation and here: recreate narrow, never
        # wide.
        File.write(temp_file, content_bytes, perm: 0o600)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to write temporary file: #{ex.message}"
        )
      end

      # Validate if requested
      if validate_cmd = @params["validate"]?
        # copy.py's own gate before anything runs:
        # fail_json(msg="validate must contain %s: <cmd>") when the
        # command has no %s to substitute the temp path into (same
        # wording this engine's assemble/blockinfile/lineinfile/replace
        # plugins already carry).
        unless validate_cmd.includes?("%s")
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "validate must contain %s: #{validate_cmd}"
          )
        end
        validation = validate_file(temp_file, validate_cmd)
        unless validation[:ok]
          # Real copy.py's validate site (the template module runs
          # through it): fail_json(msg="failed to validate",
          # exit_status=rc, stdout=out, stderr=err) - the raw streams
          # and the exit status ride in the result, checksum is the
          # rendered content's sha1 the action plugin already computed,
          # and stdout_lines/stderr_lines come from _return_formatted's
          # own splitter (live-verified vs ansible-playbook 2.19.11 on
          # `template: ... validate: /bin/false %s`: {"changed": false,
          # "checksum": "<sha1>", "exit_status": 1, "msg": "failed to
          # validate", "stderr": "", "stderr_lines": [], "stdout": "",
          # "stdout_lines": []}). The previous "Validation failed:
          # <merged output> (rendered content left at ...)" wording is
          # this plugin's own borrow - found via robertdebock.cups's
          # own "Configure cups" task (round 1500129). The staged temp
          # is still left on disk (only the message differs from real;
          # real's own tmpdir is cleaned up by do_cleanup_files, which
          # has no observable result here).
          stdout = validation[:stdout]
          stderr = validation[:stderr]
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "failed to validate",
            checksum: content_sha1,
            exit_status: validation[:rc],
            stdout: stdout,
            stdout_lines: stdout.empty? ? [] of String : stdout.chomp.split("\n"),
            stderr: stderr,
            stderr_lines: stderr.empty? ? [] of String : stderr.chomp.split("\n")
          )
        end
      end

      # Move temp file to destination, mirroring Ansible's
      # atomic_move fallback ladder. The optimistic step is a rename of
      # the /tmp-staged file onto dest (atomic, replaces dest INODE -
      # including replacing a symlink at dest, Ansible's default
      # follow=false semantics). When rename can't work - /tmp being a
      # separate tmpfs mount is very common, and the whole reason
      # staging moved back to /tmp was a cross-device "Invalid
      # cross-device link" (see temp_file's comment above) -
      # Ansible falls back to staging NEXT TO dest (mkstemp in the dest
      # directory, same filesystem) and renaming from there. Doing that
      # explicitly matters: a naive copy-onto-dest fallback (e.g.
      # FileUtils.mv's own cross-device path) OPENS dest for writing,
      # which follows a symlink - a dest symlink would get its target
      # overwritten instead of replaced, silently diverging from
      # Ansible's follow=false (and silently "succeeding" where
      # Ansible's follow default writes a real file).
      begin
        File.rename(temp_file, dest)
      rescue
        begin
          dest_dir_stage = File.join(dest_dir, ".krikri-playbook-template-#{Random::Secure.hex(8)}.tmp")
          File.write(dest_dir_stage, "")
          FileUtils.mv(temp_file, dest_dir_stage)
          File.rename(dest_dir_stage, dest)
        rescue ex
          File.delete(dest_dir_stage) if dest_dir_stage && File.exists?(dest_dir_stage)
          File.delete(temp_file) if File.exists?(temp_file)
          if true?(@params["unsafe_writes"]?)
            # Ansible's _unsafe_writes: a direct, non-atomic
            # in-place write of dest - the only path that works when
            # the DEST DIRECTORY isn't writable (the writability
            # pre-check above normally fails this first without
            # unsafe_writes:). Preserves dest's inode, so hardlinks to
            # it see the new content.
            begin
              # Same narrow-then-settle staging discipline as the temp
              # above for a not-yet-existing dest; an existing dest's
              # mode is untouched by opening it for writing.
              unless File.exists?(dest)
                create_staging_temp(dest, staging_temp_mode(dest, 0o666, preserve_dest_mode: false))
              end
              File.write(dest, content_bytes, perm: 0o600)
            rescue ex
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to write destination file (unsafe_writes): #{ex.message}"
              )
            end
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to replace #{dest} with the rendered template: #{ex.message}"
            )
          end
        end
      end

      # Set ownership and permissions (may raise a real, specific
      # failure - chattr/chcon - that must reach the user, mirroring
      # file.cr's own handling)
      begin
        apply_file_attributes(dest)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: ex.message || "Failed to apply file attributes"
        )
      end

      result = PluginResult.new(
        changed: true,
        failed: false,
        diff: diff_data,
        dest: dest,
        # Ansible's src is the staged rendered-source tempfile (.source.txt,
        # live-verified); krikri echoes the rendered-source path the
        # action plugin passed along for exactly this purpose.
        src: @params["_rendered_from_template"]?.presence || "template",
        checksum: content_sha1,
        md5sum: content_md5,
        key_order: CHANGED_KEY_ORDER
      )
      result.extra["backup_file"] = JSON::Any.new(backup_file) unless backup_file.empty?
      add_path_info(result, dest)
      result
    end

    # Create backup of existing file
    private def create_backup(path : String) : String
      # Ansible's backup_local (used by the template action's copy
      # module too) inserts the process PID between path and timestamp
      # and stamps LOCAL time - not a random number, not UTC
      # (live-verified vs 2.19.11).
      timestamp = Time.local.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{Process.pid}.#{timestamp}~"

      begin
        File.copy(path, backup_path)
        backup_path
      rescue
        # Backup failed, continue anyway
        ""
      end
    end

    # Validate file with command. Keeps stdout and stderr SEPARATE and
    # unstripped - real copy.py's run_command result feeds them straight
    # into fail_json(stdout=out, stderr=err), so a validator that writes
    # its explanation to stderr (sshd -T, nginx -t, cupsd -t, ...) must
    # land in the result's stderr key with an empty stdout, not merged
    # into one blob.
    private def validate_file(path : String, validate_cmd : String) : NamedTuple(ok: Bool, rc: Int32, stdout: String, stderr: String)
      cmd = validate_cmd.gsub("%s", shell_single_quote(path))
      out_io = IO::Memory.new
      err_io = IO::Memory.new

      result = Process.run(
        "/bin/sh",
        ["-c", cmd],
        output: out_io,
        error: err_io
      )

      {ok: result.exit_code == 0, rc: result.exit_code, stdout: out_io.to_s, stderr: err_io.to_s}
    end

    # Apply file attributes (owner, group, mode). Returns true if anything
    # actually changed on disk (so the identical-content caller can report
    # `changed` like Ansible when it reconciles an attribute), false
    # otherwise - including when nothing was stale or an apply failed.
    private def apply_file_attributes(path : String) : Bool
      before = File.info?(path, follow_symlinks: false)

      # SELinux context runs FIRST, matching the order of Ansible's
      # set_fs_attributes_if_different (set_context_if_different ->
      # owner -> group -> mode -> attributes) and file.cr's own
      # apply_single_file_attributes, which this mirrors.
      secontext_will_change = secontext_changed?(path)
      apply_secontext(path)

      # owner/group/mode - the shared BasePlugin helper: resolves the
      # names first (so an unknown user/group raises the same
      # "chown/chgrp failed: failed to look up ..." text Ansible's
      # basic.py fails with, live-verified vs 2.19.11) and applies via
      # File.chown/File.chmod, shelling to chmod only for a symbolic
      # mode (the octal-vs-symbolic split and the all-digit-is-octal
      # rule it implements are documented on that helper). The old code
      # here shelled out to chown/chgrp with stdout, stderr AND the exit
      # status all discarded, so a template task whose group: named a
      # nonexistent group silently reported changed where real fails the
      # task (gokev.motd-splash round 5210000: `group: wheel` on Ubuntu
      # - ansible "chgrp failed: failed to look up group wheel",
      # krikri changed=1).
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)

      # attributes: (chattr flags) runs LAST, matching file.cr's own
      # attribute-application order.
      attr_will_change = attr_changed?(path)
      apply_attr(path)

      after = File.info?(path, follow_symlinks: false)
      if before && after
        return true if before.permissions != after.permissions ||
                       before.owner_id != after.owner_id ||
                       before.group_id != after.group_id
      end
      secontext_will_change || attr_will_change
    end

    # output_encoding: encodes the rendered content into the requested
    # target encoding, returning the bytes plus an error message (nil on
    # success). Ansible writes with Python's codec stack
    # (errors='surrogate_or_strict' - an unencodable character or an
    # unknown codec name fails the task); Crystal strings are UTF-8
    # internally, so this goes through String#encode. The name search
    # tries a few normalizations because codec-naming conventions differ
    # (Ansible's documented example "latin-1" is
    # "latin1"/"ISO-8859-1" to iconv).
    private def encode_output(content : String, output_encoding : String) : {Slice(UInt8), String?}
      return {content.to_slice, nil} if output_encoding.downcase == "utf-8" || output_encoding.downcase == "utf8"

      candidates = {
        output_encoding,
        output_encoding.delete("-_"),
        output_encoding.upcase,
        output_encoding.delete("-").upcase,
      }
      encoding_error = nil
      candidates.each do |candidate|
        begin
          return {content.encode(candidate), nil}
        rescue ex : ArgumentError
          encoding_error = ex.message
        end
      end
      {Slice(UInt8).empty, "unknown encoding: #{output_encoding}"}
    end

    # The methods below mirror plugins/file.cr's already-verified
    # implementations of Ansible's file-common args (attr:/
    # attributes: chattr flags, seuser:/serole:/setype:/selevel: SELinux
    # context parts) for a plugin that writes new file content rather
    # than only mutating metadata - deliberately duplicated rather than
    # abstracted, so the proven-correct file.cr behavior can't drift
    # under a shared abstraction.

    # attr:/attributes: (chattr flags, Ansible's `attributes` param
    # and its `attr` alias). Parsed into the leading operator ('+'/'-',
    # defaulting to '=' when bare) plus the flag letters themselves -
    # Ansible's set_attributes_if_different in
    # the Ansible module does exactly this split before comparing.
    private def attr_args : {Char, String}?
      raw = @params["attr"]? || @params["attributes"]?
      return nil unless raw
      raw = raw.strip
      return nil if raw.empty?
      if raw[0] == '-' || raw[0] == '+'
        {raw[0], raw[1..]}
      else
        {'=', raw}
      end
    end

    # The file's current chattr flags as Ansible reads them:
    # `lsattr -d <path>` output's first whitespace field with the
    # dash-padding stripped. An lsattr failure (missing binary,
    # unsupported filesystem) is empty flags, not an error - matching
    # file.cr's reading of Ansible's get_file_attributes.
    private def current_attr_flags(path : String) : String
      result = remote_exec("lsattr -d #{shell_single_quote(path)}")
      return "" unless result[:exit_code] == 0
      fields = result[:stdout].strip.split
      return "" if fields.empty?
      fields[0].delete('-').strip
    end

    # Changed-check mirroring Ansible's set_attributes_if_different
    # (including its non-converging '-i' quirk, ansible/ansible#33745 -
    # see file.cr's attr_changed? for the full rationale).
    private def attr_changed?(path : String) : Bool
      parsed = attr_args
      return false unless parsed
      mod, flags = parsed
      return false if flags.empty?
      current_attr_flags(path) != flags || mod == '-'
    end

    # Applies the attr:/attributes: param via the real chattr binary,
    # failing the task (like Ansible's fail_json) when chattr exits
    # nonzero or writes to stderr.
    private def apply_attr(path : String) : Nil
      parsed = attr_args
      return unless parsed
      mod, flags = parsed
      return if flags.empty?
      return unless current_attr_flags(path) != flags || mod == '-'

      result = remote_exec("chattr #{mod}#{flags} #{shell_single_quote(path)}")
      if result[:exit_code] != 0 || !result[:stderr].strip.empty?
        raise "chattr failed - Error while setting attributes: #{result[:stdout]}#{result[:stderr]}"
      end
    end

    # SELinux context params: Ansible accepts these on every host
    # but only ACTS on them when SELinux is actually enabled - its
    # set_context_if_different opens with `if not self.selinux_enabled():
    # return changed`, a graceful no-op (live-verified against
    # ansible-core 2.19.4 on this non-SELinux machine: silently
    # accepted, no SELinux keys in the result, changed per the stat
    # result only). Identical semantics to file.cr's merged
    # implementation.
    @selinux_enabled : Bool? = nil
    @mls_enabled : Bool? = nil

    private def selinux_enabled? : Bool
      # Grounded approximation of libselinux's is_selinux_enabled(): the
      # selinuxfs mount only exists when SELinux is active in the kernel.
      @selinux_enabled ||= Dir.exists?("/sys/fs/selinux")
    end

    private def mls_enabled? : Bool
      @mls_enabled ||= begin
        File.read("/sys/fs/selinux/mls").strip == "1"
      rescue
        false
      end
    end

    private def secontext_requested? : Bool
      !!(@params["seuser"]? || @params["serole"]? || @params["setype"]? || @params["selevel"]?)
    end

    # The file's current context via `ls -Zd` (split limited to 4 parts
    # exactly like Ansible's own `context.split(':', 3)` - the MLS
    # level may itself contain ':').
    private def current_selinux_context(path : String) : Array(String)?
      return nil unless selinux_enabled?
      result = remote_exec("ls -Zd #{shell_single_quote(path)}")
      return nil unless result[:exit_code] == 0
      context = result[:stdout].strip.split[0]?
      return nil unless context
      parts = context.split(':', 3)
      (parts.size == 3 || (mls_enabled? && parts.size == 4)) ? parts : nil
    end

    # Desired context: provided parts override, unprovided parts keep
    # their current value; "_default" resolves via matchpathcon
    # (see file.cr's desired_selinux_context for the full
    # the Ansible module grounding).
    private def desired_selinux_context(path : String, current : Array(String)) : Array(String)
      desired = current.dup
      ["seuser", "serole", "setype"].each_with_index do |param, index|
        next unless value = @params[param]?
        desired[index] = value == "_default" ? selinux_default_context_part(path, index, current) : value
      end
      if selevel = @params["selevel"]?
        if mls_enabled? && desired.size > 3
          desired[3] = selevel == "_default" ? selinux_default_context_part(path, 3, current) : selevel
        end
      end
      desired
    end

    private def selinux_default_context_part(path : String, index : Int32, current : Array(String)) : String
      result = remote_exec("matchpathcon -n #{shell_single_quote(path)}")
      if result[:exit_code] == 0 && (context = result[:stdout].strip.split[0]?)
        parts = context.split(':', 3)
        return parts[index] if parts.size > index
      end
      current[index]
    end

    private def secontext_changed?(path : String) : Bool
      return false unless secontext_requested?
      current = current_selinux_context(path)
      return false unless current
      desired_selinux_context(path, current) != current
    end

    # Applies the full context with `chcon -h` (Ansible's
    # lsetfilecon equivalent, symlink-aware), failing the task on a
    # nonzero exit like the Ansible module's fail_json(msg='set selinux
    # context failed').
    private def apply_secontext(path : String) : Nil
      return unless secontext_requested?
      current = current_selinux_context(path)
      return unless current
      desired = desired_selinux_context(path, current)
      return if desired == current

      result = remote_exec("chcon -h #{shell_single_quote(desired.join(':'))} #{shell_single_quote(path)}")
      if result[:exit_code] != 0
        raise "set selinux context failed"
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::TemplatePlugin.new(config)
plugin.run
