module Krikri
  module PluginHelpers
    # Real AnsibleModule.set_fs_attributes_if_different (basic.py) and
    # the add_path_info its result passes through - the shared protocol
    # layer behind `add_file_common_args`, for the plugins that hand-roll
    # their owner:/group:/mode: application instead of going through the
    # copy/lineinfile file-* helpers.
    #
    # Own one implementation of all three details, which are easy to get
    # subtly wrong per-plugin:
    #
    # - ORDER. basic.py applies secontext, then owner, then group, then
    #   mode, then attributes. Owner before group matters: a task with
    #   both a rejected chown and a rejected chgrp reports the CHOWN one.
    # - FAILURE SHAPE. An unresolvable owner:/group: name fails with
    #   "chown failed: failed to look up user X" / "chgrp failed: failed
    #   to look up group X" (base_plugin's OwnerLookupFailure already
    #   raises exactly those, and its run_and_capture rescue surfaces
    #   them verbatim). A rejected chown syscall fails with the bare
    #   "chown failed" in the fatal msg and the OSError's own text
    #   appended in the [ERROR] block - real's
    #   `fail_json(path=..., msg='chown failed', exception=ex)` pair.
    #   chgrp carries no detail at all (`fail_json(msg='chgrp failed')`).
    #   A rejected chmod is only a warning: set_mode_if_different logs it
    #   and carries on.
    # - WHEN. The walk runs at module-exit on an UNCHANGED result too, so
    #   an owner:/group:/mode: that drifted from the file is itself a
    #   change, and an existing path's stat fields (uid/gid/owner/group/
    #   mode/state/size) ride along on the result either way.
    #
    # Live-verified against ansible-core 2.19.11 for ini_file (kpg32
    # seed 32) and htpasswd.
    module FileAttrs
      # Returns {changed, failure}: failure a failed PluginResult when an
      # owner:/group: could not be applied, nil otherwise.
      def apply_file_attrs(path : String, check_mode : Bool) : {Bool, PluginResult?}
        return {false, nil} if check_mode || !File.exists?(path)

        changed = false

        if owner = @params["owner"]?
          uid = resolve_owner_uid(owner)
          if before_uid(path) != uid
            return {false, chown(path, uid)}
          end
          changed = true
        end

        if group = @params["group"]?
          gid = resolve_group_gid(group)
          if before_gid(path) != gid
            failure = chgrp(path, gid)
            return {false, failure} if failure
          end
          changed = true
        end

        if mode = @params["mode"]?
          # A symbolic mode has no value to compare against, so real
          # chmods it unconditionally - but set_mode_if_different only
          # reports changed when the octal form actually differs.
          if numeric = parse_mode(mode)
            if before_mode(path) != numeric
              chmod(path, mode)
              changed = true
            end
          else
            chmod(path, mode)
          end
        end

        {changed, nil}
      end

      # Real parses ANY all-digit mode string as octal, leading zero or
      # not ("640" and "0640" are identical); a symbolic mode ("u+x") has
      # no libc equivalent and goes to the real chmod binary, exactly
      # like copy.cr's own apply_file_attributes.
      def parse_mode(mode : String) : Int32?
        return mode.to_i(8) if mode =~ /\A0?[0-7]{3,4}\z/
        nil
      end

      def before_uid(path : String) : Int32?
        raw_stat(path).try { |stat| stat.st_uid.to_i }
      end

      def before_gid(path : String) : Int32?
        raw_stat(path).try { |stat| stat.st_gid.to_i }
      end

      def before_mode(path : String) : Int32?
        raw_stat(path).try { |stat| (stat.st_mode & 0o7777).to_i }
      end

      def raw_stat(path : String) : LibC::Stat?
        s = uninitialized LibC::Stat
        LibC.stat(path, pointerof(s)) == 0 ? s : nil
      rescue
        nil
      end

      # Each returns nil on success and the failure real Ansible reports
      # otherwise, with the fatal msg and the [ERROR] block text split
      # the way real's own fail_json(msg=..., exception=...) pair
      # renders them.
      def chown(path : String, uid : Int32) : PluginResult?
        File.chown(path, uid: uid, gid: -1)
        nil
      rescue ex : File::Error
        attrs_failure(path, "chown failed", "chown failed: #{os_error_text(ex, path)}")
      end

      def chgrp(path : String, gid : Int32) : PluginResult?
        File.chown(path, uid: -1, gid: gid)
        nil
      rescue
        attrs_failure(path, "chgrp failed", "chgrp failed")
      end

      def chmod(path : String, mode : String) : Nil
        if numeric = parse_mode(mode)
          File.chmod(path, numeric)
        else
          Process.run("chmod", [mode, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
        end
      rescue
      end

      # Real's fail_json(path=..., msg=..., exception=...) routes through
      # add_path_info, so the file's stat fields ride along on the
      # failure too - exactly as on a successful result.
      def attrs_failure(path : String, msg : String, detail : String) : PluginResult
        result = PluginResult.new(changed: false, failed: true, msg: msg, path: path, _ansible_error_detail: detail)
        add_path_info(result, path)
        result
      end

      # Formats the Errno the way Python's str(OSError) does over a
      # BYTES path - the b'...' repr included, since that is literally
      # what real's os.lchown(b_path, ...) raises with.
      def os_error_text(ex : File::Error, path : String) : String
        errno = ex.os_error.try(&.value)
        strerror = ex.os_error.try(&.message) || "Unknown error"
        "[Errno #{errno}] #{strerror}: b'#{path}'"
      end
    end
  end
end
