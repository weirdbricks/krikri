#!/usr/bin/env crystal

require "json"
require "digest/md5"
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
    property? check_mode : Bool
    property? diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
      @diff_mode = true?(@params["diff_mode"]?)
    end

    def execute : PluginResult
      # Get destination (required)
      dest = @params["dest"]?
      unless dest
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: dest"
        )
      end
      dest = expand_tilde(dest)

      # Real ansible.builtin.template, like copy: a dest that signals a
      # directory (an existing directory, or an explicit trailing "/")
      # gets the template's own basename appended - the rendered file
      # lands at <dest>/<basename of src>, not on the directory path
      # itself. _rendered_from_template is the controller-side src path
      # the action plugin sends along (src itself is stripped before
      # upload), so its basename is the real template filename. Found
      # benchmarking l3d.unbound, whose config-fragment tasks pass
      # `dest: /etc/unbound/unbound.conf.d/` - previously the raw
      # slash-terminated dest reached the final move and failed with
      # "Not a directory" where real Ansible succeeded.
      dest_signaled_dir = dest.ends_with?('/')
      if (template_src = @params["_rendered_from_template"]?.presence) && (Dir.exists?(dest) || dest_signaled_dir)
        dest = File.join(dest, File.basename(template_src))
      end

      # follow: (real Ansible's copy-writer semantics, default False):
      # when True, a symlink at dest: is written THROUGH - the symlink's
      # target gets the rendered content and the symlink itself stays -
      # while the default replaces the symlink with a regular file.
      # Live-verified against ansible-core 2.19.4: follow=true writes the
      # target (link still a link afterwards), follow=false replaces the
      # link. Resolution happens BEFORE the identical-content check so
      # idempotency compares against the target's content, matching real
      # Ansible's own comparison of the followed path's checksum. A
      # dangling symlink is deliberately NOT resolved (File.exists?
      # returns false for one) - real Ansible's default path unlinks and
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

      # output_encoding: real Ansible's template module writes the
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

      # Calculate MD5 of the encoded content (see output_encoding above)
      content_md5 = Digest::MD5.hexdigest(content_bytes)

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
        rescue ex
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

      # Real Ansible's copy module (template: shares it) unconditionally
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

      # force: (real Ansible's copy-writer default True): when dest
      # already exists with DIFFERENT content and force: is explicitly
      # false, real Ansible leaves the file untouched and reports plain
      # ok/changed: false - NOT a failure (live-verified against
      # ansible-core 2.19.4). Mirrors copy.cr's own force handling.
      if changed && !true?(@params["force"]?, default: true)
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "File already exists (use force=yes to overwrite)",
          dest: dest
        )
      end

      # Generate diff if in diff mode and content changed
      diff_data = nil
      if @diff_mode && changed
        src_name = @params["_rendered_from_template"]? || "template"
        diff_data = generate_unified_diff(
          existing_content,
          content,
          dest,
          src_name
        )
      end

      # CHECK MODE: Report what would change
      if @check_mode
        if changed
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would write rendered template to #{dest} (check mode)",
            diff: diff_data
          )
        else
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Template already rendered correctly (check mode)",
            diff: diff_data
          )
        end
      end

      # If content is identical, just update attributes if requested - and
      # report changed if that reconciliation actually fixed anything. This
      # used to hardcode changed: false even when apply_file_attributes had
      # just fixed a stale mode/owner/group - the same identical-content
      # bug as copy.cr's (found on bitintheskud.ansible-role-ecs-agent:
      # anything re-breaking the mode between runs made the task silently
      # report ok forever while fixing it on disk; real Ansible reports
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
        return PluginResult.new(
          changed: attributes_fixed,
          failed: false,
          msg: "File already exists with identical content",
          dest: dest,
          checksum: content_md5
        )
      end

      # Content will change - create backup if requested
      backup_file = ""
      if true?(@params["backup"]?) && File.exists?(dest)
        backup_file = create_backup(dest)
      end

      # Real Ansible's template/copy modules do NOT create a missing
      # destination directory - they fail with this exact message
      # ("Destination directory X does not exist"). This plugin used to
      # silently `Dir.mkdir_p` it instead, diverging from real Ansible
      # only when the parent genuinely didn't exist yet (the common case
      # - dest already inside an existing dir like /etc/nginx - never hit
      # this path). Found benchmarking bertvv.mariadb's own "Add official
      # MariaDB repository (yum)" task templating into /etc/yum.repos.d
      # on Ubuntu, where that directory never exists: real Ansible
      # refused the task; krikri quietly created the directory and wrote
      # the file, reporting `changed` where real Ansible reported
      # `failed`.
      # dest is already resolved past the directory-signal step above, so
      # a trailing-"/" dest has its basename appended before this check.
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        if dest_signaled_dir
          begin
            Dir.mkdir_p(dest_dir)
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

      # Real Ansible's copy module (template: shares it) pre-checks the
      # destination directory's writability and fails with exactly
      # "Destination <dir> not writable" when it isn't - live-verified
      # against ansible-core 2.19.4, including the observable effect:
      # a read-only directory containing a WRITABLE file fails the task
      # by default (the atomic temp-file+rename cannot work without
      # directory write permission), and unsafe_writes: true bypasses
      # the check, falling back to a direct, non-atomic in-place write
      # (real Ansible's _unsafe_writes). Note the check is on the
      # DIRECTORY, not the file: a writable dir with an
      # existing-file-dest proceeds normally.
      unless true?(@params["unsafe_writes"]?)
        unless File.writable?(dest_dir)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Destination #{dest_dir} not writable"
          )
        end
      end

      # Write to temporary file first (for atomic write + validation).
      # Staged in a remote_tmp-style location (`/tmp`), matching real
      # Ansible's own `~/.ansible/tmp/ansible-tmp-.../` staging - NOT
      # dest_dir, which this plugin used previously. That dest-adjacent
      # staging was itself a fix for a real cross-device `File.rename`
      # bug (`/tmp` is very commonly its own separate tmpfs mount, so
      # renaming a /tmp staging file onto a destination elsewhere on
      # disk hit "Invalid cross-device link" - found via
      # konstruktoid-hardening's "Configure sshd using sshd_config.d"
      # task writing to /usr/lib/tmpfiles.d/ssh.conf) but it diverges
      # from real Ansible in a way that's independently observable: a
      # `validate:` command confined by AppArmor/SELinux to only the
      # target program's OWN real config paths (e.g. dhcpd's profile
      # permits /etc/dhcp/ but not a temp file dropped next to it) can
      # see a different validation outcome than real Ansible's own
      # /root/.ansible/tmp-confined run (found via bertvv.dhcp round
      # 312). Moving back to /tmp restores real Ansible's location
      # without reintroducing the cross-device bug: `FileUtils.mv`
      # (stdlib) already falls back to copy-then-delete on
      # `Errno::EXDEV`/`EPERM`, exactly the fallback needed - see its
      # use below instead of a raw `File.rename`.
      temp_file = File.join("/tmp", ".krikri-playbook-template-#{Random::Secure.hex(8)}.tmp")

      begin
        # Write the OUTPUT-ENCODED bytes (see output_encoding above) -
        # not the UTF-8 string.
        File.write(temp_file, content_bytes)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to write temporary file: #{ex.message}"
        )
      end

      # Validate if requested
      if validate_cmd = @params["validate"]?
        validation = validate_file(temp_file, validate_cmd)
        unless validation[:ok]
          # Left in place (not deleted) deliberately - a validation
          # failure means the rendered content itself is almost always
          # what's actually wrong, and there's no other way to inspect
          # what got rendered (the real destination file was never
          # touched). The path is in the message specifically so it's
          # not just silently orphaned.
          #
          # Also inlines a few lines of context around whatever line
          # number the validator's own output cites (`sshd -T`/`nginx
          # -t`-style tools report "line N: ..."), read directly from
          # this plugin's own filesystem (it's already running ON the
          # target host) - a second SSH round trip to fetch the file
          # separately isn't guaranteed to still be possible by the time
          # anyone looks (the whole play keeps running past this one
          # failed task, and can reach a task that drops the control
          # connection - e.g. this exact template's own role locking out
          # SSH access later in the same play - well before a human gets
          # a chance to inspect it).
          context = extract_error_context(temp_file, validation[:output])
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Validation failed: #{validation[:output]} (rendered content left at #{temp_file} for inspection)#{context}"
          )
        end
      end

      # Move temp file to destination, mirroring real Ansible's
      # atomic_move fallback ladder. The optimistic step is a rename of
      # the /tmp-staged file onto dest (atomic, replaces dest INODE -
      # including replacing a symlink at dest, real Ansible's default
      # follow=false semantics). When rename can't work - /tmp being a
      # separate tmpfs mount is very common, and the whole reason
      # staging moved back to /tmp was a cross-device "Invalid
      # cross-device link" (see temp_file's comment above) - real
      # Ansible falls back to staging NEXT TO dest (mkstemp in the dest
      # directory, same filesystem) and renaming from there. Doing that
      # explicitly matters: a naive copy-onto-dest fallback (e.g.
      # FileUtils.mv's own cross-device path) OPENS dest for writing,
      # which follows a symlink - a dest symlink would get its target
      # overwritten instead of replaced, silently diverging from real
      # Ansible's follow=false (and silently "succeeding" where real
      # Ansible's follow default writes a real file).
      begin
        File.rename(temp_file, dest)
      rescue
        begin
          dest_dir_stage = File.join(dest_dir, ".krikri-playbook-template-#{Random::Secure.hex(8)}.tmp")
          File.write(dest_dir_stage, "")
          FileUtils.mv(temp_file, dest_dir_stage)
          File.rename(dest_dir_stage, dest)
        rescue fallback_ex
          File.delete(dest_dir_stage) if dest_dir_stage && File.exists?(dest_dir_stage)
          File.delete(temp_file) if File.exists?(temp_file)
          if true?(@params["unsafe_writes"]?)
            # Real Ansible's _unsafe_writes: a direct, non-atomic
            # in-place write of dest - the only path that works when
            # the DEST DIRECTORY isn't writable (the writability
            # pre-check above normally fails this first without
            # unsafe_writes:). Preserves dest's inode, so hardlinks to
            # it see the new content.
            begin
              File.write(dest, content_bytes)
            rescue write_ex
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to write destination file (unsafe_writes): #{write_ex.message}"
              )
            end
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to replace #{dest} with the rendered template: #{fallback_ex.message}"
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

      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Template rendered successfully",
        diff: diff_data,
        dest: dest,
        checksum: content_md5,
        backup_file: backup_file.empty? ? nil : backup_file
      )
    end

    # Create backup of existing file
    private def create_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{Random.rand(10000..99999)}.#{timestamp}~"

      begin
        File.copy(path, backup_path)
        backup_path
      rescue
        # Backup failed, continue anyway
        ""
      end
    end

    # Reads a few lines of context out of *path* around whatever line
    # number *validator_output* cites (`"...: line 34: ..."`, the shape
    # `sshd -T`/most other line-oriented config validators use). Returns
    # "" (not an error) if the output doesn't cite a line number, or the
    # file can't be read - this is best-effort diagnostic content, never
    # something a caller should treat as required.
    private def extract_error_context(path : String, validator_output : String) : String
      # `sshd -T`'s own line-citing format varies by which check failed -
      # sometimes "path: line N: message", sometimes "path line N:
      # message" (no colon before "line") - matched loosely enough to
      # catch both rather than assuming one specific validator's exact
      # phrasing.
      return "" unless match = validator_output.match(/line\s+(\d+):/)
      line_num = match[1].to_i

      lines = File.read_lines(path)
      from = Math.max(0, line_num - 3)
      to = Math.min(lines.size - 1, line_num + 1)
      return "" if from > to

      context_lines = (from..to).map { |i| "#{i + 1}: #{lines[i]}" }.join("\n")
      "\n--- context around line #{line_num} ---\n#{context_lines}"
    rescue
      ""
    end

    # Validate file with command. Captures stdout+stderr (not discarded,
    # as this used to) so a validation failure - real Ansible's own
    # `validate:` commands are typically `sshd -T -f %s`/`nginx -t -c
    # %s`-style syntax checkers whose whole purpose is to explain exactly
    # what's wrong - reports *what* failed, not just that it did.
    private def validate_file(path : String, validate_cmd : String) : NamedTuple(ok: Bool, output: String)
      cmd = validate_cmd.gsub("%s", path)
      output = IO::Memory.new

      result = Process.run(
        "/bin/sh",
        ["-c", cmd],
        output: output,
        error: output
      )

      {ok: result.exit_code == 0, output: output.to_s.strip}
    end

    # Apply file attributes (owner, group, mode). Returns true if anything
    # actually changed on disk (so the identical-content caller can report
    # `changed` like real Ansible when it reconciles an attribute), false
    # otherwise - including when nothing was stale or an apply failed.
    private def apply_file_attributes(path : String) : Bool
      before = File.info?(path, follow_symlinks: false)

      # SELinux context runs FIRST, matching the order of real Ansible's
      # set_fs_attributes_if_different (set_context_if_different ->
      # owner -> group -> mode -> attributes) and file.cr's own
      # apply_single_file_attributes, which this mirrors.
      secontext_will_change = secontext_changed?(path)
      apply_secontext(path)

      # Set mode (permissions) using native Crystal
      if mode = @params["mode"]?
        begin
          # Real Ansible parses ANY all-digit mode string as octal,
          # leading zero or not (`mode: "640"` and `mode: "0640"` are
          # identical - only a *symbolic* mode like `u+x` isn't valid
          # octal digits). Real bug found benchmarking robertdebock.redis
          # (round 40): `mode: "{{ redis_mode }}"` rendered to the plain
          # string "640" (no leading zero, from a Jinja dict-lookup
          # default, not a literal YAML octal) - the old `starts_with?
          # ("0") ? octal : decimal` branch treated it as DECIMAL 640,
          # producing octal 1200 (`--w------T`) instead of 0640
          # (`rw-r-----`), leaving redis-server unable to even read its
          # own config file. Matches file.cr's own `parse_numeric_mode`.
          #
          # A genuinely SYMBOLIC mode (`u+x`, `u+x,g+x`, `a+x`, ...) -
          # real, common idioms for "make this script executable" -
          # doesn't match that all-digit regex and used to silently do
          # NOTHING at all (no error, no chmod, mode left at whatever
          # File.write's own default was) - found via
          # grzegorznowak.nvm_node's own `template: ... mode="u+x,g+x"`
          # writing an install script that a later `command:` task then
          # failed to execute at all ("Permission denied"). file.cr's
          # own apply_mode already falls back to shelling out to a real
          # `chmod` for exactly this case; mirrored here instead of
          # silently dropping the mode.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          else
            Process.run("chmod", [mode, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
          end
        rescue
          # Mode setting failed, continue anyway
        end
      end

      # Owner and group would require chown/chgrp system calls
      # For now, use shell commands for these (they need root anyway)
      if owner = @params["owner"]?
        Process.run("chown", [owner, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
      end

      if group = @params["group"]?
        Process.run("chgrp", [group, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
      end

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
    # success). Real Ansible writes with Python's codec stack
    # (errors='surrogate_or_strict' - an unencodable character or an
    # unknown codec name fails the task); Crystal strings are UTF-8
    # internally, so this goes through String#encode. The name search
    # tries a few normalizations because codec-naming conventions differ
    # (real Ansible's documented example "latin-1" is
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
    # implementations of real Ansible's file-common args (attr:/
    # attributes: chattr flags, seuser:/serole:/setype:/selevel: SELinux
    # context parts) for a plugin that writes new file content rather
    # than only mutating metadata - deliberately duplicated rather than
    # abstracted, so the proven-correct file.cr behavior can't drift
    # under a shared abstraction.

    # attr:/attributes: (chattr flags, real Ansible's `attributes` param
    # and its `attr` alias). Parsed into the leading operator ('+'/'-',
    # defaulting to '=' when bare) plus the flag letters themselves -
    # real Ansible's set_attributes_if_different in
    # module_utils/basic.py does exactly this split before comparing.
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
    # unsupported filesystem) is empty flags, not an error - matching
    # file.cr's reading of real Ansible's get_file_attributes.
    private def current_attr_flags(path : String) : String
      result = remote_exec("lsattr -d #{shell_single_quote(path)}")
      return "" unless result[:exit_code] == 0
      fields = result[:stdout].strip.split
      return "" if fields.empty?
      fields[0].delete('-').strip
    end

    # Changed-check mirroring real Ansible's set_attributes_if_different
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
    # failing the task (like real Ansible's fail_json) when chattr exits
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

    # SELinux context params: real Ansible accepts these on every host
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
    # exactly like real Ansible's own `context.split(':', 3)` - the MLS
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
    # module_utils/basic.py grounding).
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

    # Applies the full context with `chcon -h` (real Ansible's
    # lsetfilecon equivalent, symlink-aware), failing the task on a
    # nonzero exit like the real module's fail_json(msg='set selinux
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
