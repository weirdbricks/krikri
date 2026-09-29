#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # fetch plugin (ansible.builtin.fetch) - pulls a file from the target to
  # the controller, the inverse of copy. Always dispatched to run on the
  # controller (see PluginManager::CONTROLLER_ONLY_PLUGINS) so
  # BasePlugin#remote_download can actually SSH-pull from a genuinely
  # remote target; a local connection is a plain file copy via the same
  # helper.
  #
  # Real Ansible's fetch documents full check-mode support, but actually
  # skips outright under --check with "check mode not (yet) supported for
  # this module" (verified against a real ansible-playbook --check run,
  # not the docs) - reused verbatim here.
  class FetchPlugin < BasePlugin
    # ansible.builtin.fetch's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.fetch). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[fail_on_missing flat validate_checksum]
    end

    def execute : PluginResult
      src = @params["src"]?
      dest = @params["dest"]?
      return missing_arg_result("src") unless src
      return missing_arg_result("dest") unless dest
      dest = expand_tilde(dest)
      validate_bool_params!

      if result = preflight_result(src)
        return result
      end

      dest_check = resolve_dest_path(dest, src)
      if failure = dest_check[:error]
        return PluginResult.new(changed: false, failed: true, msg: failure)
      end
      dest_path = dest_check[:path] || raise("resolve_dest_path returned no path and no error")
      remote_checksum = source_checksum(src)

      if unchanged?(dest_path, remote_checksum)
        return unchanged_result(dest_path, remote_checksum, src)
      end

      if result = ensure_dest_dir(dest_path, src)
        return result
      end
      remote_download(src, dest_path)

      success_result(dest_path, remote_checksum, src)
    end

    private def missing_arg_result(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required argument: #{name}")
    end

    # Everything that can fail before any destination resolution or
    # checksum work happens, in the order real fetch performs the checks.
    private def preflight_result(src : String) : PluginResult?
      return unsafe_host_result(src) if !true?(@params["flat"]?) && unsafe_host_dir_name?(@host.name)
      return check_mode_result if true?(@params["_ansible_check_mode"]?)
      # Real fetch's action plugin type-checks src/dest BEFORE anything
      # else (after only the check-mode skip): `if not isinstance(source,
      # string_types)` - a non-string YAML literal (`dest: 89`, `src:
      # true`) fails AnsibleActionFail. The dest message OVERWRITES the
      # src message (the two plain `if`s run in that order), so dest wins
      # when both are non-string (live-verified vs 2.19.11).
      return invalid_type_result("dest") if non_string_param("dest")
      return invalid_type_result("source") if non_string_param("src")
      return missing_src_result(src) unless remote_file_exists?(src)
      return directory_src_result(src) if remote_dir_exists?(src)
      nil
    end

    # Real fetch's AnsibleActionFail failure: the fatal dump carries the
    # bare message (no "Task failed:" prefix) while the [ERROR] block shows
    # "Task failed: <msg>" with no middle segment - the action-level
    # _ansible_action_level shape (live-verified vs 2.19.11).
    private def invalid_type_result(option : String) : PluginResult
      PluginResult.new(
        changed: false, failed: true,
        msg: "Invalid type supplied for #{option} option, it must be a string",
        _ansible_action_level: true,
      )
    end

    private def unsafe_host_result(src : String) : PluginResult
      PluginResult.new(
        changed: false, failed: true,
        msg: "inventory hostname '#{@host.name}' cannot be used as a fetch destination directory (path separators or '..' would escape dest)",
        file: src,
      )
    end

    private def check_mode_result : PluginResult
      PluginResult.new(changed: false, failed: false, msg: "check mode not (yet) supported for this module", skipped: true)
    end

    private def directory_src_result(src : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "remote path is a directory, not a file", file: src)
    end

    private def unchanged_result(dest_path : String, remote_checksum : String, src : String) : PluginResult
      PluginResult.new(changed: false, failed: false, msg: "file already present", checksum: remote_checksum, md5sum: native_checksum(dest_path, "md5"), dest: dest_path, file: src)
    end

    private def success_result(dest_path : String, remote_checksum : String, src : String) : PluginResult
      PluginResult.new(
        changed: true, failed: false, msg: "OK",
        dest: dest_path, checksum: remote_checksum,
        md5sum: native_checksum(dest_path, "md5"),
        remote_checksum: remote_checksum, remote_md5sum: nil
      )
    end

    private def ensure_dest_dir(dest_path : String, src : String) : PluginResult?
      dest_dir = File.dirname(dest_path)
      return nil if Dir.exists?(dest_dir)
      begin
        Dir.mkdir_p(dest_dir)
        nil
      rescue e : File::Error
        # Real fetch's dest-dir creation runs on the CONTROLLER
        # (makedirs_safe inside the action plugin's run()) - a
        # non-directory ancestor (flat: false into /etc/passwd/target/
        # ... with /etc/passwd a file) escapes run() as an AnsibleError,
        # so the failure result carries no `changed` key at all
        # (registered `changed` is undefined, not false).
        PluginResult.new(
          changed: false, failed: true, omit_changed: true,
          msg: "Unable to create local directories(#{dest_dir}): #{e.message}",
          file: src,
        )
      end
    end

    private def missing_src_result(src : String) : PluginResult
      msg = "the remote file does not exist, not transferring, ignored"
      fail_on_missing = true?(@params["fail_on_missing"]?, default: true)
      # fail_on_missing (default): real 2.19.11's action plugin ends up with
      # the slurp module's failure - the fatal dump carries only changed+msg
      # (no `file` key) while the [ERROR] block shows the module's own text
      # (carried in _ansible_error_detail, stripped from every dump).
      if fail_on_missing
        return PluginResult.new(changed: false, failed: true, msg: msg,
          _ansible_error_detail: "File not found: #{src}: [Errno 2] No such file or directory: '#{src}'")
      end
      PluginResult.new(changed: false, failed: false, msg: msg, file: src)
    end

    private def unchanged?(dest_path : String, remote_checksum : String) : Bool
      return false unless File.exists?(dest_path)
      return false unless true?(@params["validate_checksum"]?, default: true)
      native_checksum(dest_path, "sha1") == remote_checksum
    end

    # `flat: false` (the default) mirrors real Ansible's own layout:
    # dest/<inventory_hostname>/<src, kept exactly as given, leading slash
    # and all>. `flat: true` writes straight to dest (or dest/<basename of
    # src> when dest ends with a path separator, same convention copy:
    # uses for a directory dest).
    #
    # Real fetch composes the destination and then applies
    # os.path.normpath before touching the filesystem, so the path is
    # normalized either way. The composition itself is plain string
    # concatenation that neither normalizes nor rejects '..', so a src
    # like "/../../etc/passwd" would resolve outside dest when the path
    # is opened. Upstream's own containment guard (is_subpath, added with
    # the CVE-2019-3828 fix) compares dest against original_dest while
    # the two are still the same string and can never fire (verified
    # against ansible-core 2.19: it normalizes and writes through the
    # escaped path), so this port enforces the containment upstream
    # intended: a composed destination that escapes dest fails with the
    # message from that guard instead of writing outside it.
    private def resolve_dest_path(dest : String, src : String) : {path: String?, error: String?}
      composed = if true?(@params["flat"]?)
                   dest.ends_with?(File::SEPARATOR) ? File.join(dest, File.basename(src)) : dest
                 else
                   File.join(dest, @host.name, src)
                 end
      normalized = File.expand_path(composed)
      return {path: normalized, error: nil} if contained_in_dest?(dest, normalized)
      {path: nil, error: "Detected directory traversal, expected to be contained in '#{dest}' but got '#{composed}'"}
    end

    # Equivalent of ansible.utils.path.is_subpath on lexically normalized
    # absolute paths: child is contained when it equals the parent or
    # lives underneath it. dest has already been tilde-expanded by the
    # caller; File.expand_path also folds any '..' the dest itself
    # carries, so a dest that normalizes outside itself still bounds the
    # check at its real location.
    private def contained_in_dest?(dest : String, child : String) : Bool
      parent = File.expand_path(dest)
      child == parent || child.starts_with?(parent.chomp(File::SEPARATOR) + File::SEPARATOR)
    end

    # `File.join` is plain string concatenation - it neither normalizes
    # nor rejects '..' - so a hostname containing '/' or '..' would write
    # outside the dest directory. Hostname comes from the playbook
    # author's own inventory, but an escaping destination is never
    # intended, so it's rejected outright.
    private def unsafe_host_dir_name?(name : String) : Bool
      name.empty? || name.includes?('/') || name.includes?('\\') || name.includes?('\0') || name == "." || name == ".."
    end

    # For a local connection, the source is directly readable from this
    # (controller) process - a plain native checksum. For a genuinely
    # remote host, there's no local filesystem access to it yet (that's
    # the whole point of fetching it), so the checksum has to be computed
    # on the far side and shelled over SSH - a real, narrow "genuine
    # remote operation, no native equivalent" case, the same category this
    # codebase's other plugins (apt/dnf/service/...) already carve out.
    private def source_checksum(src : String) : String
      if local_connection?
        native_checksum(src, "sha1")
      else
        result = remote_exec("sha1sum #{shell_single_quote(src)}")
        result[:stdout].split.first? || ""
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::FetchPlugin.new(config)
plugin.run
