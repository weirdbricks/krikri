module Krikri
  # Reader for ansible.cfg (the INI config ansible-playbook loads at
  # startup).
  #
  # WHY: every setting below has an ansible.cfg spelling and no
  # playbook-visible substitute, so krikri silently ran with different
  # data whenever a project kept it in the file instead of an env var
  # (issue #1478): `[defaults] inventory` was ignored so `hosts: all`
  # matched nothing, `roles_path`/`library` turned installed roles and
  # custom modules into "not found", and `remote_user`/`ssh_args` dialed
  # ssh as the local user over the default transport. The rest of the
  # file stays unread (KNOWN_MISSING.md's deliberate limit).
  #
  # Semantics mirror ansible-core 2.21's ConfigManager:
  #   - first readable file wins: $ANSIBLE_CONFIG, ./ansible.cfg,
  #     ~/.ansible.cfg, /etc/ansible/ansible.cfg;
  #   - an env var outranks the ini value, which outranks the default;
  #   - section and key names are case-insensitive;
  #   - a relative path in the ini resolves against the CONFIG FILE's
  #     directory (ensure_type's basedir is the cfile), while an
  #     env-sourced one resolves against the invocation directory;
  #   - `pathspec` settings split on ':' (roles_path, library),
  #     `pathlist` settings on ',' (inventory);
  #   - ONLY ';' starts an inline comment, and only after whitespace
  #     (ConfigManager passes inline_comment_prefixes=(';',)).
  module AnsibleConfig
    @@base_dir : String? = nil
    @@path : String? = nil
    @@path_computed = false
    @@values : Hash(String, String)? = nil

    # The directory ansible-playbook was started from. krikri-playbook
    # chdirs into the playbook's directory before running, but ansible
    # loads config (and resolves its relative paths) at startup, so the
    # caller records this first.
    def self.base_dir : String
      @@base_dir ||= Dir.current
    end

    def self.base_dir=(dir : String) : Nil
      @@base_dir = dir
      @@path_computed = false
      @@path = nil
      @@values = nil
    end

    def self.path : String?
      compute_path unless @@path_computed
      @@path
    end

    private def self.compute_path : Nil
      @@path_computed = true
      candidates = [] of String

      if from_env = ENV["ANSIBLE_CONFIG"]?
        unless from_env.empty?
          candidate = File.expand_path(from_env, base_dir)
          # ansible accepts a DIRECTORY here and reads ansible.cfg inside it.
          candidate = File.join(candidate, "ansible.cfg") if Dir.exists?(candidate)
          candidates << candidate
        end
      end

      candidates << File.join(base_dir, "ansible.cfg")
      if home = ENV["HOME"]?
        candidates << File.expand_path(".ansible.cfg", home)
      end
      candidates << "/etc/ansible/ansible.cfg"

      @@path = candidates.find { |candidate_path| File.file?(candidate_path) && File::Info.readable?(candidate_path) }
    end

    # One INI value, or nil when the section/key is absent.
    def self.get(section : String, key : String) : String?
      values["#{section.downcase}\0#{key.downcase}"]?
    end

    # The directory relative paths in the ini resolve against.
    private def self.ini_base_dir : String
      if file = path
        File.dirname(file)
      else
        base_dir
      end
    end

    private def self.values : Hash(String, String)
      if cached = @@values
        return cached
      end

      parsed = Hash(String, String).new
      if file = path
        parse_ini(file, parsed)
      end
      @@values = parsed
      parsed
    end

    # Python's configparser, which ansible configures with only ';' as an
    # inline comment prefix (ConfigManager) and default continuation rules.
    private def self.parse_ini(file : String, parsed : Hash(String, String)) : Nil
      section = ""
      last_key : String? = nil
      File.each_line(file) do |raw|
        line = raw.chomp
        stripped = line.strip

        # configparser continues an indented line onto the value above it.
        if !line.empty? && line[0].whitespace? && last_key
          parsed[last_key] += "\n#{stripped}"
          next
        end

        # Blank lines inside a continuation stay part of the value; at
        # the top level they just separate entries.
        if stripped.empty?
          last_key = nil
          next
        end
        next if comment_line?(stripped)

        if section_header?(stripped)
          section = section_name(stripped)
          last_key = nil
          next
        end

        entry = parse_entry(stripped)
        next unless entry
        key = "#{section}\0#{entry[0]}"
        parsed[key] = entry[1]
        last_key = key
      end
    end

    private def self.comment_line?(line : String) : Bool
      line.starts_with?('#') || line.starts_with?(';')
    end

    private def self.section_header?(line : String) : Bool
      line.starts_with?('[') && line.includes?(']')
    end

    private def self.section_name(line : String) : String
      close = line.index(']') || line.size
      line[1...close].strip.downcase
    end

    # "<key> = <value>" / "<key>: <value>", whichever separator comes
    # first (configparser accepts both), with the inline comment removed.
    private def self.parse_entry(line : String) : {String, String}?
      separator = [line.index('='), line.index(':')].compact.min?
      return nil unless separator

      key = line[0...separator].strip.downcase
      return nil if key.empty?

      value = line[(separator + 1)..].strip
      if comment = inline_comment_at(value)
        value = value[0...comment].strip
      end
      {key, value}
    end

    private def self.inline_comment_at(value : String) : Int32?
      value.each_char_with_index do |char, index|
        next unless char == ';'
        return index if index.zero? || value[index - 1].whitespace?
      end
      nil
    end

    private def self.unquote(value : String) : String
      if value.size >= 2
        first = value[0]
        last = value[-1]
        return value[1...-1] if (first == '"' && last == '"') || (first == '\'' && last == '\'')
      end
      value
    end

    # String settings come out of the ini exactly as written (minus
    # surrounding quotes), while path settings get unfrackpath's
    # treatment: `~` expansion, `{{CWD}}` substitution and resolution of a
    # relative path against *basedir* (unfrackpath(follow=False)).
    private def self.resolve_path(value : String, basedir : String) : String
      value = value.gsub("{{CWD}}", base_dir)
      # File.expand_path only expands ~ as the whole path, so do
      # os.path.expanduser's job for "~/..." here.
      if value == "~"
        value = ENV["HOME"]? || Path.home.to_s
      elsif value.starts_with?("~/")
        value = File.join(ENV["HOME"]? || Path.home.to_s, value[2..])
      end
      File.expand_path(value, basedir)
    end

    private def self.split_pathspec(value : String, basedir : String) : Array(String)
      value.split(':').map(&.strip).reject(&.empty?).map { |entry| resolve_path(entry, basedir) }
    end

    # [defaults] inventory / ANSIBLE_INVENTORY (`pathlist`). nil means
    # neither source names one, leaving krikri's own default in place.
    def self.inventory_sources : Array(String)?
      if from_env = ENV["ANSIBLE_INVENTORY"]?.presence
        return from_env.split(',').map(&.strip).reject(&.empty?).map { |entry| resolve_path(entry, base_dir) }
      end
      if from_ini = get("defaults", "inventory").presence
        return from_ini.split(',').map(&.strip).reject(&.empty?).map { |entry| resolve_path(entry, ini_base_dir) }
      end
      nil
    end

    # [defaults] roles_path / ANSIBLE_ROLES_PATH (`pathspec`). The env var
    # REPLACES ansible's built-in roles paths rather than extending them,
    # and the ini value does the same - so a non-nil result is exhaustive.
    def self.roles_paths : Array(String)?
      if from_env = ENV["ANSIBLE_ROLES_PATH"]?.presence
        return split_pathspec(from_env, base_dir)
      end
      if from_ini = get("defaults", "roles_path").presence
        return split_pathspec(from_ini, ini_base_dir)
      end
      nil
    end

    # [defaults] library / ANSIBLE_LIBRARY (`pathspec`) - ansible's
    # DEFAULT_MODULE_PATH. Like roles_path this replaces the default list.
    def self.library_paths : Array(String)?
      if from_env = ENV["ANSIBLE_LIBRARY"]?.presence
        return split_pathspec(from_env, base_dir)
      end
      if from_ini = get("defaults", "library").presence
        return split_pathspec(from_ini, ini_base_dir)
      end
      nil
    end

    # [defaults] remote_user / ANSIBLE_REMOTE_USER. Connection variables
    # and -u still outrank this; it replaces krikri's local-uid fallback.
    def self.remote_user : String?
      if from_env = ENV["ANSIBLE_REMOTE_USER"]?.presence
        return from_env
      end
      if from_ini = get("defaults", "remote_user").presence
        return unquote(from_ini)
      end
      nil
    end

    # [ssh_connection] ssh_args / ANSIBLE_SSH_ARGS. A string, split
    # shell-style by the ssh invocation site. ansible's own default
    # (`-C -o ControlMaster=auto -o ControlPersist=60s`) is not modelled:
    # krikri builds its ssh options itself, and this only ADDS args when
    # the project configured some.
    def self.ssh_args : String?
      if from_env = ENV["ANSIBLE_SSH_ARGS"]?.presence
        return from_env
      end
      if from_ini = get("ssh_connection", "ssh_args").presence
        return unquote(from_ini)
      end
      nil
    end
  end
end
