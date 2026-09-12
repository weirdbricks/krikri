#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "digest/sha1"
require "file_utils"
require "../src/krikri/base_plugin"

module Krikri
  # Copy plugin - copies files to destinations
  # This version ALWAYS uses native Crystal file operations
  # The PluginManager handles uploading to remote hosts if needed
  #
  # Not implemented (accepted and ignored):
  # - decrypt: (vault auto-decryption, real default true). Krikri never
  #   auto-decrypts copy sources - the controller-side read in
  #   TaskExecutor#inline_copy_source_content does not go through
  #   Vault.maybe_decrypt, so a vault-encrypted src file is transferred
  #   verbatim (ciphertext), i.e. krikri's effective behavior for every
  #   current run already equals real Ansible's decrypt: false. Wiring
  #   the existing controller-side vault machinery (Krikri::Vault) in
  #   here would silently change what lands on disk for existing plays
  #   relying on the current pass-through, so decrypt: is a no-op and
  #   the vault-encrypted-src gap is documented in KNOWN_MISSING.md
  #   instead.
  class CopyPlugin < BasePlugin
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

      # Check if using content or src. An empty-string src or content
      # counts as not provided: real ansible's copy action plugin
      # truthiness-checks src, and ansible-core 2.19 (verified live on
      # hbjydev.restic) fails `content:` templating to "" with
      # "src (or content) is required" instead of writing an empty file.
      content = @params["content"]?.presence
      src = @params["src"]?.presence

      # Must have either src or content
      if !src && !content
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "src (or content) is required"
        )
      end

      # Can't have both src and content
      if src && content
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "src and content are mutually exclusive"
        )
      end

      # decrypt: (see the class comment above) is accepted and ignored -
      # there is deliberately no param read for it at all.

      # Handle content-based copy
      if content
        # __original_src_basename - set by TaskExecutor#
        # inline_copy_source_content when a small src: file's content
        # was read on the controller and forwarded as content: instead
        # (see that method's own comment) - the same rewrite copy.cr's
        # own src:-based handle_file_copy already accounts for via this
        # exact param name. Without checking it here too, a `copy:
        # {src: brim.desktop, dest: /usr/share/applications/}` (an
        # existing directory) tried to write straight to the directory
        # itself once inline_copy_source_content rewrote it to content:
        # - "Failed to write file: ... 'Is a directory'" - since only
        # handle_file_copy's OWN dest-is-directory basename-append
        # logic existed, and this path never reaches it.
        # Real Ansible's copy also treats a dest: ending in a path
        # separator as an explicit "this is a directory" signal - the
        # basename is appended whenever dest is an EXISTING directory OR
        # ends in "/", not only the former. Real bug found benchmarking
        # l3d.unbound, whose config-fragment tasks pass
        # `dest: /etc/unbound/unbound.conf.d/` (trailing slash, directory
        # created earlier in the play): without the trailing-slash
        # branch, the raw slash-terminated dest reached the final
        # rename/move and failed with "Not a directory". Same condition
        # in #handle_file_copy below.
        if (basename = @params["__original_src_basename"]?.presence) && (Dir.exists?(dest) || dest.ends_with?('/'))
          dest = File.join(dest, basename)
        end
        return handle_content_copy(content, dest)
      end

      # Handle src-based copy
      if src
        result = handle_file_copy(src, dest)

        # __cleanup_after_copy - set by TaskExecutor#stage_large_copy_source
        # when src is a remote scratch path it SCP'd the real source to
        # (rather than embedding a huge file's content as a JSON param -
        # see that method's own comment), not the user's real src: value.
        # Best-effort: a leftover /tmp scratch file is far less harmful
        # than a failed cleanup masking the copy's own real result.
        if @params["__cleanup_after_copy"]? == "true"
          File.delete(src) rescue nil
        end

        # __cleanup_after_copy_dir - directory counterpart, set by
        # TaskExecutor#stage_directory_copy_source. src here may carry
        # the trailing "/" that method preserves for the directory-copy
        # dispatch's own convention, which File paths don't need.
        if @params["__cleanup_after_copy_dir"]? == "true"
          FileUtils.rm_rf(src.rstrip('/')) rescue nil
        end

        return result
      end

      # Should never reach here
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Unexpected error in copy module"
      )
    end

    # Copy inline content to destination
    private def handle_content_copy(content : String, dest_param : String) : PluginResult
      dest = resolve_follow(dest_param)

      # Calculate MD5 of content for idempotency check
      content_md5 = Digest::MD5.hexdigest(content)

      # Get existing content for diff
      existing_content = ""

      # Check if file exists and compare
      if File.exists?(dest)
        # `checksum:` - a SHA1 the caller (or, in real Ansible, the copy
        # action plugin on behalf of src) expects the destination to
        # already hold. When the existing dest's SHA1 matches it, real
        # Ansible skips the transfer entirely WITHOUT comparing the
        # content: param against the file (live-verified against
        # ansible-core 2.19.4: a copy: whose checksum: matches dest
        # reports changed=false even when content: differs from what's
        # on disk). Mirrors the identical-content skip below.
        if given_checksum = @params["checksum"]?.presence
          if File.exists?(dest) && (sha1_of(dest) == given_checksum)
            return PluginResult.new(
              changed: false,
              failed: false,
              msg: "File already exists with matching checksum",
              dest: dest,
              checksum: given_checksum
            )
          end
        end

        # force: false means "only create it if it is not there" - real
        # Ansible leaves an existing file completely alone, content and
        # all. This branch used to ignore `force` entirely (the `src:`
        # path above has always honoured it), so a `copy:` with
        # `content:` + `force: false` OVERWROTE an existing file rather
        # than skipping it. Found live on mrlesmithjr.mdadm, whose
        # "Ensure mdadm conf file exists" task is exactly
        # `content: "" / force: false` against the distro's own
        # /etc/mdadm/mdadm.conf: real ansible-playbook left the 688-byte
        # file untouched and reported ok, this truncated it to 0 bytes
        # and reported changed. Real data loss, not just a wrong verdict.
        unless true?(@params["force"]?, default: true)
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "File already exists (use force=yes to overwrite)",
            dest: dest
          )
        end

        begin
          existing_content = File.read(dest)
          existing_md5 = Digest::MD5.hexdigest(existing_content)

          if existing_md5 == content_md5
            # Content is identical - reconcile mode/owner/group like the
            # src: path does, then return. The bare early-return used to
            # skip attribute reconciliation entirely, so `mode: "0600"`
            # on an already-0644-content file reported ok forever
            # (apply_file_attributes below was never reached).
            #
            # Reconciling an attribute IS a change: real Ansible reports
            # `changed` when an identical-content copy fixes mode/owner/
            # group (live-verified against ansible-core 2.19: a copy: with
            # matching content against a 0755 dest and mode: 0640 reports
            # changed once, then ok on the next run). This path used to
            # hardcode changed: false even when apply_file_attributes had
            # just fixed something, so anything that re-broke the mode
            # between copy runs (bitintheskud.ansible-role-ecs-agent's
            # file: recurse: immediately followed by copy: on a file
            # inside that tree) left copy: silently reporting ok forever
            # while dutifully fixing the attribute on disk every run.
            attributes_fixed, failure = apply_extended_attributes(dest)
            return failure if failure
            return PluginResult.new(
              changed: attributes_fixed,
              failed: false,
              msg: "File already exists with identical content",
              dest: dest,
              checksum: content_md5
            )
          end
        rescue ex
          # File read failed, continue with copy
        end
      end

      # If we get here, file needs to be written
      changed = true

      # Generate diff if in diff mode
      diff_data = nil
      if @diff_mode
        diff_data = generate_unified_diff(
          existing_content,
          content,
          dest,
          "content"
        )
      end

      # CHECK MODE: Report what would change
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would write content to #{dest} (check mode)",
          diff: diff_data
        )
      end

      # Handle backup if requested
      if true?(@params["backup"]?) && File.exists?(dest)
        create_backup(dest)
      end

      # Real Ansible's copy module does NOT create a missing single-file
      # destination directory - it fails with this exact message. See
      # plugins/template.cr's identical fix (same bug, same root cause:
      # a leftover `Dir.mkdir_p` that only diverged from real Ansible
      # once the parent genuinely didn't exist yet) for the repro.
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Destination directory #{dest_dir} does not exist"
        )
      end

      # Write the file (staged + validated first when validate: is given)
      if failure = write_with_optional_validate(content, dest)
        return failure
      end

      # Set file permissions if requested
      _attrs_fixed, failure = apply_extended_attributes(dest)
      return failure if failure

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "Content written to file",
        diff: diff_data,
        dest: dest,
        checksum: content_md5
      )
    end

    # Copy file from src to dest
    private def handle_file_copy(src : String, dest : String) : PluginResult
      # __precomputed_match - set by TaskExecutor#precomputed_copy_match
      # when a checksum-first remote check (run BEFORE ever staging src
      # to the remote host at all) already proved the destination holds
      # identical content. `src` here is still the ORIGINAL, controller-
      # only local path in this case (nothing was staged) - checked and
      # returned first, before any of the `src`-dependent logic below
      # ever runs, since evaluating `Dir.exists?(src)`/`File.exists?(src)`
      # against a path that only exists on the controller, from a plugin
      # process actually running on the remote host, would be meaningless
      # at best. Mirrors the "content already identical" branch further
      # down exactly (still applies file attributes - owner/group/mode
      # can differ even when content matches).
      if @params["__precomputed_match"]? == "true"
        basename = @params["__original_src_basename"]?.presence || File.basename(src)
        dest = File.join(dest, basename) if Dir.exists?(dest) || dest.ends_with?('/')
        return PluginResult.new(changed: false, failed: false, msg: "File already identical (check mode)") if @check_mode

        attributes_fixed, failure = apply_extended_attributes(dest)
        return failure if failure
        return PluginResult.new(
          changed: attributes_fixed,
          failed: false,
          msg: "File already exists with identical content",
          dest: dest,
          checksum: @params["__precomputed_checksum"]? || ""
        )
      end

      # Directory src - dispatched before any of the file-specific dest
      # resolution below, which doesn't apply to a directory copy (its
      # own trailing-"/" convention decides the dest layout instead).
      return handle_directory_copy(src, dest) if Dir.exists?(src)

      # Real ansible.builtin.copy: "If dest is a directory, either the
      # file or content will be copied there" - dest is the directory
      # itself, not the final file path, whenever it's already an
      # existing directory (no trailing "/" required). Real bug found
      # benchmarking ansible-community.ansible-vault's own "Install
      # Vault" task (`dest: "{{ vault_bin_path }}"`, defaulting to the
      # plain directory "/usr/local/bin") - previously dest was always
      # treated as a literal file path, so writing to it opened the
      # directory itself with mode "wb" and failed.
      # __original_src_basename - set by TaskExecutor#stage_large_copy_source
      # when src is a random-named remote scratch path it SCP'd the real
      # (large) source file to, not the user's real src: value - using
      # File.basename(src) directly here would append that random
      # scratch filename instead of the real one.
      #
      # Trailing-"/" dest (l3d.unbound, see #execute's content-path
      # comment) is the same explicit directory signal - basename gets
      # appended even when the directory doesn't exist yet, matching
      # real Ansible. A dest WITHOUT a trailing slash that doesn't
      # exist stays a literal target filename (real Ansible likewise
      # only falls back to the basename for an existing directory).
      basename = @params["__original_src_basename"]?.presence || File.basename(src)
      dest_signaled_dir = dest.ends_with?('/')
      dest = File.join(dest, basename) if Dir.exists?(dest) || dest_signaled_dir
      dest = resolve_follow(dest)

      # Check if source exists
      unless File.exists?(src)
        # remote_src: true's missing-src failure comes from the module
        # itself (the executor deliberately skips all controller-side
        # staging for remote_src, so nothing has run before this point)
        # - real Ansible 2.19.4's exact message is "Source <src> not
        # found" (live-verified). The local-src variant never reaches
        # the module in real Ansible (the controller-side action plugin
        # fails first), so its message stays as it was.
        missing_src_msg = true?(@params["remote_src"]?) ? "Source #{src} not found" : "Source file not found: #{src}"
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: missing_src_msg
        )
      end

      # Handle directory copy (not fully implemented yet)
      if File.directory?(src)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Directory copy not yet implemented"
        )
      end

      # Calculate source file MD5
      begin
        src_content = File.read(src)
        src_md5 = Digest::MD5.hexdigest(src_content)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read source file: #{ex.message}"
        )
      end

      # Check if dest exists and compare
      changed = true
      force = true?(@params["force"]?, default: true)

      if File.exists?(dest)
        # `checksum:` skip - see #handle_content_copy's identical block.
        if given_checksum = @params["checksum"]?.presence
          if sha1_of(dest) == given_checksum
            return PluginResult.new(
              changed: false,
              failed: false,
              msg: "File already exists with matching checksum",
              dest: dest,
              checksum: given_checksum
            )
          end
        end

        unless force
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "File already exists (use force=yes to overwrite)"
          )
        end

        # Compare checksums for idempotency
        begin
          dest_content = File.read(dest)
          dest_md5 = Digest::MD5.hexdigest(dest_content)

          if dest_md5 == src_md5
            # Files are identical
            changed = false
          end
        rescue ex : File::Error
          # Ignore, continue with copy
        end
      end

      # CHECK MODE: Report what would change
      if @check_mode
        return PluginResult.new(
          changed: changed,
          failed: false,
          msg: changed ? "Would copy #{src} to #{dest} (check mode)" : "File already identical (check mode)"
        )
      end

      # If file is identical, just update attributes if requested - and
      # report changed if that reconciliation actually fixed anything
      # (same identical-content `changed: false` bug as
      # #handle_content_copy above; see its comment for the live repro).
      unless changed
        attributes_fixed, failure = apply_extended_attributes(dest)
        return failure if failure
        return PluginResult.new(
          changed: attributes_fixed,
          failed: false,
          msg: "File already exists with identical content",
          dest: dest,
          checksum: src_md5
        )
      end

      # Create backup if requested
      if true?(@params["backup"]?) && File.exists?(dest)
        create_backup(dest)
      end

      # Real Ansible's copy module does NOT create a missing single-file
      # destination directory - it fails with this exact message. See
      # #handle_content_copy's identical fix above for the repro.
      # Exception: when the caller explicitly signaled a directory dest
      # (trailing "/"), real Ansible's atomic_move creates the missing
      # destination directory as part of the move - so a
      # `dest: /etc/unbound/unbound.conf.d/` whose directory the play
      # hasn't materialized yet still succeeds (l3d.unbound repro).
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

      # Copy the file (staged + validated first when validate: is given -
      # src_content was already read above for the MD5 check, so this
      # reuses it rather than reading src a second time).
      if @params["validate"]?
        if failure = write_with_optional_validate(src_content, dest)
          return failure
        end
      else
        if failure = atomic_write(src_content, dest)
          return failure
        end
      end

      # Set ownership and permissions
      _attrs_fixed, failure = apply_extended_attributes(dest)
      return failure if failure

      PluginResult.new(
        changed: true,
        failed: false,
        msg: "File copied successfully",
        dest: dest,
        checksum: src_md5
      )
    end

    # Directory src - real Ansible copy: "if src is a directory, it is
    # copied recursively", with a `src:` trailing "/" meaning "copy the
    # CONTENTS of src", no trailing "/" meaning "copy src itself as a
    # subdirectory of dest" (identical to rsync's own convention). Real
    # bug found benchmarking cloudalchemy.prometheus's own "propagate
    # official console templates" task (`src: ".../console_libraries/"`,
    # both trailing-slash) - directory copy was entirely unimplemented,
    # always "Directory copy not yet implemented" (a documented, but
    # real-world-blocking, scope cut).
    #
    # Idempotency is a per-file existence+checksum check (identical to
    # the single-file path's own MD5 comparison), not real Ansible's
    # fuller directory-diff/prune semantics (e.g. `dest:` files with no
    # `src:` counterpart aren't removed) - narrowly scoped to what
    # actually copies a directory tree correctly, matching several other
    # deliberately-scoped gaps already in this codebase.
    private def handle_directory_copy(src : String, dest : String) : PluginResult
      dest_root = src.ends_with?('/') ? dest : File.join(dest, File.basename(src.rstrip('/')))

      dest_root_preexisted = Dir.exists?(dest_root) rescue false
      begin
        Dir.mkdir_p(dest_root)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to create destination directory: #{ex.message}")
      end

      # dest_root itself is a directory copy just created when it wasn't
      # there before - directory_mode applies to it like any other (only
      # when it didn't already exist: pre-existing dirs stay untouched).
      if (directory_mode = @params["directory_mode"]?.presence) && !dest_root_preexisted
        apply_directory_mode(dest_root, directory_mode)
      end

      changed = false
      copied = 0

      # directory_mode: real Ansible applies this to every directory the
      # copy itself CREATES (live-verified against ansible-core 2.19.4:
      # created dirs get exactly directory_mode, pre-existing dirs are
      # left untouched, and the file's own mode: is NOT applied to
      # created directories - they get the umask default instead).
      directory_mode = @params["directory_mode"]?.presence

      # local_follow: real Ansible's default (None) follows symlinks in
      # the SOURCE tree - the target's content arrives as a regular file
      # (live-verified against ansible-core 2.19.4, same result for
      # local_follow: true). Only an explicit local_follow: false
      # recreates the symlink at dest instead.
      local_follow_false = false?(@params["local_follow"]?)

      # match_hidden: real Ansible walks the whole tree with os.walk,
      # dotfiles included - the default glob silently dropped `.env`,
      # `.gitignore`, `.ssh/` etc. from a directory copy.
      Dir.glob(File.join(src, "**", "*"), match_hidden: true, follow_symlinks: false).sort.each do |entry|
        relative = entry.sub(src.rstrip('/') + "/", "")
        dest_path = File.join(dest_root, relative)

        if File.symlink?(entry) && local_follow_false
          # Recreate the source symlink verbatim (same link target,
          # relative links stay relative) instead of copying its
          # target's content.
          File.delete(dest_path) if File.symlink?(dest_path)
          File.symlink(File.readlink(entry), dest_path)
          changed = true
          next
        end

        if File.directory?(entry)
          unless Dir.exists?(dest_path)
            Dir.mkdir_p(dest_path)
            apply_directory_mode(dest_path, directory_mode) if directory_mode
            changed = true
          end
          next
        end

        Dir.mkdir_p(File.dirname(dest_path))

        if File.exists?(dest_path) && File.read(dest_path) == File.read(entry)
          attrs_fixed, failure = apply_extended_attributes(dest_path)
          return failure if failure
          changed = true if attrs_fixed
          next
        end

        begin
          File.copy(entry, dest_path)
        rescue ex
          return PluginResult.new(changed: changed, failed: true, msg: "Failed to copy #{entry}: #{ex.message}")
        end

        _attrs_fixed, failure = apply_extended_attributes(dest_path)
        return failure if failure
        changed = true
        copied += 1
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Directory copied successfully" : "Directory already up to date",
        dest: dest_root
      )
    end

    # `validate:` support - real Ansible's `copy:` supports it identically
    # to `template:`, which this codebase previously implemented but this
    # plugin never did at all (see KNOWN_MISSING.md's own writeup: found
    # while fixing template.cr's validate:/remote_tmp staging gap).
    # Mirrors template.cr's own approach exactly: stage the final content
    # under /tmp (remote_tmp-style, matching real Ansible's own
    # `~/.ansible/tmp/...` location - see that plugin's own comment on
    # why dest-adjacent staging diverges from real Ansible under
    # AppArmor/SELinux confinement), run the validate: command against
    # the staged file, then move it into place via FileUtils.mv, which
    # already falls back to copy-then-delete on a cross-device
    # (EXDEV/EPERM) move instead of the plain `File.rename` that broke
    # on konstruktoid-hardening. When no validate: is given, writes
    # directly to dest as before - this path is unchanged for the
    # overwhelmingly common no-validate: case.
    #
    # Returns nil on success, or a failed PluginResult.
    private def write_with_optional_validate(content : String, dest : String) : PluginResult?
      validate_cmd = @params["validate"]?
      unless validate_cmd
        return atomic_write(content, dest)
      end

      temp_file = File.join("/tmp", ".krikri-playbook-copy-#{Random::Secure.hex(8)}.tmp")
      begin
        File.write(temp_file, content)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}")
      end

      validation = validate_file(temp_file, validate_cmd)
      unless validation[:ok]
        # Left in place deliberately, same reasoning as template.cr's
        # identical choice - the rendered/copied content is almost
        # always what's actually wrong, and this is the only surviving
        # copy of it once the real dest was never touched.
        context = extract_error_context(temp_file, validation[:output])
        return PluginResult.new(changed: false, failed: true, msg: "Validation failed: #{validation[:output]} (content left at #{temp_file} for inspection)#{context}")
      end

      begin
        FileUtils.mv(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        return PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}")
      end

      nil
    end

    # Validate file with command - identical to template.cr's own
    # helper (captures stdout+stderr so a validation failure explains
    # what's actually wrong, not just that it happened).
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

    # Same context-around-the-cited-line extraction as template.cr's
    # own helper - see that plugin for the full rationale.
    private def extract_error_context(path : String, validator_output : String) : String
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

    # Create backup of file
    private def create_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{Random.rand(10000..99999)}.#{timestamp}~"

      begin
        File.copy(path, backup_path)
      rescue ex : File::Error
        # Backup failed, continue anyway
      end

      backup_path
    end

    # Apply file attributes (owner, group, mode). Returns true if anything
    # actually changed on disk (so the identical-content callers can report
    # `changed` like real Ansible when they reconcile an attribute), false
    # otherwise - including when nothing was stale or an apply failed.
    private def apply_file_attributes(path : String, recursive : Bool = false) : Bool
      before = File.info?(path, follow_symlinks: false)

      # Set mode (permissions)
      if mode = @params["mode"]?
        begin
          # Real Ansible parses ANY all-digit mode string as octal,
          # leading zero or not (`mode: "640"` and `mode: "0640"` are
          # identical). See template.cr's identical fix (round 40,
          # robertdebock.redis) for the full story - the old
          # `starts_with?("0") ? octal : decimal` branch corrupted any
          # templated mode value without a literal leading zero.
          #
          # A genuinely SYMBOLIC mode (`u+x`, `a+x`, ...) doesn't match
          # that all-digit regex and used to silently do NOTHING at all
          # - found via srsp.oracle-java's own `copy: ... mode="a+x"`
          # copying an executable script that a later `command:` task
          # then failed to run ("Permission denied"). Mirrors file.cr's
          # own apply_mode, which already shells out to a real `chmod`
          # for exactly this case.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          else
            Process.run("chmod", [mode, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
          end
        rescue ex : File::Error
          # Mode setting failed, continue anyway
        end
      end

      # Real bug found benchmarking cloudalchemy.grafana's own
      # "Create/Update dashboards file (provisioning)" task (copy:
      # content: ..., owner: root, group: grafana) - owner:/group: were
      # never actually applied at all (a genuinely dead stub, not just
      # narrowly scoped - the comments here claimed File.chown/File.chgrp
      # "not available in Crystal stdlib", which is simply wrong; file.cr
      # already uses File.chown successfully elsewhere in this same
      # codebase). The file silently kept its default group (whatever
      # the process creating it was already running as, "root" here
      # rather than the intended "grafana"), which meant Grafana's own
      # service user couldn't read its own dashboard provisioning
      # config, "Failed to create provisioner: ... permission denied" -
      # the whole service refused to start.
      uid = -1
      gid = -1

      if (owner = @params["owner"]?) && (user = System::User.find_by?(name: owner))
        uid = user.id.to_i
      end

      if (group = @params["group"]?) && (grp = System::Group.find_by?(name: group))
        gid = grp.id.to_i
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      after = File.info?(path, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions ||
        before.owner_id != after.owner_id ||
        before.group_id != after.group_id
    rescue ex : File::Error
      # A chown/chmod failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches file.cr's own identical rescue.
      false
    end

    # SHA1 of a file's bytes - the algorithm real Ansible's `checksum:`
    # param (and its result field) uses. Unreadable files read as ""
    # (never matches a provided checksum, so the copy proceeds/fails
    # like real Ansible's own missing-src handling would).
    private def sha1_of(path : String) : String
      Digest::SHA1.hexdigest(File.read(path))
    rescue File::Error
      ""
    end

    # follow: true - write through a dest: symlink to the file it points
    # at rather than replacing the symlink itself. Live-verified against
    # ansible-core 2.19.4: with follow: true the symlink survives and the
    # TARGET file's content is updated; with the default follow: false
    # the symlink itself is replaced by a regular file. (Krikri's old
    # File.write-based paths implicitly behaved like follow: true -
    # matching the default follow: false is exactly what the atomic
    # rename in #atomic_write now does, since File.rename replaces the
    # link, not its target.)
    private def resolve_follow(dest : String) : String
      return dest unless true?(@params["follow"]?)
      return dest unless File.symlink?(dest)
      File.realpath(dest)
    rescue File::Error
      # A dangling symlink has no realpath - write to the literal path
      # (the rename will replace the dangling link, like follow: false).
      dest
    end

    # Real Ansible's copy writes atomically: the content goes to a
    # temporary file created NEXT TO dest (same filesystem, so the final
    # File.rename can't fail cross-device), an existing dest's
    # permissions (and owner/group, best-effort) are copied onto the
    # temp file first, then it's renamed into place. Live-verified
    # against ansible-core 2.19.4: an overwrite with no explicit mode:
    # preserves the existing dest's mode across the copy.
    #
    # `checksum:` - a SHA1 the copy is verified against AFTER writing
    # but BEFORE the rename, so a mismatch fails with real Ansible's
    # exact message and leaves dest completely untouched (live-verified:
    # a failed checksum check leaves an absent dest absent).
    #
    # unsafe_writes: true is real Ansible's escape hatch for targets
    # where the rename itself fails (docker-mounted single files
    # returning EPERM/EBUSY, etc.): fall back to writing dest directly,
    # in place, non-atomically. Live-verified that on a normal
    # filesystem real Ansible does NOT change behavior with
    # unsafe_writes: true (the rename simply succeeds) - the fallback
    # only ever runs when the rename actually fails.
    #
    # Returns nil on success, or a failed PluginResult.
    private def atomic_write(content : String, dest : String) : PluginResult?
      temp_file = File.join(File.dirname(dest), ".krikri-playbook-copy-#{Random::Secure.hex(8)}.tmp")
      begin
        File.write(temp_file, content)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}")
      end

      begin
        # A symlink dest being REPLACED (default follow: false) has no
        # meaningful mode to preserve - real Ansible skips the
        # mode-copy for links too.
        if !File.symlink?(dest) && (info = File.info?(dest, follow_symlinks: false))
          begin
            File.chmod(temp_file, info.permissions)
            File.chown(temp_file, uid: info.owner_id.to_i, gid: info.group_id.to_i)
          rescue ex : File::Error
            # Best-effort: non-root can't chown; the rename still
            # yields a correct file with this process's ownership.
          end
        end
      rescue ex : File::Error
        # Stat itself failed (broken dest?) - proceed without preservation.
      end

      if given_checksum = @params["checksum"]?.presence
        actual = sha1_of(temp_file)
        unless actual == given_checksum
          File.delete(temp_file) if File.exists?(temp_file)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Copied file does not match the expected checksum. Transfer failed.",
            checksum: actual,
            expected_checksum: given_checksum
          )
        end
      end

      begin
        File.rename(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        if true?(@params["unsafe_writes"]?)
          return unsafe_write_fallback(content, dest)
        end
        return PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}")
      end

      nil
    end

    # unsafe_writes: the non-atomic fallback - write dest directly, in
    # place. Returns nil on success, or a failed PluginResult.
    private def unsafe_write_fallback(content : String, dest : String) : PluginResult?
      File.write(dest, content)
      nil
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to write #{dest} (unsafe_writes fallback): #{ex.message}")
    end

    # attributes:/attr: - chattr-style flags (e.g. "+i" for immutable),
    # real Ansible's `attributes` param and its `attr` alias. Parsed
    # into the leading operator ('+'/'-', defaulting to '=' when bare)
    # plus the flag letters themselves - real Ansible's
    # set_attributes_if_different in module_utils/basic.py does exactly
    # this split before comparing. Mirrors file.cr's proven
    # implementation exactly (same helper names, same semantics).
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
    # dash-padding stripped (e.g. "--------------e-------" -> "e").
    # Real Ansible (get_file_attributes) treats an lsattr failure
    # (missing binary, unsupported filesystem like tmpfs) as empty flags
    # rather than an error - the chattr call itself is what surfaces
    # those as task failures later, not the read.
    private def current_attr_flags(path : String) : String
      result = remote_exec("lsattr -d #{shell_single_quote(path)}")
      return "" unless result[:exit_code] == 0
      fields = result[:stdout].strip.split
      return "" if fields.empty?
      fields[0].delete('-').strip
    end

    # Whether the attributes: param reports changed, mirroring real
    # Ansible's set_attributes_if_different exactly: changed when the
    # current lsattr flag string differs from the requested flag letters
    # OR the request is '-'-prefixed - in which case chattr is re-run
    # and changed reported UNCONDITIONALLY, even when the flag being
    # removed isn't actually set (ansible/ansible#33745). See file.cr's
    # own attr_changed? for the full live-verified rationale.
    private def attr_changed?(path : String) : Bool
      parsed = attr_args
      return false unless parsed
      mod, flags = parsed
      return false if flags.empty?
      current_attr_flags(path) != flags || mod == '-'
    end

    # Applies the attributes: param via the real chattr binary and fails
    # the task (like real Ansible's fail_json(msg='chattr failed')) when
    # chattr exits nonzero or writes to stderr. Returns {changed,
    # failure}: changed is true when chattr actually ran (it reported
    # changed via attr_changed? above), failure a failed PluginResult.
    private def apply_attr(path : String) : {Bool, PluginResult?}
      return {false, nil} unless attr_changed?(path)

      parsed = attr_args
      return {false, nil} unless parsed
      mod, flags = parsed

      result = remote_exec("chattr #{mod}#{flags} #{shell_single_quote(path)}")
      if result[:exit_code] != 0 || !result[:stderr].strip.empty?
        return {false, PluginResult.new(changed: false, failed: true, msg: "chattr failed - Error while setting attributes: #{result[:stdout]}#{result[:stderr]}")}
      end

      {true, nil}
    end

    # seuser:/serole:/setype:/selevel: - SELinux file context, applied
    # to dest via `chcon`. Mirrors archive.cr's proven implementation
    # exactly (verified against real AnsibleModule's own
    # set_context_if_different/selinux_enabled source): real Ansible
    # skips this ENTIRELY (not even attempting it) when SELinux isn't
    # enabled on the target at all - matched here via the standard
    # `/sys/fs/selinux/enforce` selinuxfs check, the same file
    # `selinuxenabled(8)` itself tests. On any non-SELinux host (the
    # overwhelming majority of real-world targets this project has ever
    # benchmarked against) this is a verified, confirmed no-op,
    # identical to real Ansible's own behavior - the chcon-invocation
    # shape itself for an actually-SELinux-enabled host is implemented
    # per `chcon(1)`'s documented flags but NOT live-verified against a
    # real SELinux-enabled target (none available in this project's
    # usual Ubuntu/Debian benchmark environment).
    private def apply_selinux_context(dest : String) : PluginResult?
      return nil unless File.exists?("/sys/fs/selinux/enforce")

      flags = [] of String
      flags << "-u #{@params["seuser"]}" if @params["seuser"]?
      flags << "-r #{@params["serole"]}" if @params["serole"]?
      flags << "-t #{@params["setype"]}" if @params["setype"]?
      flags << "-l #{@params["selevel"]}" if @params["selevel"]?
      return nil if flags.empty?

      result = remote_exec("chcon #{flags.join(" ")} #{shell_single_quote(dest)}")
      if result[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true, msg: "invalid selinux context: #{result[:stderr]}")
      end

      nil
    end

    # Combined attribute reconciliation for every path copy touches:
    # mode/owner/group first (#apply_file_attributes), then chattr
    # flags, then the SELinux context - the same order real Ansible's
    # set_fs_attributes_if_different applies them. Returns {changed,
    # failure}: changed true when anything actually changed on disk,
    # failure a failed PluginResult when the chattr/chcon call itself
    # errored (both fail the task like real Ansible - neither is
    # silently swallowed the way a chmod/chown EPERM is).
    private def apply_extended_attributes(path : String) : {Bool, PluginResult?}
      changed = apply_file_attributes(path)

      attr_changed, failure = apply_attr(path)
      return {false, failure} if failure
      changed = true if attr_changed

      failure = apply_selinux_context(path)
      return {false, failure} if failure

      {changed, nil}
    end

    # directory_mode: - the mode given to directories copy CREATES
    # (never pre-existing ones, never the copied files themselves).
    # Same octal-vs-symbolic split as #apply_file_attributes' own mode
    # branch: all-digit strings parse as octal (leading zero or not),
    # anything symbolic goes to the real chmod binary.
    private def apply_directory_mode(path : String, directory_mode : String) : Nil
      if directory_mode =~ /\A0?[0-7]{3,4}\z/
        File.chmod(path, directory_mode.to_i(8))
      else
        Process.run("chmod", [directory_mode, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
    rescue ex : File::Error
      # Mode setting failed, continue anyway - matches
      # #apply_file_attributes' own convention.
      nil
    end

  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::CopyPlugin.new(config)
plugin.run
