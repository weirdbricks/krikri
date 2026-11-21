require "big"
require "./ansible_install"
require "./throttle_value"

module Krikri
  # Reader for ansible.cfg (the INI config ansible-playbook loads at
  # startup).
  #
  # WHY: each setting below is one ansible.cfg krikri silently ignored, so
  # a run used different data whenever a project kept it in the file
  # instead of an env var (issue #1478): `[defaults] inventory` was ignored
  # so `hosts: all` matched nothing, `roles_path`/`library` turned installed
  # roles and custom modules into "not found", and `remote_user`/`ssh_args`
  # dialed ssh as the local user over the default transport.
  # `deprecation_warnings` is the one whose absence changed only the
  # output: a project could not silence the deprecation blocks ansible's own
  # "can be disabled" hint names (issue #1660). The rest of the file stays
  # unread (KNOWN_MISSING.md's deliberate limit).
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

    # DEPRECATION_WARNINGS: [defaults] deprecation_warnings /
    # ANSIBLE_DEPRECATION_WARNINGS - the setting ansible-playbook's own
    # "Deprecation warnings can be disabled by setting
    # `deprecation_warnings=False` in ansible.cfg" hint names. krikri
    # printed every deprecation unconditionally, so a project that had
    # turned them off still saw them (issue #1660).
    #
    # The env var is consulted whenever it is PRESENT, empty included: only
    # an unset variable falls through to the ini, and the `boolean` coercion
    # is non-strict, so `ANSIBLE_DEPRECATION_WARNINGS=` and
    # `deprecation_warnings = nope` both disable the warnings instead of
    # erroring (live-verified vs 2.21.6).
    def self.deprecation_warnings_enabled? : Bool
      if from_env = ENV["ANSIBLE_DEPRECATION_WARNINGS"]?
        return boolean(from_env)
      end
      if from_ini = get("defaults", "deprecation_warnings")
        return boolean(from_ini)
      end
      true
    end

    # ansible's module_utils.parsing.convert_bool.boolean(strict=False):
    # its true set only, everything else False.
    def self.boolean(raw : String) : Bool
      %w(y yes on 1 true t).includes?(raw.strip.downcase)
    end

    # ssh.py's host_key_checking connection option, ini layer: its two
    # entries are [defaults] and [ssh_connection] `host_key_checking`, and
    # ConfigManager._loop_entries keeps the LAST listed entry found, so an
    # [ssh_connection] value outranks [defaults] when both are present.
    # nil = unset in both - the option's own True default then applies.
    # Consumed by SSHManager's StrictHostKeyChecking resolution, below
    # ANSIBLE_SSH_HOST_KEY_CHECKING/ANSIBLE_HOST_KEY_CHECKING and the
    # per-host variables (issue #1682).
    def self.host_key_checking : Bool?
      raw = get("ssh_connection", "host_key_checking") ||
            get("defaults", "host_key_checking")
      raw ? boolean(raw) : nil
    end

    # DEFAULT_FORKS: ANSIBLE_FORKS (`integer`) or [defaults] forks.
    # ansible-core's constants.py resolves this setting while it is being
    # IMPORTED, which makes it the one config value that stops
    # ansible-playbook before it has even parsed its own arguments
    # (`--version` dies on a bad one too, live-verified vs 2.21.6). krikri
    # used to neither read nor check it, so a run under
    # ANSIBLE_FORKS=kpg-many played the whole playbook where real printed
    # nothing and exited 5 (issue #1501, through the generator's
    # play-keyword axis).
    #
    # nil means absent or empty: ansible treats an empty env value as
    # unset and falls back to the built-in 5 (an empty variable still
    # outranks the ini, so the ini is not consulted for it either).
    def self.forks_setting : Int32?
      raw, _origin = forks_setting_source
      raw ? python_integer(raw) : nil
    end

    # The DEFAULT_FORKS text ansible's `integer` coercion refuses together
    # with the origin ansible blames for it - `env: ANSIBLE_FORKS`, or the
    # config file's own path - or nil when there is nothing to complain
    # about. The caller renders ansible's import-time crash from it.
    def self.invalid_forks_setting : {String, String}?
      raw, origin = forks_setting_source
      return nil unless raw
      python_integer(raw) ? nil : {raw, origin}
    end

    private def self.forks_setting_source : {String?, String}
      if env_value = ENV["ANSIBLE_FORKS"]?
        return {nil, "env: ANSIBLE_FORKS"} if env_value.empty?
        return {env_value, "env: ANSIBLE_FORKS"}
      end
      if from_ini = get("defaults", "forks")
        if file = path
          return {from_ini, file}
        end
      end
      {nil, "default"}
    end

    # ensure_type's `integer` branch: ansible parses the value with
    # Python's decimal.Decimal and accepts it only when that equals its
    # own integer part, so `5`, `5.0`, `1e2` and `+3` are fork counts
    # while `3.5` is not - and `0x10` is not either, because Decimal's
    # grammar is not int()'s literal grammar. Decimal allows surrounding
    # whitespace and underscores between digits.
    #
    # The result is clamped: a count this engine could never schedule
    # (or a zero/negative one, which would stall its channel gate) still
    # has to be accepted or refused the way real ansible does, so only
    # the effective fan-out is bounded here.
    private def self.python_integer(raw : String) : Int32?
      body = raw.strip
      return nil if body.empty?
      return nil unless body.matches?(/\A[+-]?(?:\d(?:_?\d)*(?:\.(?:\d(?:_?\d)*)?)?|\.\d(?:_?\d)*)(?:[eE][+-]?\d(?:_?\d)*)?\z/)
      number = BigDecimal.new(body.delete('_'))
      integral = number.to_big_i
      return nil unless number == BigDecimal.new(integral)
      return 1 if integral < 1
      return Int32::MAX if integral > Int32::MAX
      integral.to_i
    rescue InvalidBigDecimalException
      nil
    end

    # The stderr block real ansible-playbook prints for a refused
    # DEFAULT_FORKS: cli/__init__.py imports constants, the settings'
    # import-time integer coercion raises, its catch-all prints
    # "ERROR: <message>" plus traceback.format_exception(ex) - both
    # chained tracebacks, PEP 657 anchors included - on STDERR, and exits
    # 5 with no stdout at all (live-verified vs 2.21.6). The install path
    # and the anchor lines belong to the Python that would run ansible on
    # THIS host (see AnsibleInstall), not to the kpg podman image they
    # were first captured from: the generator's Ubuntu 24.04 microVM
    # reference hosts run Python 3.12, which names python3.12 and still
    # underlines every call frame where 3.13 prints either no anchor or a
    # split one (issue #1620).
    def self.invalid_forks_crash_render(raw : String, origin : String) : String
      pkg = AnsibleInstall.package_path
      event = "Config 'DEFAULT_FORKS' from #{ThrottleValue.python_repr(origin)} has an invalid value: " \
              "Invalid value provided for 'integer': #{ThrottleValue.python_repr(raw)}"
      ensure_type_source = "value = ensure_type(value, defs[config].get('type'), origin=origin, origin_ftype=origin_ftype)"
      ensure_type_call = "ensure_type(value, defs[config].get('type'), origin=origin, origin_ftype=origin_ftype)"
      get_config_value_source = "value, _drop = self.get_config_value_and_origin(config, cfile=cfile, plugin_type=plugin_type, plugin_name=plugin_name,"
      String.build do |io|
        io << "ERROR: " << event << "\n\n"
        io << "Traceback (most recent call last):\n"
        io << forks_trace_frame(pkg, "config/manager.py", 697, "get_config_value_and_origin",
          ensure_type_source, ensure_type_call)
        io << forks_trace_frame(pkg, "config/manager.py", 111, "ensure_type",
          "value = _ensure_type(value, value_type, origin)", "_ensure_type(value, value_type, origin)")
        io << forks_trace_frame(pkg, "config/manager.py", 225, "_ensure_type",
          "raise ValueError(f'Invalid value provided for {value_type!r}: {original_value!r}')")
        io << "ValueError: Invalid value provided for 'integer': " << ThrottleValue.python_repr(raw) << "\n\n"
        io << "The above exception was the direct cause of the following exception:\n\n"
        io << "Traceback (most recent call last):\n"
        io << forks_trace_frame(pkg, "cli/__init__.py", 93, "<module>", "from ansible import constants as C")
        io << forks_trace_frame(pkg, "constants.py", 186, "<module>",
          "set_constant(setting, config.get_config_value(setting, variables=vars()))",
          "config.get_config_value(setting, variables=vars())", "config.get_config_value")
        io << forks_trace_frame(pkg, "config/manager.py", 559, "get_config_value", get_config_value_source,
          "self.get_config_value_and_origin(config, cfile=cfile, plugin_type=plugin_type, plugin_name=plugin_name,",
          "self.get_config_value_and_origin")
        unless AnsibleInstall.caret_lines?
          # 3.13 prints a multi-line statement whole, with its own anchor
          # line under the continuation.
          io << " " * 52 << "keys=keys, variables=variables, direct=direct, templar=templar)\n"
          io << " " * 52 << "^" * 63 << "\n"
        end
        io << forks_trace_frame(pkg, "config/manager.py", 704, "get_config_value_and_origin",
          "raise AnsibleOptionsError(f'Config {_get_config_label(plugin_type, plugin_name, config)} from {origin!r} has an invalid value.') from ex")
        io << "ansible.errors.AnsibleOptionsError: " << event << "\n\n"
      end
    end

    # One frame of a counterfeited traceback: the `File "..."` line, its
    # source line, and the anchor line the host's Python prints under it.
    # *expression* is the part of *source* the failing instruction covers
    # and *callee* is its leading call target, which 3.13 marks with `~`
    # while 3.11/3.12 underline the whole expression; a frame whose
    # position is its whole statement (a raise, an import) passes neither,
    # because no version marks those.
    private def self.forks_trace_frame(pkg : String, rel : String, line : Int32, fn : String,
                                       source : String, expression : String? = nil,
                                       callee : String? = nil) : String
      frame = "  File \"#{pkg}/#{rel}\", line #{line}, in #{fn}\n    #{source}\n"
      return frame unless expression
      offset = source.index(expression) || return frame
      marks = if AnsibleInstall.caret_lines?
                "^" * expression.size
              elsif callee
                "~" * callee.size + "^" * (expression.size - callee.size)
              else
                return frame
              end
      frame + " " * (4 + offset) + marks + "\n"
    end
  end
end
