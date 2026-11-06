#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/text_file_io"
require "../src/krikri/plugin_helpers/block_editor"

module Krikri
  # Blockinfile plugin - inserts/updates/removes a marker-delimited block of
  # text in a file. Compatible with Ansible's ansible.builtin.blockinfile.
  #
  # Parameters:
  #   path (required, aliases: dest, destfile, name - matches Ansible's
  #     own argument_spec): File to edit
  #   block (alias content): Text to insert between the markers - a missing
  #     or empty block removes the block instead (Ansible's own
  #     "if present and block:" gate), which is not the same as state:
  #     absent for the prepend_newline/append_newline padding
  #   state: present (default) or absent
  #   marker: marker line template, {mark} replaced by marker_begin/marker_end
  #   marker_begin / marker_end: default "BEGIN" / "END"
  #   insertafter / insertbefore: EOF/BOF or a regexp (same LAST-match
  #     anchoring as lineinfile - via the shared LineEditor.insertion_index;
  #     Ansible has no firstmatch here) - mutually exclusive
  #   create: create the file if it doesn't exist (default: no)
  #   backup: write a timestamped backup before changing the file
  #   mode / owner / group: applied (unconditionally, like Ansible's
  #     check_file_attrs) via the same attr suite lineinfile uses
  #   attributes (alias: attr): chattr-style flags (e.g. "+i")
  #   seuser / serole / setype / selevel: SELinux context parts - graceful
  #     no-op on non-SELinux hosts, chcon on SELinux-enabled ones
  #   validate: command run against the staged content (%s = temp path)
  #     before the write lands
  #   unsafe_writes: fall back to a direct in-place write when the atomic
  #     rename into place fails
  #   append_newline / prepend_newline: pad the block with a blank line
  #     after/before it (skipped at EOF/BOF or when the neighbor is
  #     already blank)
  class BlockInFilePlugin < BasePlugin
    # ansible.builtin.blockinfile's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.blockinfile). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[append_newline backup create prepend_newline unsafe_writes]
    end

    DEFAULT_MARKER = "# {mark} ANSIBLE MANAGED BLOCK"

    def execute : PluginResult
      validate_bool_params!
      path = @params["path"]? || @params["dest"]? || @params["destfile"]? || @params["name"]?
      return missing_param("path") unless path
      path = expand_tilde(path)

      check_mode = true?(@params["_ansible_check_mode"]?)
      block = @params["block"]? || @params["content"]?
      # Ansible keeps `present` (state: present) and the block
      # separate: an empty/missing block makes it REMOVE the block, but a
      # state: present task is still "present" for the prepend_newline /
      # append_newline padding, which is why folding the two together here
      # silently dropped the blank line those flags add and reported ok
      # where Ansible reports changed (verified against 2.19.11).
      state = @params["state"]? || "present"

      if error = validate_params
        return error
      end

      # Ansible fails on a directory path before anything else
      # (fail_json rc=256, msg='Path %s is a directory !').
      if File.directory?(path)
        return PluginResult.new(changed: false, failed: true, msg: "Path #{path} is a directory !", rc: 256)
      end

      # Ansible: a missing file with state=absent and create=true
      # exits "File %s not present" WITHOUT creating anything - only
      # state=present (or an explicit need for the file) goes through the
      # create/fail logic below.
      if state == "absent" && !File.exists?(path) && true?(@params["create"]?)
        return PluginResult.new(changed: false, failed: false, msg: "File #{path} not present", key_order: BLOCK_KEY_ORDER)
      end

      being_created, error = ensure_file_exists(path, true?(@params["create"]?), check_mode)
      return error if error

      apply(path, state, block, being_created, check_mode)
    end

    # Ansible's argument_spec marks insertbefore/insertafter
    # mutually exclusive (live-verified against ansible-core 2.19.4:
    # giving both fails with "parameters are mutually exclusive:
    # insertbefore|insertafter").
    private def validate_params : PluginResult?
      if @params["insertafter"]? && @params["insertbefore"]?
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: insertbefore|insertafter")
      end

      nil
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    private def ensure_file_exists(path : String, create : Bool, check_mode : Bool) : {Bool, PluginResult?}
      return {false, nil} if File.exists?(path)

      unless create
        return {false, PluginResult.new(changed: false, failed: true, msg: "Path #{path} does not exist !", rc: 257,
          # Ansible's fail_json(rc=257, msg=...) puts the kwarg first: rc, failed,
          # msg, changed, exception (live-verified against 2.19.11, same
          # module_utils pattern as lineinfile's missing-dest failure)
          key_order: %w[rc failed msg changed exception])}
      end

      unless check_mode
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        # The dest didn't exist, so atomic_move's own relabel gives the
        # file matchpathcon's policy default context (issue #911).
        secontext = prewrite_selinux_context(path)
        File.write(path, "")
        if failure = relabel_written_file(path, secontext)
          return {false, failure}
        end
      end

      {true, nil}
    end

    private def apply(path : String, state : String, block : String?, being_created : Bool, check_mode : Bool) : PluginResult
      original_content, read_failure = read_as_text(path)
      return read_failure.not_nil! if read_failure
      marker_begin_line, marker_end_line = marker_lines
      # Ansible builds its marker-delimited block lines only from a
      # NON-EMPTY block (`if present and block:`), so the default empty
      # block: is a removal - Crystal's split would otherwise hand back
      # one empty line and re-create the markers around it.
      trimmed_block = block.try(&.rstrip("\n")) || ""
      block_lines = trimmed_block.empty? ? [] of String : trimmed_block.split("\n")
      # Ansible clears blocklines entirely for state=absent
      # (`if present and block: ... else: blocklines = []`), so the
      # block is never "present" on an absent run - the removal msg is
      # 'Block removed' even when block: was passed, and the render's
      # trailing-newline heuristic sees an absent block.
      block_present = state == "present" && !block_lines.empty?

      lines = split_lines(original_content)
      new_lines, _ = PluginHelpers::BlockEditor.apply(
        lines, marker_begin_line, marker_end_line, block_lines, state,
        @params["insertafter"]?, @params["insertbefore"]?,
        append_newline: true?(@params["append_newline"]?),
        prepend_newline: true?(@params["prepend_newline"]?)
      )
      new_content = render_content(new_lines, original_content, being_created, marker_end_line, block_present)

      # Ansible compares the whole file byte for byte (`original ==
      # result`), and a file it had to CREATE always counts as changed -
      # its `original` is None there, which can never equal the computed
      # content even when both are empty.
      changed = new_content != original_content || being_created

      backup_file, write_failure = persist(path, new_content, being_created, changed, check_mode)
      return write_failure if write_failure

      # The attribute baseline is the file's state BEFORE the attribute
      # pass below, together with the pending SELinux context change and
      # the current chattr flags (the diff payload reports what that pass
      # changes).
      attribute_baseline = File.info?(path)
      secontext_baseline = pending_secontext_change(path)
      attr_flags_baseline = current_attr_flags(path)

      # owner:/group:/mode:/attributes:/SELinux apply even when the block
      # content itself was already correct - Ansible's blockinfile
      # runs check_file_attrs unconditionally after the write, and its
      # attr_diff entry is built from that call's return, so an
      # attribute-only change (a secontext: change with the block already
      # in place) still reports changed and still carries before/after.
      attrs_changed = false
      if File.exists?(path)
        attrs_changed, attrs_failure = apply_file_attrs(path, check_mode)
        return attrs_failure if attrs_failure
      end
      changed = changed || !!attrs_changed

      diff = file_module_diff(path, original_content, new_content,
        attributes_diff_entry(path, attribute_baseline, secontext_baseline, attr_flags_baseline)) if changed && @diff_mode
      # Real blockinfile's wire result ALWAYS carries a `diff` key - the
      # same two-entry list lineinfile's does (a content diff and a
      # file-attributes diff; both before/after bodies empty outside
      # --diff mode, live-verified vs 2.19.11 via a registered result on
      # changed, unchanged and absent runs alike).
      diff ||= blockinfile_diff(path)

      # Real blockinfile's result carries ONLY changed + msg (empty msg
      # included explicitly on an already-correct re-run) plus a
      # backup_file only when a backup was actually taken - never a
      # path echo, never the file-common stat fields (live-verified vs
      # 2.19.11 at -v). Registered-result key order: changed, msg, diff
      # (, backup_file), failed.
      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: result_msg(being_created, changed, block_present),
        diff: diff,
        include_empty_msg: true,
        key_order: BLOCK_KEY_ORDER
      )
      result.extra["backup_file"] = JSON::Any.new(backup_file) unless backup_file.empty?
      result
    end

    # Real blockinfile's registered-result key order (live-verified vs
    # 2.19.11 via `{{ r | to_json }}`): changed, msg, diff, then
    # backup_file only when a backup was taken, then failed. The
    # "File X not present" missing-file early exit is just {changed,
    # msg} - the same constant reduces to that once the absent keys are
    # skipped.
    private BLOCK_KEY_ORDER = %w[changed msg diff backup_file failed]

    # Same shape as lineinfile's always-present diff list: a content
    # entry (before/after empty outside --diff mode) plus a
    # file-attributes entry with no before/after at all.
    private def blockinfile_diff(path : String) : JSON::Any
      file_module_diff(path, "", "")
    end

    # A file that had to be created reports "File created" even when the
    # block write happens in the same call - matches Ansible, verified
    # against a `ansible-playbook` run rather than assumed. Real picks
    # between the other two messages on whether it had any block lines to
    # insert (`elif not blocklines: 'Block removed'`), not on the state
    # value: a state: present task whose block is empty removes too.
    private def result_msg(being_created : Bool, changed : Bool, block_present : Bool) : String
      return "File created" if being_created && changed
      return "" unless changed
      block_present ? "Block inserted" : "Block removed"
    end

    private def marker_lines : {String, String}
      marker = @params["marker"]? || DEFAULT_MARKER
      marker_begin = @params["marker_begin"]? || "BEGIN"
      marker_end = @params["marker_end"]? || "END"
      {marker.sub("{mark}", marker_begin), marker.sub("{mark}", marker_end)}
    end

    private def split_lines(content : String) : Array(String)
      lines = content.split("\n")
      lines.pop if lines.size > 0 && lines.last.empty?
      lines
    end

    # Ansible's blocklines all carry their own trailing newline
    # (marker1 = marker.sub("{mark}", marker_end) + os.linesep), so when a
    # block ends the file the result ALWAYS ends with a newline - even
    # when the original file's last line didn't have one.
    private def render_content(new_lines : Array(String), original_content : String, being_created : Bool, marker_end_line : String, block_present : Bool) : String
      content = new_lines.join("\n")
      content += "\n" if new_lines.size > 0 && (original_content.ends_with?("\n") || (being_created && block_present) || (block_present && new_lines.last == marker_end_line))
      content
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

    # Ansible writes blockinfile's result through
    # AnsibleModule.atomic_move: a temp file whose content is validated
    # (validate:) and then RENAMED into place - same shape lineinfile.cr's
    # merged implementation already uses here. unsafe_writes: swaps the
    # rename for a direct in-place write when the rename fails (Ansible's own escape hatch for paths a rename can't touch, e.g.
    # /proc or container bind-mounts).
    #
    # Returns nil on success, or a failed PluginResult.
    # 2.21 opens the file in text mode with the task's `encoding:` (default
    # utf-8): the block is matched and inserted on decoded text and the
    # file keeps its own encoding, while content the codec cannot decode
    # fails the task with CPython's UnicodeDecodeError text.
    private def file_encoding : String
      @params["encoding"]?.presence || "utf-8"
    end

    private def read_as_text(path : String) : {String, PluginResult?}
      return {"", nil} unless File.exists?(path)
      text, error = PluginHelpers::TextFileIO.decode(File.read(path).to_slice, file_encoding)
      return {"", PluginResult.new(changed: false, failed: true, msg: error.not_nil!)} if error
      {text.not_nil!, nil}
    end

    private def write_with_optional_validate(path : String, content : String) : PluginResult?
      validate_cmd = @params["validate"]?
      if validate_cmd && !validate_cmd.includes?("%s")
        return PluginResult.new(changed: false, failed: true, msg: "validate must contain %s: #{validate_cmd}")
      end

      temp_file = File.join(File.dirname(path), ".krikri-playbook-blockinfile-#{Random::Secure.hex(8)}.tmp")
      begin
        # SECURITY: created EMPTY at 0600 and settled to its final mode
        # (the task's numeric mode:, else the dest's own mode as resolved
        # by the preservation block below) BEFORE the content lands -
        # see BasePlugin#create_staging_temp. The old write-first shape
        # held the bytes at 0644 & ~umask until the mode preservation
        # below ran after the write.
        create_staging_temp(temp_file, staging_temp_mode(path, 0o644))
        bytes, encode_failure = PluginHelpers::TextFileIO.encode(content, file_encoding)
        return PluginResult.new(changed: false, failed: true, msg: encode_failure.not_nil!) if encode_failure
        File.write(temp_file, bytes.not_nil!, perm: 0o600)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}")
      end

      if validate_cmd
        validation = validate_file(temp_file, validate_cmd)
        unless validation[:ok]
          # Left in place deliberately, same reasoning as copy.cr's
          # identical choice - the computed content is almost always
          # what's actually wrong, and the real dest was never touched.
          File.delete(temp_file) if File.exists?(temp_file) && temp_file.starts_with?(File.dirname(path))
          return PluginResult.new(changed: false, failed: true, msg: "failed to validate: rc:#{validation[:rc]} error:#{validation[:output]}")
        end
      end

      # Preserve an existing dest's ownership (the mode is already
      # settled on the empty temp above; a rename would otherwise reset
      # it to the temp file's). Best-effort chown,
      # same as copy.cr - non-root can't chown, and the rename still
      # yields a correct file.
      if !File.symlink?(path) && (info = File.info?(path, follow_symlinks: false))
        begin
          File.chown(temp_file, uid: info.owner_id.to_i, gid: info.group_id.to_i)
        rescue File::Error
          nil
        end
      end

      # Ansible's atomic_move resolves a symlink dest to its TARGET
      # (os.path.realpath) before renaming, so a blockinfile task pointing
      # at a symlink edits the file it points at rather than replacing
      # the symlink - and the previous in-place File.write here followed
      # it too, so keep that behavior.
      dest = File.symlink?(path) ? File.realpath(path) : path

      # atomic_move's context capture, read BEFORE the rename (issue
      # #911): the staged inode replaces dest's, so the dest has to be
      # relabelled to the context the write was meant to land on.
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
            return PluginResult.new(changed: false, failed: true, msg: encode_failure.not_nil!) if encode_failure
            File.write(dest, bytes.not_nil!, perm: 0o600)
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
    # temp path) - identical to copy.cr's/lineinfile.cr's own helper.
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

    private def write_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_file)
      backup_file
    end

    # basic.py's set_fs_attributes_if_different order: SELinux context
    # first, then owner/group/mode, then the chattr-style
    # attributes:/attr: flags (mirrors lineinfile.cr's apply_file_attrs,
    # which itself mirrors copy.cr's apply_extended_attributes). Returns
    # {changed, failure}: failure a failed PluginResult when the
    # chattr/chcon call itself errored. Skips the actual chmod/chown
    # under check_mode, matching every other check_mode-aware plugin in
    # this codebase.
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
    # template, lineinfile and stat use), so a context change is DETECTED
    # and counted as changed instead of blindly re-applied, "_default"
    # resolves through matchpathcon, and the parts merge into the file's
    # current context the way basic.py's set_context_if_different does.
    # Returns {changed, failure}; the failure is that fail_json's shape
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

    # ansible-core 2.21's file-attributes diff entry - see lineinfile.cr's
    # identical helper: real passes an `attr_diff` dict into
    # set_fs_attributes_if_different, which records before/after for every
    # attribute that changes and leaves the entry header-only otherwise.
    # `info` is the file's state BEFORE the attribute pass, `secontext`
    # and `attr_flags` its still-pending SELinux context change and
    # current chattr flags at the same moment.
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
        if (mode = @params["mode"]?) && mode.matches?(/^0?\d+$/)
          current_bits = info.permissions.value.to_i & 0o7777
          target_bits = mode.to_i(8)
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

    private def apply_mode_attr(path : String, info : File::Info, check_mode : Bool) : Bool
      return false unless mode = @params["mode"]?
      return false unless mode =~ /^0?\d+$/

      current = (info.permissions.value & 0o7777).to_s(8)
      target = mode.to_i(8).to_s(8)
      return false if current.lstrip('0').presence == target.lstrip('0').presence

      (File.chmod(path, mode.to_i(8)) rescue nil) unless check_mode
      true
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
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::BlockInFilePlugin.new(config)
plugin.run
