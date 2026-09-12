#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/block_editor"

module Krikri
  # Blockinfile plugin - inserts/updates/removes a marker-delimited block of
  # text in a file. Compatible with Ansible's ansible.builtin.blockinfile.
  #
  # Parameters:
  #   path (required, aliases: dest, destfile, name - matches real Ansible's
  #     own argument_spec): File to edit
  #   block (alias content): Text to insert between the markers - a missing
  #     or empty block is treated as state: absent, matching real Ansible
  #   state: present (default) or absent
  #   marker: marker line template, {mark} replaced by marker_begin/marker_end
  #   marker_begin / marker_end: default "BEGIN" / "END"
  #   insertafter / insertbefore: EOF/BOF or a regexp (same LAST-match
  #     anchoring as lineinfile - via the shared LineEditor.insertion_index;
  #     real Ansible has no firstmatch here) - mutually exclusive
  #   create: create the file if it doesn't exist (default: no)
  #   backup: write a timestamped backup before changing the file
  #   mode / owner / group: applied (unconditionally, like real Ansible's
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
    DEFAULT_MARKER = "# {mark} ANSIBLE MANAGED BLOCK"

    def execute : PluginResult
      path = @params["path"]? || @params["dest"]? || @params["destfile"]? || @params["name"]?
      return missing_param("path") unless path
      path = expand_tilde(path)

      check_mode = true?(@params["check_mode"]?)
      block = @params["block"]? || @params["content"]?
      state = block.nil? || block.empty? ? "absent" : (@params["state"]? || "present")

      if error = validate_params
        return error
      end

      # Real Ansible fails on a directory path before anything else
      # (fail_json rc=256, msg='Path %s is a directory !').
      if File.directory?(path)
        return PluginResult.new(changed: false, failed: true, msg: "Path #{path} is a directory !")
      end

      # Real Ansible: a missing file with state=absent and create=true
      # exits "File %s not present" WITHOUT creating anything - only
      # state=present (or an explicit need for the file) goes through the
      # create/fail logic below.
      if state == "absent" && !File.exists?(path) && true?(@params["create"]?)
        return PluginResult.new(changed: false, failed: false, msg: "File #{path} not present")
      end

      being_created, error = ensure_file_exists(path, true?(@params["create"]?), check_mode)
      return error if error

      apply(path, state, block, being_created, check_mode)
    end

    # Real Ansible's argument_spec marks insertbefore/insertafter
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
        return {false, PluginResult.new(changed: false, failed: true, msg: "Path #{path} does not exist!")}
      end

      unless check_mode
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, "")
      end

      {true, nil}
    end

    private def apply(path : String, state : String, block : String?, being_created : Bool, check_mode : Bool) : PluginResult
      original_content = File.exists?(path) ? File.read(path) : ""
      marker_begin_line, marker_end_line = marker_lines
      block_lines = block ? block.rstrip("\n").split("\n") : [] of String

      lines = split_lines(original_content)
      new_lines, changed = PluginHelpers::BlockEditor.apply(
        lines, marker_begin_line, marker_end_line, block_lines, state,
        @params["insertafter"]?, @params["insertbefore"]?,
        append_newline: true?(@params["append_newline"]?),
        prepend_newline: true?(@params["prepend_newline"]?)
      )
      new_content = render_content(new_lines, original_content, being_created, marker_end_line, !block_lines.empty?)

      backup_file, write_failure = persist(path, new_content, being_created, changed, check_mode)
      return write_failure if write_failure

      diff = generate_unified_diff(original_content, new_content, path, path) if changed && @diff_mode

      # owner:/group:/mode:/attributes:/SELinux apply even when the block
      # content itself was already correct - real Ansible's blockinfile
      # runs check_file_attrs unconditionally after the write.
      attrs_changed = false
      if File.exists?(path)
        attrs_changed, attrs_failure = apply_file_attrs(path, check_mode)
        return attrs_failure if attrs_failure
      end
      changed = changed || !!attrs_changed

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: result_msg(being_created, changed, state),
        diff: diff,
        path: path,
        backup_file: backup_file
      )
    end

    # A file that had to be created reports "File created" even when the
    # block write happens in the same call - matches real Ansible, verified
    # against a real `ansible-playbook` run rather than assumed.
    private def result_msg(being_created : Bool, changed : Bool, state : String) : String
      return "File created" if being_created && changed
      return "" unless changed
      state == "absent" ? "Block removed" : "Block inserted"
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

    # Real Ansible's blocklines all carry their own trailing newline
    # (marker1 = marker.sub("{mark}", marker_end) + os.linesep), so when a
    # block ends the file the result ALWAYS ends with a newline - even
    # when the original file's last line didn't have one.
    private def render_content(new_lines : Array(String), original_content : String, being_created : Bool, marker_end_line : String, block_present : Bool) : String
      content = new_lines.join("\n")
      content += "\n" if new_lines.size > 0 && (original_content.ends_with?("\n") || (being_created && block_present) || (block_present && new_lines.last == marker_end_line))
      content
    end

    # Backup first (real Ansible's backup_local also runs before its own
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

    # Real Ansible writes blockinfile's result through
    # AnsibleModule.atomic_move: a temp file whose content is validated
    # (validate:) and then RENAMED into place - same shape lineinfile.cr's
    # merged implementation already uses here. unsafe_writes: swaps the
    # rename for a direct in-place write when the rename fails (real
    # Ansible's own escape hatch for paths a rename can't touch, e.g.
    # /proc or container bind-mounts).
    #
    # Returns nil on success, or a failed PluginResult.
    private def write_with_optional_validate(path : String, content : String) : PluginResult?
      validate_cmd = @params["validate"]?
      if validate_cmd && !validate_cmd.includes?("%s")
        return PluginResult.new(changed: false, failed: true, msg: "validate must contain %s: #{validate_cmd}")
      end

      temp_file = File.join(File.dirname(path), ".krikri-playbook-blockinfile-#{Random::Secure.hex(8)}.tmp")
      begin
        File.write(temp_file, content)
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

      # Preserve an existing dest's mode/ownership (a rename would
      # otherwise reset them to the temp file's). Best-effort chown,
      # same as copy.cr - non-root can't chown, and the rename still
      # yields a correct file.
      if !File.symlink?(path) && (info = File.info?(path, follow_symlinks: false))
        begin
          File.chmod(temp_file, info.permissions)
          File.chown(temp_file, uid: info.owner_id.to_i, gid: info.group_id.to_i)
        rescue ex : File::Error
          nil
        end
      end

      # Real Ansible's atomic_move resolves a symlink dest to its TARGET
      # (os.path.realpath) before renaming, so a blockinfile task pointing
      # at a symlink edits the file it points at rather than replacing
      # the symlink - and the previous in-place File.write here followed
      # it too, so keep that behavior.
      dest = File.symlink?(path) ? File.realpath(path) : path

      begin
        File.rename(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        if true?(@params["unsafe_writes"]?)
          begin
            File.write(dest, content)
          rescue ex
            return PluginResult.new(changed: false, failed: true, msg: "Failed to write file (unsafe_writes fallback): #{ex.message}")
          end
          return nil
        end
        return PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}")
      end

      nil
    end

    # Runs the validate: command (with %s substituted by the staged
    # temp path) - identical to copy.cr's/lineinfile.cr's own helper.
    private def validate_file(path : String, validate_cmd : String) : NamedTuple(ok: Bool, rc: Int32, output: String)
      cmd = validate_cmd.gsub("%s", path)
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
      timestamp = Time.local.to_s("%Y%m%d-%H%M%S")
      backup_file = "#{path}.#{timestamp}.bak"
      File.copy(path, backup_file)
      backup_file
    end

    # Checks owner:/group:/mode:, then chattr-style attributes:/attr:
    # flags, then the SELinux context parts - the same order real
    # Ansible's set_fs_attributes_if_different applies them (mirrors
    # lineinfile.cr's apply_file_attrs, which itself mirrors copy.cr's
    # apply_extended_attributes). Returns {changed, failure}: failure a
    # failed PluginResult when the chattr/chcon call itself errored.
    # Skips the actual chmod/chown under check_mode, matching every
    # other check_mode-aware plugin in this codebase.
    private def apply_file_attrs(path : String, check_mode : Bool) : {Bool, PluginResult?}
      changed = false
      info = begin
        File.info(path)
      rescue
        return {false, nil}
      end

      changed = apply_mode_attr(path, info, check_mode) || changed
      changed = apply_owner_attr(path, info, check_mode) || changed
      changed = apply_group_attr(path, info, check_mode) || changed

      attr_changed, failure = apply_attr(path, check_mode)
      return {false, failure} if failure
      changed = changed || attr_changed

      failure = apply_secontext(path, check_mode)
      return {false, failure} if failure

      {changed, nil}
    end

    # attributes:/attr: (chattr flags, e.g. "+i" for immutable) -
    # mirrors file.cr/copy.cr/template.cr's proven implementations
    # exactly (same helper names, same semantics, including real
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

    # The file's current chattr flags as real Ansible reads them:
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
    # the task (like real Ansible's fail_json(msg='chattr failed')) when
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

    # seuser:/serole:/setype:/selevel: - SELinux context parts, applied
    # to the file via `chcon`. Mirrors copy.cr's/lineinfile.cr's proven
    # implementation exactly: real Ansible skips this ENTIRELY (a
    # graceful no-op, its set_context_if_different opens with `if not
    # self.selinux_enabled(): return changed`) when SELinux isn't enabled
    # on the target at all, the overwhelming majority of real-world
    # targets.
    private def apply_secontext(path : String, check_mode : Bool) : PluginResult?
      return nil unless File.exists?("/sys/fs/selinux/enforce")

      flags = [] of String
      flags << "-u #{@params["seuser"]}" if @params["seuser"]?
      flags << "-r #{@params["serole"]}" if @params["serole"]?
      flags << "-t #{@params["setype"]}" if @params["setype"]?
      flags << "-l #{@params["selevel"]}" if @params["selevel"]?
      return nil if flags.empty?

      return nil if check_mode

      result = remote_exec("chcon #{flags.join(" ")} #{shell_single_quote(path)}")
      if result[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true, msg: "invalid selinux context: #{result[:stderr]}")
      end

      nil
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
      return false unless user = System::User.find_by?(name: owner)
      return false if info.owner_id.to_s == user.id.to_s

      (File.chown(path, uid: user.id.to_i, gid: -1) rescue nil) unless check_mode
      true
    end

    private def apply_group_attr(path : String, info : File::Info, check_mode : Bool) : Bool
      return false unless group = @params["group"]?
      return false unless grp = System::Group.find_by?(name: group)
      return false if info.group_id.to_s == grp.id.to_s

      (File.chown(path, uid: -1, gid: grp.id.to_i) rescue nil) unless check_mode
      true
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::BlockInFilePlugin.new(config)
plugin.run
