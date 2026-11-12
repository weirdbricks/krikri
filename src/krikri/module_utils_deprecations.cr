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
      "acl"              => ["to_native"],
      "authorized_key"   => ["to_native"],
      "firewalld_info"   => ["to_native"],
      "mount"            => ["to_bytes", "to_native"],
      "podman_container" => ["to_bytes", "to_native"],
      "seboolean"        => ["to_text"],
      "synchronize"      => ["to_bytes", "to_native"],
      "sysctl"           => ["to_native"],
    }

    # Fallback-table modules whose collection moved the deprecated
    # imports out at a boundary other than ansible.posix's 2.2.0 one,
    # mapped to the FIRST release that no longer carries them
    # (source-verified against the tagged releases: containers.podman's
    # podman_container_lib.py opens with the `_text` pair through 1.18.2
    # and imports common.text.converters from 1.19.0 on - issue #1156).
    # The 2.2.0 gate alone would model the pair for every 1.x release
    # forever, including the ones real is silent on.
    LATER_MIGRATION_BOUNDARIES = {
      "podman_container" => {1, 19, 0},
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
    # pins a release that no longer makes those imports (the 2.2.0 gate
    # below, tightened per module by LATER_MIGRATION_BOUNDARIES).
    def self.text_import_deprecation_symbols(name : String?, collection_version : String? = nil) : Array(String)
      return [] of String unless name
      return [] of String unless deprecated_text_imports?(name, collection_version)
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
      return [] of String unless deprecated_text_imports?(name, collection_version)
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
    # this code models for `name`: ansible.posix 2.2.x carries none (see
    # the header), so only its 2.1.x line - and an unpinned one - models
    # them, and a module with its own LATER_MIGRATION_BOUNDARIES entry
    # stops at its own boundary instead (containers.podman 1.19.0).
    private def self.deprecated_text_imports?(name : String, collection_version : String?) : Bool
      return false unless CollectionIndex.version_before?(collection_version, 2, 2, 0)
      if boundary = LATER_MIGRATION_BOUNDARIES[name.split(".").last?]?
        return CollectionIndex.version_before?(collection_version, boundary[0], boundary[1], boundary[2])
      end
      true
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
    # modeled table's case). Real executes the payload's whole IMPORT
    # CHAIN, not just the module file - containers.podman's
    # podman_container carries no `_text` import of its own; its
    # module_utils/podman/podman_container_lib.py opens with the
    # to_bytes/to_native pair and the shim deprecates when THAT import
    # runs - so the scan follows the payload's collection-internal
    # module_utils imports too (see payload_import_events). Reproducing
    # these lines is cosmetic metadata riding a result, so any lookup
    # failure degrades to nil rather than surfacing: a plugin process
    # whose own starting directory was deleted out from under it (the
    # command plugin's chdir: case) must never crash over it, and
    # Crystal's Dir.glob raises on a gone cwd.
    private def self.installed_payload_events(name : String) : Array(Tuple(String, String))?
      module_path = CollectionIndex.module_source_file(name)
      return nil unless module_path
      payload_import_events(module_path, Set(String).new)
    rescue
      nil
    end

    # The deprecated import events of one payload file and the
    # collection-internal module_utils files it imports, in real's
    # import-execution order: each file's own deprecated imports at
    # their statement position, each `from`-import of a same-collection
    # module_utils file recursing AT that statement (an earlier
    # statement's imports precede a later one's). Core
    # `ansible.module_utils` imports are deliberately not followed -
    # ansible-core's own tree is the clean side of the two deprecated
    # paths. Each file executes once per process, so the visited set
    # also breaks cycles; a failure anywhere degrades to no events at
    # all (the caller's rescue, like the module-file read before it).
    private def self.payload_import_events(module_path : String, visited : Set(String)) : Array(Tuple(String, String))
      return [] of Tuple(String, String) unless visited.add?(module_path)
      events = [] of Tuple(String, String)
      lines = File.read(module_path).lines
      index = 0
      while index < lines.size
        line = lines[index]
        index += 1
        if line =~ /^\s*import\s+ansible\.module_utils\.common\._collections_compat\b/ ||
           line =~ /^\s*from\s+ansible\.module_utils\.common\._collections_compat\s+import\b/
          events << {"compat", ""}
          next
        end
        if match = /^\s*from\s+ansible\.module_utils\._text\s+import\s+(.+)$/.match(line)
          clause_events, index = text_import_clause_events(match[1], lines, index)
          events += clause_events
          next
        end
        if target = collection_module_utils_import_target(line, module_path)
          events += payload_import_events(target, visited)
        end
      end
      events
    end

    # The `from ansible.module_utils._text import <names>` events for
    # one statement, shared by the module-file walk above and the
    # action-plugin scan: parenthesized and backslash-continued clauses
    # span lines (comment-free - a '#' inside the clause is a comment in
    # an import statement); returns the events and the line index past
    # the statement.
    private def self.text_import_clause_events(clause : String, lines : Array(String), index : Int32) : {Array(Tuple(String, String)), Int32}
      deprecatable = {"codecs", "to_bytes", "to_text", "to_native", "binary_type", "text_type", "PY3"}
      events = [] of Tuple(String, String)
      clause = clause.split('#', 2).first
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
      {events, index}
    end

    # The installed module_utils file one import statement pulls in from
    # the SAME collection, nil for anything else (core
    # ansible.module_utils imports, other collections, non-module_utils
    # collection code). Both spellings real's loader resolves against
    # the payload's own collection are followed: the relative
    # `from ..module_utils.podman.podman_container_lib import ...` and
    # the absolute `from ansible_collections.<ns>.<coll>.plugins.
    # module_utils.<rest> import ...` one.
    private def self.collection_module_utils_import_target(line : String, module_path : String) : String?
      payload_collection_root(module_path).try do |collection_dir|
        candidate = relative_import_target(line, module_path) ||
                    absolute_collection_import_target(line, collection_dir)
        next nil unless candidate
        # Only files that really sit in this collection's module_utils
        # tree answer: real resolves the import through the installed
        # collection, and anything outside it (or missing) warns nothing.
        next nil unless File.file?(candidate)
        next nil unless File.dirname(candidate).starts_with?(File.join(collection_dir, "plugins", "module_utils"))
        candidate
      end
    end

    # The ansible_collections/<ns>/<coll> directory a payload lives
    # under - module files and their module_utils sit at different
    # depths under it, so the prefix is located directly.
    private def self.payload_collection_root(module_path : String) : String?
      parts = module_path.split(File::SEPARATOR)
      coll_idx = (parts.rindex("ansible_collections") || return nil) + 2
      return nil unless coll_idx < parts.size
      File.join(parts[0..coll_idx])
    end

    # The file a RELATIVE module_utils import names, resolved against
    # the importing file's package: level 1 is the directory containing
    # it, each further dot one level up. A bare `from . import x` names
    # the package itself - module_utils packages carry no __init__.py
    # payload here, so nothing follows.
    private def self.relative_import_target(line : String, module_path : String) : String?
      md = line.match(/^\s*from\s+((?:\.)+)([\w.]*)\s+import\b/) || return nil
      return nil if md[2].empty? || md[2].ends_with?(".")
      dotted = md[2].split('.')
      base = File.dirname(module_path)
      (md[1].size - 1).times { base = File.dirname(base) }
      parent = dotted.size > 1 ? File.join(base, dotted[0..-2].join("/")) : base
      File.join(parent, "#{dotted.last}.py")
    end

    # The file an ABSOLUTE same-collection module_utils import names,
    # nil for imports that leave the payload's own collection (real
    # resolves those too, but only the same collection's module_utils
    # tree is followed here).
    private def self.absolute_collection_import_target(line : String, collection_dir : String) : String?
      md = line.match(/^\s*from\s+ansible_collections\.([\w.]+)\s+import\b/) ||
           line.match(/^\s*import\s+ansible_collections\.([\w.]+)\b/) || return nil
      collection_fq = "#{File.basename(File.dirname(collection_dir))}.#{File.basename(collection_dir)}"
      remainder = md[1].lchop?("#{collection_fq}.") || return nil
      return nil unless remainder.starts_with?("plugins.module_utils.")
      File.join(collection_dir, remainder.gsub('.', "/") + ".py")
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
        if match = /^\s*from\s+ansible\.module_utils\._text\s+import\s+(.+)$/.match(line)
          clause_events, index = text_import_clause_events(match[1], lines, index)
          events += clause_events
        end
      end
      events
    end
  end
end
