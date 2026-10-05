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
  # decrypt: (vault auto-decryption of src, real default true) is
  # handled CONTROLLER-side, before this plugin ever runs:
  # TaskExecutor#inline_copy_source_content decrypts a vault-encrypted
  # src file (unless the play passes decrypt: false) and forwards the
  # plaintext as content: - or stages the decrypted bytes via SCP when
  # the plaintext is oversized or binary. By the time a src: reaches
  # this plugin it is never vault-armored, so decrypt: is still accepted
  # and ignored here.
  class CopyPlugin < BasePlugin
    # Real ansible-core 2.19.11's registered copy result key orders -
    # live-verified via `{{ r | to_json }}` on registered copy: tasks
    # (the -v dump sorts alphabetically, so the order is only observable
    # programmatically). Real's changed-path result runs diff, dest, src,
    # md5sum, checksum, changed (, backup_file), then the add_path_info
    # stat block and failed: false last - verified on both the content:
    # and src: paths (identical order), with backup: true (backup_file
    # right after changed), and on the directory-copy path (whose real
    # result is bare dest/src/changed, no stat block). `src` and
    # `md5sum` ride the changed results too (live-verified vs 2.19.11):
    # real's src is its staged tempfile path - the content path echoes
    # krikri's own staging temp, the src path echoes the source path
    # itself - and md5sum is the source content's MD5. The equal-content
    # and check-mode would-not-change paths dispatch real's FILE module
    # (the copy action's already-correct-hash branch), whose result runs
    # diff, path, changed, the stat block, then the action-injected
    # checksum and dest - a different order, hence its own constant.
    private CHANGED_KEY_ORDER   = %w[diff dest src md5sum checksum changed backup_file uid gid owner group mode state size failed]
    private UNCHANGED_KEY_ORDER = %w[diff path changed uid gid owner group mode state size checksum dest failed]
    # force: false against an existing dest: real's result is ONLY
    # {dest, src, changed} (live-verified) - dest leads.
    private NOOP_KEY_ORDER = %w[dest src changed failed]
    # check-mode would-change: real's action-level result is
    # {diff: [], changed: true} (live-verified, src and content paths
    # alike).
    private CHECK_KEY_ORDER = %w[diff changed failed]

    # ansible.builtin.copy's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.copy). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    #
    # `follow` is conditional: real's copy ACTION plugin reads it through
    # boolean(value, strict=False) and hands the MODULE the coerced boolean
    # (copy.py:328-335) - so on that path an invalid spelling is silently
    # False and the module never rejects it. Only the remote_src branch
    # passes the raw args to the module, where the strict spec does apply
    # (live-verified vs 2.19.11). copy.py:422 picks that branch with the
    # SAME boolean(strict=False) as this predicate. Same condition, same
    # reasoning in ArgspecValidator's copy follow normalisation.
    protected def bool_params : Array(String)
      params = %w[backup decrypt follow force local_follow remote_src unsafe_writes]
      return params if Krikri.lenient_boolean_true?(@params["remote_src"]?)
      params.reject { |name| name == "follow" }
    end

    # These default to None in real's argspec, so an explicit null
    # skips type validation there (see BasePlugin#bool_params_none_default).
    protected def bool_params_none_default : Array(String)
      %w[local_follow]
    end

    property? check_mode : Bool
    property? diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
      @diff_mode = true?(@params["_ansible_diff"]?)
    end

    def execute : PluginResult
      # Real's argspec failure (a module-level failure, live-verified)
      # is a copy result like any other - it goes through the same
      # post-processing below (notably the always-present `diff` key),
      # so it is caught here rather than left to run_and_capture's
      # generic rescue, which builds a bare result without it.
      result = begin
        execute_copy
      rescue ex : BoolParamError
        PluginResult.new(changed: false, failed: true, msg: ex.message || "invalid boolean parameter")
      end
      # Real copy's wire result ALWAYS carries a `diff` key - an empty
      # LIST when no diff data was computed (live-verified vs 2.19.11 at
      # -vvv, run and --check alike; the display layer strips it below
      # -vvv, so only -vvv sees it). Failed module results keep it too -
      # the registered result of a failed copy shows `"diff": []` (argspec
      # failures and module failures alike, live-verified). A real diff
      # payload (diff mode) keeps the computed content.
      if result.diff.nil?
        result.diff = JSON::Any.new([] of JSON::Any)
      end
      # Real 2.19.11's CHECK-MODE content copy reports its module
      # invocation in this exact censored shape (live-verified at -vvv):
      # the outer raw task args with content no_log-censored, plus
      # module_args where the content value is replaced by real's
      # VALUE_SPECIFIED_IN_NO_LOG_PARAMETER sentinel. Deterministic - no
      # random staged path (the module never stages in check mode).
      if @check_mode && !result.failed? && result.changed? && @params.has_key?("content")
        dest = @params["dest"]?
        if dest
          result.extra["invocation"] = JSON::Any.new({
            "content"     => JSON::Any.new("CENSORED: content is a no_log parameter"),
            "dest"        => JSON::Any.new(dest),
            "module_args" => JSON::Any.new({
              "content" => JSON::Any.new("VALUE_SPECIFIED_IN_NO_LOG_PARAMETER"),
              "dest"    => JSON::Any.new(dest),
            }),
          })
        end
      end
      result
    end

    private def execute_copy : PluginResult
      validate_bool_params! unless copy_module_never_runs?
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

      # `src` and `content` have DIFFERENT presence rules in real
      # Ansible - genuinely asymmetric, not a simplification either way
      # (all four live-verified against ansible-core 2.19.11):
      #
      # - `src`: truthiness-checked, matching a real file PATH - an
      #   empty string is never a valid path, so `src: ""` alone fails
      #   "src (or content) is required" exactly like `src:` being
      #   absent, AND `src: "", content: "hello"` succeeds using
      #   content (the empty src is simply ignored, not "provided",
      #   so there's no mutual-exclusivity conflict either).
      # - `content`: presence-checked (nil vs not-nil), since an empty
      #   FILE is a perfectly legitimate thing to write - a bare `{{
      #   empty_var }}`, mixed text (`"prefix{{ e }}"`), a literal
      #   `content: ""`, and even a bare `{{ '' }}` expression all
      #   succeed and write a real empty file (geerlingguy.sanoid's own
      #   `content: "{{ sanoid_conf }}"` with `sanoid_conf: ""` needs
      #   this to keep working) - and `src: "actual/path", content: ""`
      #   DOES hit "src and content are mutually exclusive" (the empty
      #   content still counts as "given"). The ONE exception - a `{%
      #   for %}...{% endfor %}` block tag rendering to nothing
      #   (hbjydev.restic's own `content:`) DOES fail "src (or content)
      #   is required" - is handled upstream, in
      #   TaskExecutor#substitute_task_params, which drops such a param
      #   key entirely (OMIT_SENTINEL) rather than sending it here as
      #   "" - so a plain presence check on content is already correct
      #   for every remaining shape without this plugin needing to know
      #   anything about how its value was templated.
      content = @params["content"]?
      # A falsy non-string literal src (false/0/0.0 - the parser marks
      # those, see NON_STRING_PARAM_PREFIX) is ignored by real's action
      # plugin (`not source`), exactly like an absent or empty one - so
      # `src: 0` with content: runs the content path (live-verified vs
      # 2.19.11).
      src = python_param_truthy?("src") ? @params["src"]?.presence : nil

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

      # decrypt: (see the class comment above) is handled entirely
      # controller-side - there is deliberately no param read for it
      # here.

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

    # Real's copy ACTION plugin hands the task to the copy MODULE only
    # when there are bytes to move, so the module's own argument spec -
    # and with it the strict `type: bool` conversion of backup/force/... -
    # only ever runs in that case (copy.py, live-verified vs 2.19.11):
    #
    # - remote_src: the action plugin dispatches the module right away
    #   (copy.py:466), so the spec always applies;
    # - otherwise _copy_file returns changed=True as soon as it sees the
    #   checksums differ, BEFORE the transfer and the module call, when
    #   the run is a --check one (copy.py:288-293);
    # - ... and when the destination already holds the source's exact
    #   content it skips the transfer altogether and dispatches
    #   ansible.legacy.file with copy's copy-only options stripped, so
    #   those are never validated either - the task just reports ok.
    #
    # So a bad `backup:` spelling in either of those two states must NOT
    # fail the task: it fails only when the module would really run. This
    # is the same rule the controller-side gate applies before dispatch
    # (TaskExecutor#copy_module_never_runs?); both layers have to agree
    # or the same task would be validated twice.
    private def copy_module_never_runs? : Bool
      return false if true?(@params["remote_src"]?)
      return true if @check_mode
      src = @params["src"]?
      dest = @params["dest"]?
      return false unless src && dest
      return false unless File.file?(src) && File.file?(dest)
      File.size(src) == File.size(dest) && File.read(src) == File.read(dest)
    end

    # Copy inline content to destination
    private def handle_content_copy(content : String, dest_param : String) : PluginResult
      dest = resolve_follow(dest_param)

      # Calculate the checksums the result fields carry. `checksum:` is
      # a SHA1 (real Ansible's own checksum algorithm - module.sha1 <-
      # the real module's checksum(), verified against
      # ansible-core 2.19.4's live output: a 40-hex-char SHA1, not the
      # 32-hex-char MD5 this used to emit) of the content, used both for
      # the result field and the idempotency comparison; `md5sum:` is the
      # separate backwards-compat field real copy reports alongside it.
      content_sha1 = Digest::SHA1.hexdigest(content)
      content_md5 = Digest::MD5.hexdigest(content)

      # Get existing content for diff
      existing_content = ""

      # Check if file exists and compare
      if File.exists?(dest)
        # force: false means "only create it if it is not there" - real
        # Ansible leaves an existing file completely alone, content and
        # all, and never even computes the dest checksum for the
        # equal-content shortcut (the action's _execute_remote_stat
        # gets checksum=force, so a force=false run always takes the
        # transfer branch and the module's own force check exits first
        # - live-verified vs 2.19.11 at -v). This branch used to ignore
        # `force` entirely (the `src:` path above has always honoured
        # it), so a `copy:` with `content:` + `force: false` OVERWROTE
        # an existing file rather than skipping it. Found live on
        # mrlesmithjr.mdadm, whose "Ensure mdadm conf file exists" task
        # is exactly `content: "" / force: false` against the distro's
        # own /etc/mdadm/mdadm.conf: real ansible-playbook left the
        # 688-byte file untouched and reported ok, this truncated it to
        # 0 bytes and reported changed. Real data loss, not just a
        # wrong verdict.
        unless true?(@params["force"]?, default: true)
          # Real's result here is ONLY {changed, dest, src} - no msg, no
          # file-common stat fields, no checksum (live-verified vs
          # 2.19.11 at -v; src is real's random staged tempfile - the
          # action always stages the content before the module's force
          # check exits). The echo is reported in real's shape via
          # staged_src_echo; no staging temp of krikri's own is needed
          # to produce it.
          return PluginResult.new(
            changed: false,
            failed: false,
            dest: dest,
            src: staged_src_echo(dest),
            key_order: NOOP_KEY_ORDER
          )
        end

        begin
          existing_content = File.read(dest)
          existing_sha1 = Digest::SHA1.hexdigest(existing_content)

          if existing_sha1 == content_sha1
            # Content is identical - real's copy ACTION plugin short-circuits
            # here (its local_checksum of the source equals the dest's
            # checksum) and calls the FILE module for attribute
            # reconciliation only; the copy module - and its user-checksum
            # validation with it - never runs. The user's `checksum:`
            # param is irrelevant on this path (live-verified vs 2.19.11:
            # an equal-content copy with a matching checksum: registers
            # the file-module result shape below, not any
            # "already exists" message).
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
        rescue
          # File read failed, continue with copy
        end
      end

      # If we get here, file needs to be written
      changed = true

      # Generate diff if in diff mode
      diff_data = nil
      if @diff_mode
        # Real copy's diff headers (live-verified vs 2.19.11): the before
        # side is `before: <dest>` when the dest file already exists and
        # bare `before` when it does not; the after side is always
        # `after: <dest>`.
        diff_data = generate_unified_diff(
          existing_content,
          content,
          File.exists?(dest) ? "before: #{dest}" : "before",
          "after: #{dest}"
        )
      end

      # CHECK MODE: Report what would change
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          diff: diff_data,
          key_order: CHECK_KEY_ORDER
        )
      end

      # Handle backup if requested
      backup_file = nil
      if true?(@params["backup"]?) && File.exists?(dest)
        backup_file = create_backup(dest)
      end

      # Real Ansible's copy module does NOT create a missing single-file
      # destination directory - it fails with this exact message. See
      # plugins/template.cr's identical fix (same bug, same root cause:
      # a leftover `Dir.mkdir_p` that only diverged from real Ansible
      # once the parent genuinely didn't exist yet) for the repro.
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        # The trailing `checksum` is real's copy ACTION plugin injecting
        # local_checksum into any module result that lacks one, failed
        # results included (live-verified vs 2.19.11). The action also
        # seeds `diff: []` before the module runs and `result.update`s
        # the module's failure into it, so the registered failure leads
        # with diff, then failed, msg, checksum - changed and exception
        # trail after (round 994002 kop_misc2 helper_unfinished).
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Destination directory #{dest_dir} does not exist",
          checksum: content_sha1,
          key_order: ["diff", "failed", "msg", "checksum"]
        )
      end

      # Write the file (staged + validated first when validate: is given;
      # content_sha1 rides along because real's copy ACTION plugin injects
      # `checksum` (its local_checksum) into any module result that lacks
      # one - failed results included)
      write = write_with_optional_validate(content, dest, content_sha1)
      write_failure = write[:failure]
      return write_failure if write_failure
      staged = write[:staged]

      # Set file permissions if requested
      _attrs_fixed, failure = apply_extended_attributes(dest)
      return failure if failure

      result = PluginResult.new(
        changed: changed,
        failed: false,
        diff: diff_data,
        dest: dest,
        # Real's src is the action's staged content tempfile (.source,
        # live-verified) - krikri's own staging temp is where the bytes
        # actually travelled, but the echo is reported in real's shape
        # (staged_src_echo) so registered values compare.
        src: staged ? staged_src_echo(dest) : dest,
        checksum: content_sha1,
        md5sum: content_md5,
        key_order: CHANGED_KEY_ORDER
      )
      result.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      add_path_info(result, dest)
      result
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
        if @check_mode
          result = PluginResult.new(
            changed: false,
            failed: false,
            dest: dest,
            checksum: @params["__precomputed_checksum"]?.presence || "",
            key_order: UNCHANGED_KEY_ORDER
          )
          add_path_info(result, dest)
          return result
        end

        attributes_fixed, failure = apply_extended_attributes(dest)
        return failure if failure
        result = PluginResult.new(
          changed: attributes_fixed,
          failed: false,
          dest: dest,
          checksum: @params["__precomputed_checksum"]? || "",
          key_order: UNCHANGED_KEY_ORDER
        )
        add_path_info(result, dest)
        result.extra["path"] = JSON::Any.new(dest)
        return result
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
        # found" (live-verified), with <src> formatted by Python str()
        # of the module arg - so a non-string YAML literal reports its
        # native text (a bool prints True/False, not the demoted
        # "true"/"false") and a list its Python repr. The local-src
        # variant never reaches the module in real Ansible (the
        # controller-side action plugin fails first), so its message
        # stays as it was.
        missing_src_msg = true?(@params["remote_src"]?) ? "Source #{python_module_src_text(src)} not found" : "Source file not found: #{src}"
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

      # Calculate source file checksums (SHA1 for the `checksum:` result
      # field and the idempotency comparison - real Ansible's own
      # algorithm; MD5 for the backwards-compat `md5sum:` field).
      begin
        src_sha1 = native_checksum(src, "sha1")
        src_md5 = native_checksum(src, "md5")
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
        # force: false exits first - real's action never computes the
        # dest checksum on a force=false run (checksum=force in
        # _execute_remote_stat), so the equal-content shortcut below
        # can only fire when force is true (see #handle_content_copy's
        # note).
        if changed && !force
          # Real's result here is ONLY {dest, src, changed} - no msg, no
          # file-common stat fields, no checksum, no diff (live-verified
          # vs 2.19.11 at -v; src is the user's own src: path for a src
          # copy, and the action's staged content tempfile for a content
          # copy - the registered-result capture shows the raw dict).
          return PluginResult.new(
            changed: false,
            failed: false,
            dest: dest,
            src: src,
            key_order: NOOP_KEY_ORDER
          )
        end

        # Compare checksums for idempotency (only on a force=true run)
        begin
          dest_sha1 = native_checksum(dest, "sha1")

          if dest_sha1 == src_sha1
            # Files are identical
            changed = false
          end
        rescue File::Error
          # Ignore, continue with copy
        end
      end

      # CHECK MODE: Report what would change
      if @check_mode
        result = PluginResult.new(
          changed: changed,
          failed: false,
          msg: "",
          # A would-CHANGE check result is real Ansible's copy ACTION
          # PLUGIN's own bare `changed: true` (no dest, no stat fields).
          # A would-NOT-change one falls through to the file module (the
          # action's "already correct hash" branch), whose result carries
          # dest/path, the SHA1 checksum (added by the action's
          # `if not module_return.get('checksum')` fill-in), and the
          # add_path_info stat fields - all live-verified against
          # ansible-core 2.19.4.
          key_order: changed ? CHECK_KEY_ORDER : UNCHANGED_KEY_ORDER
        )
        unless changed
          result.extra["dest"] = JSON::Any.new(dest)
          result.extra["checksum"] = JSON::Any.new(src_sha1)
          add_path_info(result, dest)
        end
        return result
      end

      # If file is identical, just update attributes if requested - and
      # report changed if that reconciliation actually fixed anything
      # (same identical-content `changed: false` bug as
      # #handle_content_copy above; see its comment for the live repro).
      unless changed
        attributes_fixed, failure = apply_extended_attributes(dest)
        return failure if failure
        # Real's equal-content src path result (the action's
        # already-correct-hash branch calls the FILE module): dest + path
        # echo + stat fields, NO checksum key (live-verified vs 2.19.11
        # at -v; unlike the content path, whose equal result does carry
        # the action-injected checksum).
        result = PluginResult.new(
          changed: attributes_fixed,
          failed: false,
          dest: dest,
          key_order: UNCHANGED_KEY_ORDER
        )
        add_path_info(result, dest)
        result.extra["path"] = JSON::Any.new(dest)
        return result
      end

      # Create backup if requested
      backup_file = nil
      if true?(@params["backup"]?) && File.exists?(dest)
        backup_file = create_backup(dest)
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
            msg: "Destination directory #{dest_dir} does not exist",
            checksum: src_sha1,
            key_order: ["diff", "failed", "msg", "checksum"]
          )
        end
      end

      # Copy the file (staged + validated first when validate: is given -
      # src_sha1 was already computed above for the idempotency check, so
      # this reads src a second time only on the validate: path). The
      # staged temp path is not echoed here: on the src path real's
      # registered result echoes the user's own src: path (see the
      # src: below), unlike the content path whose src IS the staging
      # temp.
      if @params["validate"]?
        write = write_with_optional_validate(File.read(src), dest, src_sha1)
        write_failure = write[:failure]
        return write_failure if write_failure
      else
        write = atomic_write(File.read(src), dest)
        write_failure = write[:failure]
        return write_failure if write_failure
      end

      # Set ownership and permissions
      _attrs_fixed, failure = apply_extended_attributes(dest)
      return failure if failure

      result = PluginResult.new(
        changed: true,
        failed: false,
        dest: dest,
        # Real's src here is the action's staged .source.txt tempfile
        # path (live-verified) - krikri echoes the source path it
        # actually copied from, which is the same thing on the
        # remote_src path and the user's own path locally.
        src: src,
        checksum: src_sha1,
        md5sum: src_md5,
        key_order: CHANGED_KEY_ORDER
      )
      result.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      add_path_info(result, dest)
      result
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
    # The module-arg src as real's copy module formats it into its
    # missing-src message: Python str() of the value. A parser-marked
    # non-string literal keeps its native text (bools print True/False,
    # see Krikri.python_str_scalar) and a comma-joined list with marked
    # members reports its Python list repr - the demoted wire text alone
    # would print "true"/"false" or the bare join.
    private def python_module_src_text(src : String) : String
      if members = non_string_member_list("src")
        return python_list_repr(members)
      end
      if native = non_string_param("src")
        return Krikri.python_str_scalar(native)
      end
      src
    end

    private def python_list_repr(members : Array(JSON::Any)) : String
      "[" + members.join(", ") do |member|
        case raw = member.raw
        when String
          raw.includes?("'") && !raw.includes?('"') ? %("#{raw}") : "'#{raw}'"
        when Bool    then raw ? "True" : "False"
        when Nil     then "None"
        when Float64 then raw.to_s
        else              raw.to_s
        end
      end + "]"
    end

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
      Dir.glob(File.join(src, "**", "*"), match: File::MatchOptions.glob_default | File::MatchOptions::DotFiles, follow_symlinks: false).sort.each do |entry|
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

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Directory copied successfully" : "Directory already up to date",
        dest: dest_root,
        key_order: CHANGED_KEY_ORDER
      )
      # Real Ansible's add_path_info runs over the directory-copy result
      # too (dest is an existing directory at exit time) - stat fields
      # with state "directory", no checksum (its checksum: field is the
      # SRC file's SHA1, nil for a directory source).
      add_path_info(result, dest_root)
      result
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
    # Returns nil on success, or a failed PluginResult. The failure shape
    # is real copy.py's validate site (fail_json(msg="failed to validate",
    # exit_status=rc, stdout=out, stderr=err)) plus the action plugin's
    # unconditional `checksum` injection, stdout/stderr unstripped with
    # their _lines splitters added by _return_formatted (live-verified vs
    # 2.19.11).
    # Writes content to dest (staging through a temp file for the
    # result's `src` echo - real's src is its own staged tempfile, so the
    # success result needs the temp path the bytes actually travelled
    # through). Returns {failure: PluginResult?, staged: String?} -
    # failure is set on error, staged is the temp path the content was
    # written to (always set on success).
    # The registered src echo for content copies, in real's shape: the
    # copy action plugin stages the content on the target as
    # <remote_tmp>/ansible-tmp-<epoch.micro>-<pid>-<random>/.source
    # (action/copy.py: tmp_src = join(shell.tmpdir, '.source'), with the
    # dest's extension appended when it has one) and the module echoes
    # that path back. remote_tmp defaults to ~/.ansible/tmp of the
    # remote user - the user the plugin process runs as. Krikri's write
    # flow stages wherever it needs to, but the ECHO is reported in
    # real's shape (round 995005 deploy_helper_helper_block: real
    # /root/.ansible/tmp/ansible-tmp-.../.source, krikri its own
    # .krikri-playbook-copy-<hex>.tmp next to the dest).
    # The `~` MUST go through BasePlugin#expand_tilde ($HOME first, then
    # the passwd entry - the same order Python's os.path.expanduser uses
    # for it): Crystal's own File.expand_path does NOT expand a leading
    # tilde at all, so it joined the LITERAL "~" onto the plugin's
    # working directory and this echo came out as
    # /root/~/.ansible/tmp/ansible-tmp-.../.source on a root target
    # (round996005 deploy_helper_helper_block).
    private def staged_src_echo(dest : String) : String
      random = Random.rand(100_000_000_000_000..999_999_999_999_999)
      expand_tilde("~/.ansible/tmp/ansible-tmp-#{sprintf("%.7f", Time.local.to_unix_f)}-#{Process.pid}-#{random}/.source#{File.extname(dest)}")
    end

    private def write_with_optional_validate(content : String, dest : String, content_sha1 : String) : {failure: PluginResult?, staged: String?}
      validate_cmd = @params["validate"]?
      unless validate_cmd
        return atomic_write(content, dest)
      end

      temp_file = File.join("/tmp", ".krikri-playbook-copy-#{Random::Secure.hex(8)}.tmp")
      begin
        # SECURITY: created EMPTY 0600 and settled to its final mode
        # (0666 & ~umask for a new dest, narrowed by the task's numeric
        # mode: - this /tmp staging is mv'd in as a new inode, it does
        # NOT inherit an existing dest's mode, matching the old perm:
        # 0o666 creation semantics) BEFORE the content lands - see
        # BasePlugin#create_staging_temp. The old write-then-chmod
        # shape held the bytes at 0666 & ~umask for the whole write +
        # validate + move span.
        create_staging_temp(temp_file, staging_temp_mode(dest, 0o666, preserve_dest_mode: false))
        File.write(temp_file, content, perm: 0o600)
      rescue ex
        return {failure: PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}"), staged: nil}
      end

      validation = validate_file(temp_file, validate_cmd)
      unless validation[:ok]
        # Real copy.py: fail_json(msg="failed to validate", exit_status=rc,
        # stdout=out, stderr=err) - the raw, unstripped streams and the
        # exit status ride in the result; the real module does NOT keep
        # the staged content around (do_cleanup_files runs on failure).
        # stdout_lines/stderr_lines come from _return_formatted's own
        # splitter.
        stdout = validation[:stdout]
        stderr = validation[:stderr]
        result = PluginResult.new(
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
        return {failure: result, staged: nil}
      end

      begin
        FileUtils.mv(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        return {failure: PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}"), staged: nil}
      end

      {failure: nil, staged: temp_file}
    end

    # Validate file with command - like template.cr's own helper, but
    # returns the raw stdout/stderr streams and exit status separately
    # (real copy.py's validate failure result carries them unmerged and
    # unstripped).
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

    # Create backup of file
    private def create_backup(path : String) : String
      # Real Ansible's backup_local uses LOCAL time (time.localtime), not
      # UTC (live-verified vs 2.19.11: a backup taken at 19:12 EDT is
      # named ...@19:12:40~, not ...@23:12:40~).
      timestamp = Time.local.to_s("%Y-%m-%d@%H:%M:%S")
      # Real Ansible's backup_local inserts the
      # process PID between path and timestamp, not a random number:
      # `<path>.<pid>.<yyyy-mm-dd@hh:mm:ss>~`.
      backup_path = "#{path}.#{Process.pid}.#{timestamp}~"

      begin
        File.copy(path, backup_path)
      rescue File::Error
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
        rescue File::Error
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

      # A present owner:/group: value (explicit empty string included)
      # is always resolved - and an unresolvable name fails the task
      # like real Ansible's basic.py (round900811 kilip.chezmoi) -
      # instead of the old `&&`-short-circuit that silently skipped the
      # chown whenever the lookup came back empty.
      if owner = @params["owner"]?
        uid = resolve_owner_uid(owner)
      end

      if group = @params["group"]?
        gid = resolve_group_gid(group)
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      after = File.info?(path, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions ||
        before.owner_id != after.owner_id ||
        before.group_id != after.group_id
    rescue File::Error
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
    private def atomic_write(content : String, dest : String) : {failure: PluginResult?, staged: String?}
      temp_file = File.join(File.dirname(dest), ".krikri-playbook-copy-#{Random::Secure.hex(8)}.tmp")
      begin
        # SECURITY: the temp is created EMPTY at 0600 and settled to its
        # final mode (the task's numeric mode:, else the dest's preserved
        # mode, else 0666 & ~umask) BEFORE any content lands in it - see
        # BasePlugin#create_staging_temp. Writing first and chmod-ing
        # later (the old shape, with the temp at 0666 & ~umask while the
        # bytes were already on disk) briefly left a copied private key
        # readable at the default mode before the mode: was applied.
        create_staging_temp(temp_file, staging_temp_mode(dest, 0o666))

        # Ownership of an existing dest is still reconciled onto the temp
        # before the rename (the mode is already settled above).
        begin
          if !File.symlink?(dest) && (info = File.info?(dest, follow_symlinks: false))
            begin
              File.chown(temp_file, uid: info.owner_id.to_i, gid: info.group_id.to_i)
            rescue File::Error
              # Best-effort: non-root can't chown; the rename still
              # yields a correct file with this process's ownership.
            end
          end
        rescue File::Error
          # Stat itself failed (broken dest?) - proceed without
          # ownership preservation.
        end

        # perm 0600 only matters if the temp vanished between creation
        # and here (an external /tmp cleaner): recreate narrow, never
        # wide.
        File.write(temp_file, content, perm: 0o600)
      rescue ex
        return {failure: PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}"), staged: nil}
      end

      if given_checksum = @params["checksum"]?.presence
        actual = sha1_of(temp_file)
        unless actual == given_checksum
          File.delete(temp_file) if File.exists?(temp_file)
          failure = PluginResult.new(
            changed: false,
            failed: true,
            msg: "Copied file does not match the expected checksum. Transfer failed.",
            checksum: actual,
            expected_checksum: given_checksum
          )
          return {failure: failure, staged: nil}
        end
      end

      begin
        File.rename(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        if true?(@params["unsafe_writes"]?)
          failure = unsafe_write_fallback(content, dest)
          return {failure: failure, staged: nil}
        end
        return {failure: PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}"), staged: nil}
      end

      {failure: nil, staged: temp_file}
    end

    # unsafe_writes: the non-atomic fallback - write dest directly, in
    # place. Returns nil on success, or a failed PluginResult.
    private def unsafe_write_fallback(content : String, dest : String) : PluginResult?
      # Same umask-default contract as #atomic_write's temp file: 0666 &
      # ~umask for a new file, existing file's mode untouched (opening an
      # existing file for writing never changes its mode, so there is no
      # window to close in that case). A new dest is created EMPTY 0600
      # and settled to its final mode before the bytes land - see
      # BasePlugin#create_staging_temp.
      unless File.exists?(dest)
        create_staging_temp(dest, staging_temp_mode(dest, 0o666, preserve_dest_mode: false))
      end
      File.write(dest, content, perm: 0o600)
      nil
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to write #{dest} (unsafe_writes fallback): #{ex.message}")
    end

    # attributes:/attr: - chattr-style flags (e.g. "+i" for immutable),
    # real Ansible's `attributes` param and its `attr` alias. Parsed
    # into the leading operator ('+'/'-', defaulting to '=' when bare)
    # plus the flag letters themselves - real Ansible's
    # set_attributes_if_different in the real module does exactly
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
    rescue File::Error
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
