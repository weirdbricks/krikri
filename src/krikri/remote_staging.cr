require "digest/sha1"

module Krikri
  # The shared per-host staging tree: plugin binaries, batch working dirs and
  # the SSM rsync bridge all live under one per-user directory here.
  #
  # `/var/tmp`, not `/tmp`: some hardening roles remount `/tmp` as a fresh,
  # empty tmpfs mid-play, which would wipe anything staged there. The
  # `<name>-<hash>` tag keeps the path collision-proof and unpredictable
  # enough that a local user cannot pre-create it; PluginManager and the SSM
  # bridge verify ownership/symlink-freedom before using it, and the
  # directories are mode 0711 (traversable for a `become_user:` exec, never
  # listable or writable by anyone else).
  module RemoteStaging
    extend self

    BASE = "/var/tmp/.krikri-playbook"

    # Stable, collision-proof directory-name tag for a connecting user: the
    # sanitized name stays human-readable, the hash suffix guarantees two
    # distinct users never map to one directory (and that a hostile username
    # can't alias an existing path).
    def dir_tag(user : String) : String
      safe = user.gsub(/[^a-zA-Z0-9._-]/, "-")
      "#{safe}-#{Digest::SHA1.hexdigest(user)[0, 8]}"
    end

    def plugin_dir(remote_user : String?) : String
      user = remote_user.presence || "root"
      "#{BASE}-#{dir_tag(user)}/plugins"
    end
  end
end
