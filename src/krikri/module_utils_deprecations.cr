require "json"
require "./collection_index"

module Krikri
  # The deprecated `ansible.module_utils` imports real ansible-core 2.21 warns
  # about the moment a module payload (or a controller-side action plugin)
  # imports one, and which modules of this engine reach without python.
  #
  # ansible-core 2.21 turned `ansible.module_utils._text` into a shim whose
  # module-level __getattr__ deprecates every name imported from it - one
  # deprecation per name, in the importing module's own order - and
  # `ansible.module_utils.common._collections_compat` deprecates itself on
  # import. Collection releases still import from both paths, so real prints
  # a [DEPRECATION WARNING] (each distinct line once per run, behind the
  # one-time "can be disabled" hint) wherever that import happens, and its
  # registered result carries a matching `deprecations` entry per imported
  # name. krikri implements several of those modules natively, with no python
  # payload at all, so no import ever happens and real's lines went missing
  # (issue #1000: alecunsolo.cockpit's synchronize task lost the whole
  # trailer block).
  #
  # Which names those are is decided by the resolved collection release and
  # the INSTALLED payload it carries: the import travels with the
  # collection, and collections migrate it away over time (ansible.posix
  # 2.2.0 moved every catalogued module - and the synchronize action plugin -
  # onto `ansible.module_utils.common.text.converters` and `collections.abc`,
  # so a controller resolving the 2.2.x line has NO import deprecations at
  # all and this code must print nothing either - issues #1060 and #1061,
  # where krikri printed the 2.1.x pair against a 2.2.x tree: mount.py:228 in
  # 2.2.2 migrated the import that mount.py:229's `import to_bytes, to_native`
  # still spells in 2.1.0). The methods therefore take the resolved release's
  # version (CollectionIndex.module_provider_version, pinned on the plugin
  # wire) and model nothing for the 2.2.x-or-newer line; an unknown version
  # models, the conservative default the engine hardcoded before the resolved
  # release became visible. Inside that gate the installed module/action
  # source decides exactly which names warn (CollectionIndex knows where
  # real's loader would find it) - including names no table below catalogues,
  # like community.libvirt's virt_net.py:142 to_native import - and the
  # tables model one 2.1.x release's payload only for controllers that ship
  # no such file at all, krikri-only hosts where real cannot run the module
  # either. Live-verified against ansible-core 2.21.6 plus both ansible.posix
  # lines' module sources.
  module ModuleUtilsDeprecations
    # The `_text` imports of the module payloads this engine runs without
    # python, for controllers with no installed collection file to read
    # (see the intro). Keyed by the bare trailing segment because real
    # reaches the same module through its own FQCN and through
    # ansible.builtin's legacy redirect, and every spelling warns.
    # `patch` is deliberately absent: krikri has no patch plugin, so a
    # patch task never runs a module here.
    TEXT_IMPORT_DEPRECATIONS = {
      "acl"            => ["to_native"],
      "authorized_key" => ["to_native"],
      "firewalld_info" => ["to_native"],
      "mount"          => ["to_bytes", "to_native"],
      "seboolean"      => ["to_text"],
      "synchronize"    => ["to_bytes", "to_native"],
      "sysctl"         => ["to_native"],
    }

    # ansible.posix's synchronize ACTION plugin imports to_text from the
    # deprecated `_text` path and MutableSequence from the deprecated
    # `_collections_compat` one (plugins/action/synchronize.py:25-26 in
    # 2.1.x), so real prints both lines when it loads that plugin on the
    # controller. Real loads action plugins lazily, immediately before the
    # task's own banner - a `when:` false synchronize still warns there,
    # live-verified against 2.21.6 - and, unlike the module payload's
    # imports, these leave NO entry on the registered result (a synchronize
    # result registers only the module's to_bytes/to_native pair). The
    # fallback for controllers with no installed collection file, keyed by
    # the bare trailing segment for the same reason as the module table
    # above; 2.2.x's action plugin migrated both imports (to
    # collections.abc and common.text.converters) and warns nothing.
    ACTION_PLUGIN_TEXT_IMPORT_DEPRECATIONS = {
      "synchronize" => ["to_text"],
    }

    # `_collections_compat` deprecates the MODULE rather than one imported
    # name (ansible/module_utils/common/_collections_compat.py's own
    # module-level deprecate() call), so its line has no "Importing ..." stem.
    COLLECTIONS_COMPAT_DEPRECATION_TEXT = "The `ansible.module_utils.common._collections_compat` module is deprecated. " \
                                          "This feature will be removed from ansible-core version 2.24. " \
                                          "Use `collections.abc` from the Python standard library instead."

    # The `_text` symbols one module imports, in the module's own import
    # order; empty for every name outside the installed payload and the
    # fallback table alike - and for every name when `collection_version`
    # pins a 2.2.x-or-newer release (see the header).
    def self.text_import_deprecation_symbols(name : String?, collection_version : String? = nil) : Array(String)
      return [] of String unless name
      return [] of String unless deprecated_text_imports?(collection_version)
      if events = installed_payload_events(name)
        return events.select { |kind, _| kind == "text" }.map { |_, symbol| symbol }
      end
      TEXT_IMPORT_DEPRECATIONS[name.split(".").last?]? || [] of String
    end

    # The console text real prints for one imported symbol: the deprecation's
    # own message, Display's removal-version tail, and the `_text.py` shim's
    # help text joined onto one line (the help text is a separate `_messages`
    # field that only the console line merges in - see
    # text_import_deprecation_result_entries).
    def self.text_import_deprecation_texts(name : String?, collection_version : String? = nil) : Array(String)
      text_import_deprecation_symbols(name, collection_version).map { |symbol| text_import_deprecation_text(symbol) }
    end

    # The `deprecations` entries those imports leave on the module result
    # (live-verified vs ansible-core 2.21.6 through `register`: the deprecator
    # resolves to ansible.builtin - `_text` is ansible-core's own
    # module_utils, not the importing module's collection - and the msg
    # carries no removal tail; only the console line does).
    def self.text_import_deprecation_result_entries(name : String?, collection_version : String? = nil) : Array(JSON::Any)
      text_import_deprecation_symbols(name, collection_version).map do |symbol|
        deprecation_result_entry("Importing '#{symbol}' from 'ansible.module_utils._text' is deprecated.")
      end
    end

    # The console texts real prints when it loads one controller-side action
    # plugin: its `_text` imports in order, then the `_collections_compat`
    # module deprecation when it imports that too (the scanner preserves the
    # two kinds' relative order, which synchronize's own import order
    # establishes). The action plugin real loads for a name ships beside the
    # module payload in the same collection; a collection whose install
    # carries no plugins/action/<leaf>.py loads no action plugin at all, so
    # nothing warns. Empty for every action plugin krikri implements without
    # one - and for every name when `collection_version` pins a
    # 2.2.x-or-newer release (see the header).
    def self.action_plugin_text_import_deprecation_texts(name : String?, collection_version : String? = nil) : Array(String)
      return [] of String unless name
      return [] of String unless deprecated_text_imports?(collection_version)
      if events = installed_action_events(name)
        return events.map do |kind, symbol|
          kind == "text" ? text_import_deprecation_text(symbol) : COLLECTIONS_COMPAT_DEPRECATION_TEXT
        end
      end
      symbols = ACTION_PLUGIN_TEXT_IMPORT_DEPRECATIONS[name.split(".").last?]? || return [] of String
      texts = symbols.map { |symbol| text_import_deprecation_text(symbol) }
      # The one catalogued action plugin imports _collections_compat beside
      # _text (synchronize.py:26), in that order.
      texts + [COLLECTIONS_COMPAT_DEPRECATION_TEXT]
    end

    # Whether the resolved release can still carry the deprecated imports
    # this code models: ansible.posix 2.2.x carries none (see the
    # header), so only the 2.1.x line - and an unpinned one - models them.
    private def self.deprecated_text_imports?(collection_version : String?) : Bool
      CollectionIndex.version_before?(collection_version, 2, 2, 0)
    end

    # One registered `deprecations` entry as ansible-core 2.21's
    # _return_formatted dumps it: msg first, no removal tail, the
    # ansible.builtin deprecator, version 2.24.
    def self.deprecation_result_entry(msg : String, version : String = "2.24") : JSON::Any
      JSON.parse({
        "msg"             => msg,
        "collection_name" => "ansible.builtin",
        "version"         => version,
        "deprecator"      => {
          "resolved_name" => "ansible.builtin",
          "type"          => nil,
        },
      }.to_json)
    end

    # The console line for one imported `_text` symbol.
    private def self.text_import_deprecation_text(symbol : String) : String
      "Importing '#{symbol}' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead."
    end

    # The deprecated imports of the module payload real would run for
    # `name`, nil when no installed collection payload answers (the
    # modeled table's case). Reproducing these lines is cosmetic metadata
    # riding a result, so any lookup failure degrades to nil rather than
    # surfacing: a plugin process whose own starting directory was
    # deleted out from under it (the command plugin's chdir: case) must
    # never crash over it, and Crystal's Dir.glob raises on a gone cwd.
    private def self.installed_payload_events(name : String) : Array(Tuple(String, String))?
      module_path = CollectionIndex.module_source_file(name)
      return nil unless module_path
      deprecated_import_events(File.read(module_path))
    rescue
      nil
    end

    # The same for the controller-side action plugin real loads for
    # `name`: [] when the installed collection ships no plugins/action
    # file beside the module (real then loads no action plugin and
    # nothing warns), nil when no installed collection payload answers at
    # all.
    private def self.installed_action_events(name : String) : Array(Tuple(String, String))?
      module_path = CollectionIndex.module_source_file(name)
      return nil unless module_path
      action = File.join(File.dirname(File.dirname(module_path)), "action", File.basename(module_path))
      return [] of Tuple(String, String) unless File.file?(action)
      deprecated_import_events(File.read(action))
    rescue
      nil
    end

    # The deprecated module_utils import events one payload source holds, in
    # source order: {"text", symbol} per name imported from
    # `ansible.module_utils._text`, {"compat", ""} per `_collections_compat`
    # import. Only names the real shim can serve are counted - its
    # __getattr__ raises AttributeError for anything else BEFORE deprecating,
    # so real prints no line for them either. A bare
    # `import ansible.module_utils._text` is not an event (no attribute is
    # accessed at import, so nothing deprecates), while a bare
    # `import ... _collections_compat` is one (the module deprecates itself
    # on import).
    private def self.deprecated_import_events(source : String) : Array(Tuple(String, String))
      deprecatable = {"codecs", "to_bytes", "to_text", "to_native", "binary_type", "text_type", "PY3"}
      events = [] of Tuple(String, String)
      lines = source.lines
      index = 0
      while index < lines.size
        line = lines[index]
        index += 1
        if line =~ /^\s*import\s+ansible\.module_utils\.common\._collections_compat\b/ ||
           line =~ /^\s*from\s+ansible\.module_utils\.common\._collections_compat\s+import\b/
          events << {"compat", ""}
          next
        end
        match = /^\s*from\s+ansible\.module_utils\._text\s+import\s+(.+)$/.match(line)
        next unless match
        # Parenthesized and backslash-continued imports span lines; read
        # until the statement closes (comment-free - a '#' inside the
        # clause is a comment in an import statement).
        clause = match[1].split('#', 2).first
        while index < lines.size &&
              (clause.count('(') > clause.count(')') || clause.rstrip.ends_with?('\\'))
          clause += " " + lines[index].split('#', 2).first
          index += 1
        end
        clause.split(',').each do |piece|
          if md = piece.match(/\b[A-Za-z_][A-Za-z0-9_]*/)
            symbol = md[0]
            events << {"text", symbol} if deprecatable.includes?(symbol)
          end
        end
      end
      events
    end
  end
end
