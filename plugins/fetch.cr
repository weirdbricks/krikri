#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
    def execute : PluginResult
      src = @params["src"]?
      dest = @params["dest"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: src") unless src
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: dest") unless dest
      dest = expand_tilde(dest)

      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: false, failed: false, msg: "check mode not (yet) supported for this module", skipped: true)
      end

      unless remote_file_exists?(src)
        return missing_src_result(src)
      end

      if remote_dir_exists?(src)
        return PluginResult.new(changed: false, failed: true, msg: "remote path is a directory, not a file", file: src)
      end

      dest_path = resolve_dest_path(dest, src)
      remote_checksum = source_checksum(src)

      if unchanged?(dest_path, remote_checksum)
        return PluginResult.new(changed: false, failed: false, msg: "file already present", checksum: remote_checksum, md5sum: native_checksum(dest_path, "md5"), dest: dest_path, file: src)
      end

      dest_dir = File.dirname(dest_path)
      Dir.mkdir_p(dest_dir) unless Dir.exists?(dest_dir)
      remote_download(src, dest_path)

      PluginResult.new(
        changed: true, failed: false, msg: "OK",
        dest: dest_path, checksum: remote_checksum,
        md5sum: native_checksum(dest_path, "md5"),
        remote_checksum: remote_checksum, remote_md5sum: nil
      )
    end

    private def missing_src_result(src : String) : PluginResult
      msg = "the remote file does not exist, not transferring, ignored"
      fail_on_missing = is_true?(@params["fail_on_missing"]?, default: true)
      PluginResult.new(changed: false, failed: fail_on_missing, msg: msg, file: src)
    end

    private def unchanged?(dest_path : String, remote_checksum : String) : Bool
      return false unless File.exists?(dest_path)
      return false unless is_true?(@params["validate_checksum"]?, default: true)
      native_checksum(dest_path, "sha1") == remote_checksum
    end

    # `flat: false` (the default) mirrors real Ansible's own layout:
    # dest/<inventory_hostname>/<src, kept exactly as given, leading slash
    # and all>. `flat: true` writes straight to dest (or dest/<basename of
    # src> when dest ends with a path separator, same convention copy:
    # uses for a directory dest).
    private def resolve_dest_path(dest : String, src : String) : String
      if is_true?(@params["flat"]?)
        dest.ends_with?(File::SEPARATOR) ? File.join(dest, File.basename(src)) : dest
      else
        File.join(dest, @host.name, src)
      end
    end

    # For a local connection, the source is directly readable from this
    # (controller) process - a plain native checksum. For a genuinely
    # remote host, there's no local filesystem access to it yet (that's
    # the whole point of fetching it), so the checksum has to be computed
    # on the far side and shelled over SSH - a real, narrow "genuine
    # remote operation, no native equivalent" case, the same category this
    # codebase's other plugins (apt/dnf/service/...) already carve out.
    private def source_checksum(src : String) : String
      if is_local_connection?
        native_checksum(src, "sha1")
      else
        result = remote_exec("sha1sum '#{src}'")
        result[:stdout].split.first? || ""
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::FetchPlugin.new(config)
plugin.run
