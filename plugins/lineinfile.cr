#!/usr/bin/env crystal

require "json"
require "file_utils"
require "system/user"
require "system/group"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/text_file_io"
require "../src/krikri/plugin_helpers/line_editor"
require "../src/krikri/plugin_helpers/python_pattern"

module Krikri
  # Lineinfile plugin - manages a single line in a text file
  # Compatible with Ansible's ansible.builtin.lineinfile module
  #
  # Parameters:
  #   path (required, aliases: dest, name - matches Ansible's own
  #     argument_spec, where `dest:` is the long-standing legacy alias
  #     most existing playbooks/roles still write): File to edit
  #   line: Line content (required for state: present, unless backrefs/regexp-only removal)
  #   regexp: Pattern used to find the line to replace/remove
  #   state: present (default) or absent
  #   create: Create the file if it doesn't exist (default: no)
  #   backup: Write a timestamped backup before changing the file (default: no)
  #   insertafter / insertbefore: EOF/BOF/END/BEGIN or a regexp
  #   backrefs: Substitute regexp match groups into `line` instead of replacing it wholesale
  #   firstmatch: Replace/anchor at the FIRST matching line instead of the last
  #   search_string: Literal-substring alternative to regexp (mutually exclusive with it)
  #   validate: Command run against the staged content (%s = temp path) before the write lands
  #   backup / create / owner / group / mode: as above
  #   attributes (alias: attr): chattr-style flags (e.g. "+i")
  #   seuser / serole / setype / selevel: SELinux context parts - graceful
  #     no-op on non-SELinux hosts, chcon on SELinux-enabled ones
  #   unsafe_writes: fall back to a direct in-place write when the atomic
  #     rename into place fails
  class LineInFilePlugin < BasePlugin
    # ansible.builtin.lineinfile's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.lineinfile). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[backrefs backup create firstmatch unsafe_writes]
    end

    def execute : PluginResult
      path = @params["path"]? || @params["dest"]? || @params["name"]?
      return missing_param("path") unless path
      path = expand_tilde(path)
      validate_bool_params!

      line = @params["line"]?
      # An explicit None line (`line: "{{ item }}"` with a null item, or a
      # bare `line:`) rode the wire as NONE_SENTINEL and BasePlugin demoted
      # it to "" - but ansible-core sees Python None and rejects the task
      # with "line is required with state=present", while a real "" stays a
      # legitimate (empty) line. Restoring nil makes the validate checks
      # above fire the same way Ansible's module does.
      line = nil if explicit_null_param?("line")
      # `regex` is Ansible's own argument-spec alias for `regexp`
      # (ansible-core lineinfile: regexp=dict(type='str', aliases=['regex'])).
      # Found via ryezone_labs.sssd: its "remove mkhomedir from
      # /var/lib/pam/seen" task passes `regex:` with state=absent - real
      # Ansible accepts it and removes the lines; without the alias here the
      # alias-suffixed param was silently ignored and the task failed with
      # "one of line, search_string, or regexp is required with state=absent".
      regexp = @params["regexp"]? || @params["regex"]?
      search_string = @params["search_string"]?
      firstmatch = true?(@params["firstmatch"]?)
      backrefs = true?(@params["backrefs"]?)
      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)

      if error = validate(state, line, regexp, search_string, backrefs)
        return error
      end

      # `state: absent` on a file that doesn't exist at all is a real-
      # Ansible no-op ("file not present", changed: false) - there's
      # nothing to remove a line *from*. Only `state: present` (or an
      # explicit `create: true`) needs the file to actually exist.
      # Found via konstruktoid-hardening's "Clean cron and at" task,
      # `state: absent` on /etc/at.allow/cron.allow, neither of which
      # exist on a stock image - failed outright instead of no-op'ing.
      if state == "absent" && !File.exists?(path)
        return PluginResult.new(changed: false, failed: false, msg: "file not present", key_order: ABSENT_KEY_ORDER)
      end

      being_created, error = ensure_file_exists(path, true?(@params["create"]?), check_mode)
      return error if error

      # Real lineinfile.py compiles regexp: - and, for state=present, a
      # non-literal insertafter:/insertbefore: anchor - with a bare
      # re.compile that no except clause catches, so an invalid pattern
      # crashes the module ("Task failed: Module failed: unterminated
      # character set at position 1", RedHatGov.director's
      # `regexp: "^{{ director_public_ip }}"` with its list-typed default
      # rendering to "[]") instead of silently matching nothing and
      # reporting changed/ok. The compile sits AFTER the destination
      # checks, so a missing dest without create: still fails with
      # "Destination ... does not exist !" and absent: on a missing file
      # still no-ops with "file not present". Also issue #869:
      # RedHatGov.content's `regexp: "^{{ content_public_ip }}"` with its
      # own empty-list default, the same "^[]" shape.
      if detail = regex_compile_error(state, regexp, @params["insertafter"]?, @params["insertbefore"]?)
        # Real present() compiles only after the missing-dest checks but
        # before ANY write (the create:true file materializes in
        # write_changes at the very end), so a crash there leaves no file
        # behind - undo the eager creation here for the same side effects.
        File.delete(path) if being_created && !check_mode && File.exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "Task failed: Module failed: #{detail}",
          _ansible_error_detail: detail)
      end

      apply(path, state, line, regexp, search_string, firstmatch, being_created, check_mode)
    end

    # nil when every pattern real Ansible's lineinfile would re.compile
    # accepts (and compiles), otherwise the re.error detail text the
    # module crash carries. Order mirrors real check_present(): the
    # bare re.compile calls run regexp first, then the anchor - so when
    # both are invalid the regexp's error is the one reported.
    private def regex_compile_error(state : String, regexp : String?, insertafter : String?, insertbefore : String?) : String?
      patterns = [] of String
      patterns << regexp if regexp
      # Real compiles the anchor only in check_present (state=present;
      # absent never touches insertafter/insertbefore) and only when it
      # is a real pattern: BOF/EOF spellings for insertafter and BOF for
      # insertbefore are literals, everything else is re.compile'd.
      if state == "present"
        patterns << insertafter if insertafter && insertafter != "BOF" && insertafter != "EOF"
        patterns << insertbefore if insertbefore && insertbefore != "BOF"
      end

      patterns.each do |pattern|
        if detail = PythonPattern.python_error(pattern)
          return detail
        end
      end
      nil
    end

    # Parameter validation shared by both states. Also enforces the
    # mutually-exclusive pairs Ansible's own argument_spec declares
    # (live-verified against ansible-core 2.19.4: giving both fails with
    # "parameters are mutually exclusive: regexp|search_string" etc.).
    private def validate(state : String, line : String?, regexp : String?, search_string : String?, backrefs : Bool) : PluginResult?
      if regexp && search_string
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: regexp|search_string")
      end

      if backrefs && search_string
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: backrefs|search_string")
      end

      if state == "present"
        if backrefs && !regexp
          return PluginResult.new(changed: false, failed: true, msg: "regexp is required with backrefs=true")
        end

        return PluginResult.new(changed: false, failed: true, msg: "line is required with state=present") unless line
      end

      if state == "absent" && !regexp && !search_string && !line
        return PluginResult.new(changed: false, failed: true, msg: "one of line, search_string, or regexp is required with state=absent")
      end

      nil
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    # Returns {being_created, error}. Creates an empty file (unless
    # check_mode) when it's missing and `create:` was requested.
    private def ensure_file_exists(path : String, create : Bool, check_mode : Bool) : {Bool, PluginResult?}
      return {false, nil} if File.exists?(path)

      unless create
        return {false, PluginResult.new(changed: false, failed: true, msg: "Destination #{path} does not exist !", rc: 257,
          # Ansible's fail_json(rc=257, msg=...) puts the kwarg first: rc, failed,
          # msg, changed, exception (live-verified against 2.19.11)
          key_order: %w[rc failed msg changed exception])}
      end

      unless check_mode
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        # Real creates a missing file via atomic_move at Python's default
        # 0666 & ~umask - NOT File.write's 0644 default. The task's
        # mode: is applied afterwards by set_fs_attributes_if_different
        # and its drift feeds the "and ownership, perms or SE linux
        # context changed" msg suffix (live-verified vs 2.19.11).
        # The dest didn't exist, so atomic_move's own relabel gives it
        # matchpathcon's policy default context (issue #911).
        secontext = prewrite_selinux_context(path)
        File.write(path, "")
        File.chmod(path, 0o666 & ~creation_umask)
        if failure = relabel_written_file(path, secontext)
          return {false, failure}
        end
      end

      {true, nil}
    end

    # Reads the file, runs the appropriate LineEditor operation, and writes
    # the result back (unless check_mode). Lines carry their terminators
    # (Ansible's binary-mode readlines view) - the joined list IS the new
    # file content, byte for byte.
    private def apply(path : String, state : String, line : String?, regexp : String?, search_string : String?, firstmatch : Bool, being_created : Bool, check_mode : Bool) : PluginResult
      original_content, read_failure = read_as_text(path)
      return read_failure if read_failure
      original_lines = PluginHelpers::LineEditor.split_lines(original_content)

      new_lines, changed, msg, found =
        if state == "absent"
          kept, removed, count = PluginHelpers::LineEditor.remove_matching(original_lines, line, regexp, search_string)
          {kept, removed, removed ? "#{count} line(s) removed" : "", count}
        else
          edited, edited_changed, edited_msg = PluginHelpers::LineEditor.ensure_present(
            original_lines, (line || raise "lineinfile: line is required"), regexp, search_string,
            @params["insertafter"]?, @params["insertbefore"]?, true?(@params["backrefs"]?), firstmatch)
          {edited, edited_changed, edited_msg, 0}
        end
      new_content = new_lines.join

      backup_file, write_failure = persist(path, new_content, being_created, changed, check_mode)
      return write_failure if write_failure

      # The attribute baseline is the file's state BEFORE the attribute
      # pass below (the diff payload reports what that pass changes) -
      # the pending SELinux context change and the current chattr flags
      # are read at the same moment, for the same reason.
      attribute_baseline = File.info?(path)
      secontext_baseline = pending_secontext_change(path)
      attr_flags_baseline = current_attr_flags(path)

      # owner:/group:/mode: apply even when the line content itself was
      # already correct - Ansible's lineinfile module runs the
      # generic file-attribute check unconditionally via
      # set_fs_attributes_if_different, so a mode-only drift (task's
      # mode: differs from the file's current mode, no line insertion
      # needed) still reports changed: true. Found via robertdebock's
      # grub role: `GRUB_TIMEOUT=5` already present in /etc/default/grub
      # on a fresh Rocky 9.6 image, but the task's own `mode: "0664"`
      # didn't match the file's actual 0644 - crystal previously never
      # even looked at the mode param once no line edit was needed.
      attrs_changed = false
      if File.exists?(path)
        begin
          attrs_changed, attrs_failure = apply_file_attrs(path, check_mode)
        rescue InvalidModeError
          # basic.py's set_mode_if_different rejects a mode: that is
          # neither octal nor valid chmod(1) symbolic syntax with this
          # exact msg - before the symbolic-mode support above, such a
          # value was silently ignored here instead.
          return PluginResult.new(changed: false, failed: true, msg: "mode must be in octal or symbolic form")
        end
        return attrs_failure if attrs_failure
      end
      changed = changed || !!attrs_changed

      # Real lineinfile's diff list: the content entry (before/after text,
      # file created or modified alike) plus the file-attributes entry.
      diff = file_module_diff(path, original_content, new_content,
        attributes_diff_entry(path, attribute_baseline, secontext_baseline, attr_flags_baseline)) if changed && @diff_mode

      line_result(path, state, changed, msg, backup_file, found, !!attrs_changed, diff)
    end

    # Ansible's per-branch msg strings (live-verified against
    # ansible-core 2.19.11 ad-hoc: 'line added' when the line is
    # newly inserted (including into a just-created file), 'line
    # replaced' when an existing line matched and was rewritten in
    # place, '%d line(s) removed' for state: absent, and an empty
    # msg when nothing changed - the previous single generic 'Line
    # modified' for every changed=true case came from an ad-hoc CLI
    # comparison sweep against Ansible, 2026-09-13), plus
    # Ansible's own check_file_attrs suffix when the file's
    # owner/group/mode/SELinux attributes were what changed.
    # Ansible's state=absent exit also carries a `found` count of the
    # removed lines (its present-path exit does not); the backup path
    # goes out under the key `backup` ("" when none), not blockinfile's
    # `backup_file`.
    # Ansible.builtin.lineinfile's registered-result key order
    # (live-verified vs 2.19.11 via `{{ r | to_json }}` on registered
    # lineinfile: tasks): state=present runs changed, msg, backup, diff,
    # failed - backup: "" even when no backup was taken, msg: "" on an
    # already-correct re-run - while state=absent leads with a `found`
    # count right after changed: changed, found, msg, backup, diff,
    # failed. Check mode keeps the same order per state. The missing-
    # file "file not present" early exit is just {changed, msg} - both
    # constants reduce to that once the absent keys are skipped.
    private PRESENT_KEY_ORDER = %w[changed msg backup diff failed]
    private ABSENT_KEY_ORDER  = %w[changed found msg backup diff failed]

    private def line_result(path : String, state : String, changed : Bool, msg : String, backup_file : String, found : Int32, attrs_changed : Bool, diff : JSON::Any?) : PluginResult
      if attrs_changed
        msg += " and " unless msg.empty?
        msg += "ownership, perms or SE linux context changed"
      end

      # Ansible.builtin.lineinfile's return value carries no `path`,
      # `line` or `state` keys in either state - only backup/changed/msg
      # (plus `found` for state=absent). It also passes msg='' explicitly,
      # so the empty-string `msg` key stays in the wire result.
      if state == "absent"
        PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          include_empty_msg: true,
          diff: diff || lineinfile_diff(path),
          backup: backup_file,
          found: found,
          key_order: ABSENT_KEY_ORDER
        )
      else
        PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          include_empty_msg: true,
          diff: diff || lineinfile_diff(path),
          backup: backup_file,
          key_order: PRESENT_KEY_ORDER
        )
      end
    end

    # Backup first (Ansible's backup_local also runs before its own
    # write_changes), then the actual write. Returns {backup_file,
    # failure}: failure a failed PluginResult when the write/validate
    # path itself failed.
    private def persist(path : String, new_content : String, being_created : Bool, changed : Bool, check_mode : Bool) : {String, PluginResult?}
      backup_file = should_backup?(being_created, changed, path, check_mode) ? write_backup(path) : ""
      return {backup_file, nil} if !changed || check_mode

      if failure = write_with_optional_validate(path, new_content)
        return {backup_file, failure}
      end

      {backup_file, nil}
    end

    # Ansible writes lineinfile's result through
    # AnsibleModule.atomic_move: a temp file whose content is validated
    # (validate:) and then RENAMED into place - same shape copy.cr's
    # merged implementation already uses here. unsafe_writes: swaps the
    # rename for a direct in-place write when the rename fails (Ansible's own escape hatch for paths a rename can't touch, e.g.
    # /proc or container bind-mounts).
    #
    # Ansible's atomic_move resolves a symlink dest to its TARGET
    # (os.path.realpath) BEFORE creating the temp file, so the temp
    # always lands in the real dest's directory and the rename never
    # crosses a filesystem; building it next to the symlink instead
    # fails with EXDEV when the target is on another filesystem
    # (issue #129). Resolving to the target is also what makes a
    # lineinfile task pointing at a symlink edit the file it points at
    # rather than replacing the symlink - and the previous in-place
    # File.write here followed it too, so keep that behavior.
    #
    # Returns nil on success, or a failed PluginResult.
    # ansible-core 2.21's file-attributes diff entry: the module passes an
    # `attr_diff` dict into set_fs_attributes_if_different, which records
    # `before`/`after` for every attribute that actually changes - and the
    # entry degenerates to its two headers when nothing did. `info` is the
    # file's state BEFORE the attribute pass and `secontext`/
    # `attr_flags` its still-pending SELinux context change and current
    # chattr flags, captured at the same moment (the setters run in
    # secontext, owner, group, mode, attributes order and record as they
    # go).
    private def attributes_diff_entry(path : String, info : File::Info?, secontext : {Array(String), Array(String)}?, attr_flags : String) : JSON::Any
      before = {} of String => JSON::Any
      after = {} of String => JSON::Any
      if current_and_desired = secontext
        current, desired = current_and_desired
        before["secontext"] = JSON::Any.new(current.map { |part| JSON::Any.new(part) })
        after["secontext"] = JSON::Any.new(desired.map { |part| JSON::Any.new(part) })
      end
      if info
        if (owner = @params["owner"]?) && !owner.empty?
          uid = resolve_owner_uid(owner)
          unless info.owner_id.to_s == uid.to_s
            before["owner"] = JSON::Any.new(info.owner_id.to_i64)
            after["owner"] = JSON::Any.new(uid.to_i64)
          end
        end
        if (group = @params["group"]?) && !group.empty?
          gid = resolve_group_gid(group)
          unless info.group_id.to_s == gid.to_s
            before["group"] = JSON::Any.new(info.group_id.to_i64)
            after["group"] = JSON::Any.new(gid.to_i64)
          end
        end
        if mode = @params["mode"]?
          current_bits = mode_current_bits(info)
          target_bits = mode_target_bits(current_bits, mode)
          if current_bits != target_bits
            before["mode"] = JSON::Any.new("0#{current_bits.to_s(8).rjust(3, '0')}")
            after["mode"] = JSON::Any.new("0#{target_bits.to_s(8).rjust(3, '0')}")
          end
        end
        if parsed = attr_args
          mod, flags = parsed
          if attr_flags != flags || mod == '-'
            before["attributes"] = JSON::Any.new(attr_flags)
            after["attributes"] = JSON::Any.new(mod == '=' ? flags : "#{mod}#{flags}")
          end
        end
      end

      entry = {} of String => JSON::Any
      unless before.empty?
        entry["before"] = JSON::Any.new(before)
        entry["after"] = JSON::Any.new(after)
      end
      entry["before_header"] = JSON::Any.new("#{path} (file attributes)")
      entry["after_header"] = JSON::Any.new("#{path} (file attributes)")
      JSON::Any.new(entry)
    end

    private def mode_current_bits(info : File::Info) : Int32
      info.permissions.value.to_i & 0o7777
    end

    # 2.21 opens the destination in text mode with the task's `encoding:`
    # (default utf-8), so undecodable content fails the task with CPython's
    # own UnicodeDecodeError text instead of being edited byte-wise. The
    # file is decoded to UTF-8 for editing and re-encoded on the way out.
    private def file_encoding : String
      @params["encoding"]?.presence || "utf-8"
    end

    private def read_as_text(path : String) : {String, PluginResult?}
      return {"", nil} unless File.exists?(path)
      text, error = PluginHelpers::TextFileIO.decode(File.read(path).to_slice, file_encoding)
      return {"", PluginResult.new(changed: false, failed: true, msg: error)} if error
      {text, nil}
    end

    private def write_with_optional_validate(path : String, content : String) : PluginResult?
      validate_cmd = @params["validate"]?
      if validate_cmd && !validate_cmd.includes?("%s")
        return PluginResult.new(changed: false, failed: true, msg: "validate must contain %s: #{validate_cmd}")
      end

      dest = File.symlink?(path) ? File.realpath(path) : path
      temp_file = File.join(File.dirname(dest), ".krikri-playbook-lineinfile-#{Random::Secure.hex(8)}.tmp")
      begin
        # SECURITY: created EMPTY at 0600 and settled to its final mode
        # (0666 & ~umask for a new dest - Ansible's atomic_move gives a new
        # file Python's default 0666 & ~umask and does NOT pre-apply the
        # task's mode:, which set_fs_attributes_if_different then
        # applies AFTER the move, reporting the drift as the "and
        # ownership, perms or SE linux context changed" msg suffix;
        # live-verified vs 2.19.11 - an existing dest keeps its own
        # mode the same way) BEFORE the content lands - see
        # BasePlugin#create_staging_temp. The old write-first shape
        # held the bytes at 0644 & ~umask until the mode preservation
        # below ran after the write.
        create_staging_temp(temp_file, staging_temp_mode(path, 0o666, apply_task_mode: false))
        bytes, encode_failure = PluginHelpers::TextFileIO.encode(content, file_encoding)
        return PluginResult.new(changed: false, failed: true, msg: encode_failure) if encode_failure
        File.write(temp_file, bytes, perm: 0o600)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}")
      end

      if validate_cmd
        validation = validate_file(temp_file, validate_cmd)
        unless validation[:ok]
          # Left in place deliberately, same reasoning as copy.cr's
          # identical choice - the computed content is almost always
          # what's actually wrong, and the real dest was never touched.
          File.delete(temp_file) if File.exists?(temp_file) && temp_file.starts_with?(File.dirname(dest))
          return PluginResult.new(changed: false, failed: true, msg: "failed to validate: rc:#{validation[:rc]} error:#{validation[:output]}")
        end
      end

      # Preserve an existing dest's ownership (the mode is already
      # settled on the empty temp above; a rename would otherwise reset
      # it to the temp file's). Read the owner off dest itself - the
      # realpath - so a symlinked dest keeps its target's owner the
      # same way a plain dest keeps its own (the symlink's own owner
      # is a different identity, frequently root's). Best-effort
      # chown, same as copy.cr - non-root can't chown, and the rename
      # still yields a correct file.
      if (info = File.info?(dest, follow_symlinks: false))
        begin
          File.chown(temp_file, uid: info.owner_id.to_i, gid: info.group_id.to_i)
        rescue File::Error
          nil
        end
      end

      # atomic_move's context capture, read BEFORE the rename (issue
      # #911): the staged inode replaces dest's, so the dest has to be
      # relabelled to the context the write was meant to land on (an
      # existing dest's own, a new one's policy default).
      secontext = prewrite_selinux_context(dest)

      begin
        File.rename(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        if true?(@params["unsafe_writes"]?)
          begin
            unless File.exists?(dest)
              create_staging_temp(dest, staging_temp_mode(dest, 0o644, preserve_dest_mode: false))
            end
            bytes, encode_failure = PluginHelpers::TextFileIO.encode(content, file_encoding)
            return PluginResult.new(changed: false, failed: true, msg: encode_failure) if encode_failure
            File.write(dest, bytes, perm: 0o600)
          rescue ex
            return PluginResult.new(changed: false, failed: true, msg: "Failed to write file (unsafe_writes fallback): #{ex.message}")
          end
          return relabel_written_file(dest, secontext)
        end
        return PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}")
      end

      relabel_written_file(dest, secontext)
    end

    # Runs the validate: command (with %s substituted by the staged
    # temp path) - identical to copy.cr's own helper.
    private def validate_file(path : String, validate_cmd : String) : NamedTuple(ok: Bool, rc: Int32, output: String)
      cmd = validate_cmd.gsub("%s", shell_single_quote(path))
      output = IO::Memory.new

      result = Process.run(
        "/bin/sh",
        ["-c", cmd],
        output: output,
        error: output
      )

      {ok: result.exit_code == 0, rc: result.exit_code, output: output.to_s.strip}
    end

    private def should_backup?(being_created : Bool, changed : Bool, path : String, check_mode : Bool) : Bool
      return false if being_created || check_mode || !changed
      true?(@params["backup"]?) && File.exists?(path)
    end

    # Real lineinfile's wire result ALWAYS carries a `diff` key (live-
    # verified vs 2.19.11, any verbosity - the display layer strips it
    # below -vvv): a LIST of two entries - a content diff (whose
    # before/after text is empty for these runs) and a file-attributes
    # diff (which never carries before/after at all).
    private def lineinfile_diff(path : String) : JSON::Any
      file_module_diff(path, "", "")
    end

    # basic.py's set_fs_attributes_if_different order: SELinux context
    # first, then owner/group/mode, then the chattr-style
    # attributes:/attr: flags (mirrors copy.cr's
    # apply_extended_attributes - running chattr last matters: an
    # immutable file would break the setters after it). Returns
    # {changed, failure}: failure a failed PluginResult when the
    # chattr/chcon call itself errored. Returns whether anything was
    # actually changed (skips the actual chmod/chown under check_mode,
    # matching every other check_mode-aware plugin in this codebase).
    private def apply_file_attrs(path : String, check_mode : Bool) : {Bool, PluginResult?}
      info = begin
        File.info(path)
      rescue
        return {false, nil}
      end

      secontext_changed, failure = apply_secontext(path, check_mode)
      return {false, failure} if failure
      changed = secontext_changed

      changed = apply_mode_attr(path, info, check_mode) || changed
      changed = apply_owner_attr(path, info, check_mode) || changed
      changed = apply_group_attr(path, info, check_mode) || changed

      attr_changed, failure = apply_attr(path, check_mode)
      return {false, failure} if failure
      changed = changed || attr_changed

      {changed, nil}
    end

    # attributes:/attr: (chattr flags, e.g. "+i" for immutable) -
    # mirrors file.cr/copy.cr/template.cr's proven implementations
    # exactly (same helper names, same semantics, including
    # Ansible's non-converging '-'-prefixed quirk,
    # ansible/ansible#33745).
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
    # unsupported filesystem like tmpfs) is empty flags, not an error -
    # the chattr call is what surfaces those as task failures later.
    private def current_attr_flags(path : String) : String
      result = remote_exec("lsattr -d #{shell_single_quote(path)}")
      return "" unless result[:exit_code] == 0
      fields = result[:stdout].strip.split
      return "" if fields.empty?
      fields[0].delete('-').strip
    end

    private def attr_changed?(path : String) : Bool
      parsed = attr_args
      return false unless parsed
      mod, flags = parsed
      return false if flags.empty?
      current_attr_flags(path) != flags || mod == '-'
    end

    # Applies the attributes: param via the real chattr binary and fails
    # the task (like Ansible's fail_json(msg='chattr failed')) when
    # chattr exits nonzero or writes to stderr.
    private def apply_attr(path : String, check_mode : Bool) : {Bool, PluginResult?}
      return {false, nil} unless attr_changed?(path)

      parsed = attr_args
      return {false, nil} unless parsed
      mod, flags = parsed

      unless check_mode
        result = remote_exec("chattr #{mod}#{flags} #{shell_single_quote(path)}")
        if result[:exit_code] != 0 || !result[:stderr].strip.empty?
          return {false, PluginResult.new(changed: false, failed: true, msg: "chattr failed - Error while setting attributes: #{result[:stdout]}#{result[:stderr]}")}
        end
      end

      {true, nil}
    end

    # seuser:/serole:/setype:/selevel: - the SELinux file context, applied
    # through BasePlugin's shared helpers (the same ones file, copy,
    # template and stat use), so a context change is DETECTED and counted
    # as changed instead of blindly re-applied, "_default" resolves
    # through matchpathcon, and the parts merge into the file's current
    # context the way basic.py's set_context_if_different does. Returns
    # {changed, failure}; the failure is that fail_json's shape
    # (msg='invalid selinux context: <err>', path, cur_context,
    # new_context, input_was).
    private def apply_secontext(path : String, check_mode : Bool) : {Bool, PluginResult?}
      return {false, nil} unless pending = pending_secontext_change(path)
      current, desired = pending

      # set_context_if_different returns changed BEFORE calling
      # lsetfilecon in check mode, so a --check run reports the pending
      # context change and writes nothing.
      return {true, nil} if check_mode

      if err = set_selinux_context(path, desired)
        return {false, selinux_context_failure(path, err, current, desired, secontext_input_was)}
      end

      {true, nil}
    end

    private def apply_mode_attr(path : String, info : File::Info, check_mode : Bool) : Bool
      return false unless mode = @params["mode"]?

      current = mode_current_bits(info)
      target = mode_target_bits(current, mode)
      return false if current == target

      (File.chmod(path, target) rescue nil) unless check_mode
      true
    end

    # The task's mode: as permission bits, resolving the symbolic
    # spelling (`go-rwx`, `u-x,go-rwx`) against the file's CURRENT bits
    # the way chmod(1) and ansible-core's _symbolic_mode_to_octal do.
    # The previous octal-only test dropped every symbolic mode on the
    # floor: the file kept its package mode while ansible chmod'ed it,
    # so ansible-lockdown.ubuntu24_stig's `mode: 'go-rwx'` on
    # sshd_config and `mode: 'u-x,go-rwx'` on the audit plugins left
    # 0644 here against ansible's 0600 - reported ok on both sides, so
    # only the later stat listings showed the drift (issue #983).
    private def mode_target_bits(current : Int32, mode : String) : Int32
      mode =~ /^0?\d+$/ ? mode.to_i(8) : resolve_symbolic_mode(current, mode)
    end

    private def apply_owner_attr(path : String, info : File::Info, check_mode : Bool) : Bool
      return false unless owner = @params["owner"]?
      uid = resolve_owner_uid(owner)
      return false if info.owner_id.to_s == uid.to_s

      (File.chown(path, uid: uid, gid: -1) rescue nil) unless check_mode
      true
    end

    private def apply_group_attr(path : String, info : File::Info, check_mode : Bool) : Bool
      return false unless group = @params["group"]?
      gid = resolve_group_gid(group)
      return false if info.group_id.to_s == gid.to_s

      (File.chown(path, uid: -1, gid: gid) rescue nil) unless check_mode
      true
    end

    private def write_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_file)
      backup_file
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::LineInFilePlugin.new(config)
plugin.run
