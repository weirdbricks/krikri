require "file_utils"
require "./cli_options"
require "./module_registry"

module Krikri
  # Issue #1755 - module plugins built and shipped OUTSIDE this tree.
  #
  # Before this, every native module was `plugins/<name>.cr`, registered in
  # `PlaybookParser::AVAILABLE_PLUGINS` at compile time, and `PluginManager`
  # only resolved binaries from its own `plugins/` + per-platform
  # `plugins-<key>/` + cwd-relative `./bin/plugins*/` fallbacks. Porting an
  # in-house module therefore meant forking krikri and rebuilding it for
  # every release. The execution boundary was already a process boundary
  # (JSON config on stdin, JSON result on stdout) and upload/md5-dedup/
  # batching/remote staging are all name-keyed, so the only missing pieces
  # were registration and path lookup - nothing on that path is
  # Crystal-specific, so a Rust, Go, Nim or Zig binary, or a shebang script,
  # works exactly like a krikri-built one.
  #
  # Layout (mirrors `PluginManager.platform_key`, so a same-OS target gets
  # the controller's own binaries and another OS gets `<os>-<arch>`):
  #
  #   <root>/
  #     mycompany.internal.foo                    # controller platform
  #     plugins-linux-x86_64/mycompany.internal.foo
  #     plugins-linux-aarch64/mycompany.internal.foo
  #
  # Resolution rules (enforced in PluginManager#runtime_plugin_path):
  #   - local connections (including `delegate_to: localhost`) and
  #     same-platform remote targets use the flat `<name>` only.
  #   - a remote target whose platform key differs from the controller's
  #     uses `plugins-<key>/<name>` ONLY - never a flat fallback, which
  #     could only produce an exec-format failure on the target.
  #   - external directories resolve by exact filename. The fat-plugin "any
  #     executable file in the directory" fallback deliberately does NOT
  #     apply here: for those dirs it exists because one binary serves
  #     every module name, while here it would silently run a DIFFERENT
  #     plugin than the task named.
  #
  # Discovered from `--plugin-path DIR` (repeatable) and the
  # `KRIKRI_PLUGIN_PATH` environment variable (path-separator separated),
  # never from the current directory. These names are krikri-only: no
  # Python path reads them, and `library/`, ANSIBLE_LIBRARY and
  # ANSIBLE_*_PLUGINS keep meaning exactly what they mean to Ansible.
  class RuntimePluginRegistry
    # Bad operator input (a missing/symlinked/unsafe root, an invalid or
    # reserved plugin name, one name from two roots). Raised at configure
    # time - i.e. before the playbook is even parsed - so a misconfigured
    # plugin directory fails the run immediately instead of surfacing as a
    # missing task later.
    class ConfigError < Exception
    end

    # The namespaces `PluginManager.simple_plugin_name` strips. An external
    # plugin in one of them would be silently renamed on the way to both its
    # filename and its remote staging name, and could then collide with a
    # built-in plugin of the same basename - so they are rejected instead.
    # SHARED with `simple_plugin_name` (single source of truth), and the
    # dots are escaped: the pattern previously read `community.(general|...)`,
    # where the unescaped dot also matched `communityXgeneral.`.
    STRIPPED_NAMESPACE = /\A(ansible\.(builtin|legacy|posix|mysql)|community\.(general|docker|mysql|postgresql|crypto|rabbitmq)|ovirt\.ovirt|amazon\.aws|containers\.podman)\./

    # A plugin name is a path component locally, in the remote staging
    # directory, and in the shell/batch target string: no slashes, no
    # leading dot, no spaces or glob characters.
    NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

    # Every name an external plugin may not take: what krikri implements
    # natively (`AVAILABLE_PLUGINS`), plus the alias keys
    # `PlaybookParser.resolve_module_name` answers from BEFORE consulting
    # this registry. Without them, a plugin named e.g. `raw` would be
    # accepted and then silently replaced by the alias target, so the
    # operator's binary never ran even though registration succeeded.
    RESERVED_NAMES = begin
      names = Set(String).new
      PlaybookParser::AVAILABLE_PLUGINS.each { |name| names << name }
      PlaybookParser::MODULE_ALIASES.each_key { |name| names << name }
      names
    end

    ARCH_DIR_PREFIX = "plugins-"

    private class Entry
      property flat : String?
      getter archs = Hash(String, String).new

      def initialize(@flat : String? = nil)
      end
    end

    @@configured = false
    @@roots = [] of String
    @@index = Hash(String, Entry).new

    # Validates and indexes *paths*. An external plugin may not shadow a
    # name krikri itself answers (RESERVED_NAMES, which the lazy
    # `ensure_loaded` path uses too, so a caller that never configures
    # explicitly still gets the shadowing check). `--plugin-path`/
    # KRIKRI_PLUGIN_PATH entries are operator input, so a bad one is a hard
    # error rather than a skip.
    def self.configure(paths : Array(String), reserved_names : Set(String) = RESERVED_NAMES) : Nil
      roots = paths.map { |path| File.expand_path(path) }.uniq!
      index = build_index(roots, expand_reserved(reserved_names))
      @@roots = roots
      @@index = index
      @@configured = true
    end

    # The built-in registry is a set of task spellings (mostly FQCNs like
    # `ansible.builtin.command`, plus bare aliases); a plugin FILE is named
    # after the stripped form, so both spellings count as taken.
    private def self.expand_reserved(reserved_names : Set(String)) : Set(String)
      expanded = Set(String).new
      reserved_names.each do |name|
        expanded << name
        expanded << name.sub(STRIPPED_NAMESPACE, "")
      end
      expanded
    end

    # Drops all configuration. Spec-only: production code configures once at
    # startup and never un-configures.
    def self.reset : Nil
      @@configured = false
      @@roots = [] of String
      @@index = Hash(String, Entry).new
    end

    # `--plugin-path` first, then KRIKRI_PLUGIN_PATH, both absolutized
    # against the INVOCATION directory and de-duplicated. krikri-playbook.cr
    # resolves this once, before its chdir into the playbook's directory,
    # and writes it back into the environment - which is both how the local
    # `__async_run` re-invocation inherits the same roots (it re-enters this
    # program after the chdir, so a relative path must already be absolute)
    # and why the expansion cannot be left to configure().
    def self.discovery_paths : Array(String)
      from_env = ENV["KRIKRI_PLUGIN_PATH"]?.to_s.split(':').reject(&.empty?)
      (CliOptions.plugin_paths + from_env).map { |path| File.expand_path(path) }.uniq!
    end

    def self.registered?(name : String) : Bool
      ensure_loaded
      @@index.has_key?(name)
    end

    # The flat (controller-platform) binary for *name*, or nil.
    def self.flat_path(name : String) : String?
      ensure_loaded
      @@index[name]?.try(&.flat)
    end

    # The `plugins-<key>/` binary for *name*, or nil. Never falls back to
    # flat: a different-platform target cannot execute the controller's own
    # build (issue #1's arch-awareness rule).
    def self.arch_path(name : String, key : String) : String?
      ensure_loaded
      @@index[name]?.try(&.archs[key]?)
    end

    def self.root_dirs : Array(String)
      ensure_loaded
      @@roots
    end

    # The directories a flat lookup consults, for not-found messages.
    def self.flat_search_dirs : Array(String)
      root_dirs.map { |root| File.join(root, "") }
    end

    # The directories a per-platform lookup consults, for
    # PluginArchUnsupportedError's message.
    def self.arch_search_dirs(key : String) : Array(String)
      root_dirs.map { |root| File.join(root, "#{ARCH_DIR_PREFIX}#{key}", "") }
    end

    def self.registered_names : Array(String)
      ensure_loaded
      @@index.keys.sort!
    end

    private def self.ensure_loaded : Nil
      return if @@configured
      configure(discovery_paths)
    end

    private def self.build_index(roots : Array(String), reserved_names : Set(String)) : Hash(String, Entry)
      index = Hash(String, Entry).new
      roots.each do |root|
        validate_root(root)
        list_dir(root).each do |child|
          index_child(index, File.join(root, child), child, reserved_names)
        end
      end
      index
    end

    # One entry of a plugin root: either a per-platform `plugins-<key>/`
    # directory or a flat plugin. Anything else (a real subdirectory, a
    # README, a hidden file) is ordinary content and is left alone.
    private def self.index_child(index : Hash(String, Entry), path : String, child : String, reserved_names : Set(String)) : Nil
      if child.starts_with?(ARCH_DIR_PREFIX)
        index_platform_dir(index, path, child, reserved_names)
      elsif !File.directory?(path) || File.symlink?(path)
        register(index, child, path, nil, reserved_names)
      end
    end

    private def self.index_platform_dir(index : Hash(String, Entry), path : String, child : String, reserved_names : Set(String)) : Nil
      if File.symlink?(path)
        # A symlinked platform DIRECTORY would hide every build under it
        # (and then silently skip every task needing that platform); a
        # symlinked executable is the same trust-boundary problem as a flat
        # one. Other symlinked content (a README) is ignored like any other
        # non-plugin entry.
        if File.directory?(path)
          raise ConfigError.new(
            "external plugin platform directory #{path} is a symlink; plugin directories must be " \
            "real directories, or every build under it is silently unreachable"
          )
        elsif File::Info.executable?(path) && File.file?(path)
          raise ConfigError.new(
            "external plugin #{path} is a symlink; plugins must be regular files (krikri uploads " \
            "the file itself to managed hosts)"
          )
        end
        return
      end

      unless File.directory?(path)
        # A valid plugin name, but the reserved per-platform prefix would
        # make it ambiguous with a plugins-<key>/ directory.
        if File::Info.executable?(path) && File.file?(path)
          raise ConfigError.new(
            "external plugin #{path} uses the reserved #{ARCH_DIR_PREFIX}<key> directory prefix; " \
            "rename the plugin"
          )
        end
        return
      end

      key = child.byte_slice(ARCH_DIR_PREFIX.size)
      return if key.empty?
      list_dir(path).each do |arch_child|
        register(index, arch_child, File.join(path, arch_child), key, reserved_names)
      end
    end

    # `Dir.children` raises a plain File::Error for an unlistable directory;
    # reporting the root/arch dir as a ConfigError keeps every misconfiguration
    # in the one channel krikri-playbook.cr already reports cleanly.
    private def self.list_dir(dir : String) : Array(String)
      Dir.children(dir).sort!
    rescue ex
      raise ConfigError.new("external plugin directory #{dir} cannot be listed (#{ex.message}); check its permissions")
    end

    private def self.validate_root(root : String) : Nil
      raise ConfigError.new("external plugin directory #{root} does not exist") unless File.exists?(root)
      raise ConfigError.new("external plugin directory #{root} is not a directory") unless File.directory?(root)
      raise ConfigError.new("external plugin directory #{root} is a symlink; point --plugin-path/KRIKRI_PLUGIN_PATH at the real directory instead") if File.symlink?(root)

      info = File.info(root)
      if info.permissions.group_write? || info.permissions.other_write?
        raise ConfigError.new(
          "external plugin directory #{root} is group- or world-writable (#{info.permissions}); " \
          "chmod it to remove group/other write access first"
        )
      end

      # Owned by the invoking user, or by root - a root-owned install under
      # /usr/local or /opt is the normal system-wide case, and is no more
      # writable by a local user than the user's own directory.
      owner = info.owner_id.to_u32? || return
      unless owner == LibC.getuid || owner == 0
        raise ConfigError.new(
          "external plugin directory #{root} is owned by uid #{owner}, not the current user " \
          "(#{LibC.getuid}) or root; refusing to load plugins from a foreign-owned directory"
        )
      end
    end

    private def self.register(index : Hash(String, Entry), name : String, path : String, key : String?, reserved_names : Set(String)) : Nil
      return if name.empty? || name.starts_with?(".")
      return unless usable_plugin?(name, path, reserved_names)

      entry = index[name] ||= Entry.new
      existing = key ? entry.archs[key]? : entry.flat
      if existing
        raise ConfigError.new(
          "external plugin #{name} is provided twice#{key ? " for platform #{key}" : ""}: " \
          "#{existing} and #{path}; a plugin name must resolve to exactly one file"
        )
      end

      if key
        entry.archs[key] = path
      else
        entry.flat = path
      end
    end

    # Whether *path* may be registered as plugin *name*, raising for the
    # cases that are an operator mistake rather than ordinary directory
    # content (see each message's own reasoning).
    private def self.usable_plugin?(name : String, path : String, reserved_names : Set(String)) : Bool
      unless name.matches?(NAME_PATTERN)
        # A non-conforming but EXECUTABLE file is almost certainly a plugin
        # the operator meant to register (a space in the name), so refusing
        # it beats silently not registering it. Anything else (README, a
        # .md5 sidecar, a lock file) is ordinary directory content.
        if File::Info.executable?(path) && File.file?(path)
          raise ConfigError.new(
            "external plugin name #{name.inspect} in #{File.dirname(path)} is not a valid plugin name: " \
            "names must match #{NAME_PATTERN.source} (letters, digits, dot, dash, underscore; no " \
            "leading dot, slash, space or glob character)"
          )
        end
        return false
      end

      # "The file must be executable; a non-executable match is not a match."
      return false unless File::Info.executable?(path)
      if File.symlink?(path)
        raise ConfigError.new(
          "external plugin #{name} in #{File.dirname(path)} is a symlink; plugins must be regular " \
          "files (krikri uploads the file itself to managed hosts)"
        )
      end
      return false unless File.file?(path)

      if name.matches?(STRIPPED_NAMESPACE)
        raise ConfigError.new(
          "external plugin name #{name.inspect} in #{File.dirname(path)} is in a namespace krikri " \
          "reserves for built-in plugins (it strips #{STRIPPED_NAMESPACE.source} from task module " \
          "names), so it would be renamed on dispatch and could collide; rename the plugin"
        )
      end

      if reserved_names.includes?(name)
        raise ConfigError.new(
          "external plugin name #{name.inspect} in #{File.dirname(path)} shadows a module krikri " \
          "already implements (or an alias of one), so the task would run that module and never " \
          "this plugin; rename the plugin"
        )
      end

      true
    end
  end
end
