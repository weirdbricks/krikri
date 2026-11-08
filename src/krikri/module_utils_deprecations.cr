require "json"

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
  # trailer block). Live-verified against ansible-core 2.21.6 plus the
  # installed ansible.posix module sources, whose import lines these are -
  # acl.py:150, authorized_key.py:230, firewalld_info.py:213 and sysctl.py:108
  # import to_native; mount.py:229 and synchronize.py:371 import to_bytes then
  # to_native; seboolean.py:76 imports to_text.
  #
  # Keyed by the bare trailing segment because real reaches the same module
  # through its own FQCN and through ansible.builtin's legacy redirect, and
  # every spelling warns. `patch` is deliberately absent: krikri has no patch
  # plugin, so a patch task never runs a module here.
  module ModuleUtilsDeprecations
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
    # `_collections_compat` one (plugins/action/synchronize.py:25-26), so real
    # prints both lines when it loads that plugin on the controller. Real
    # loads action plugins lazily, immediately before the task's own banner -
    # a `when: false` synchronize still warns there, live-verified against
    # 2.21.6 - and, unlike the module payload's imports, these leave NO entry
    # on the registered result (a synchronize result registers only the
    # module's to_bytes/to_native pair). Keyed by the bare trailing segment
    # for the same reason as the module table above.
    ACTION_PLUGIN_TEXT_IMPORT_DEPRECATIONS = {
      "synchronize" => ["to_text"],
    }

    # `_collections_compat` deprecates the MODULE rather than one imported
    # name (ansible/module_utils/common/_collections_compat.py's own
    # module-level deprecate() call), so its line has no "Importing ..." stem.
    COLLECTIONS_COMPAT_DEPRECATION_TEXT = "The `ansible.module_utils.common._collections_compat` module is deprecated. " \
                                          "This feature will be removed from ansible-core version 2.24. " \
                                          "Use `collections.abc` from the Python standard library instead."

    # The `_text` symbols one module imports, in the module's own import order;
    # empty for every name outside the table above.
    def self.text_import_deprecation_symbols(name : String?) : Array(String)
      return [] of String unless name
      TEXT_IMPORT_DEPRECATIONS[name.split(".").last?]? || [] of String
    end

    # The console text real prints for one imported symbol: the deprecation's
    # own message, Display's removal-version tail, and the `_text.py` shim's
    # help text joined onto one line (the help text is a separate `_messages`
    # field that only the console line merges in - see
    # text_import_deprecation_result_entries).
    def self.text_import_deprecation_texts(name : String?) : Array(String)
      text_import_deprecation_symbols(name).map do |symbol|
        "Importing '#{symbol}' from 'ansible.module_utils._text' is deprecated. " \
        "This feature will be removed from ansible-core version 2.24. " \
        "Use ansible.module_utils.common.text.converters instead."
      end
    end

    # The `deprecations` entries those imports leave on the module result
    # (live-verified vs ansible-core 2.21.6 through `register`: the deprecator
    # resolves to ansible.builtin - `_text` is ansible-core's own
    # module_utils, not the importing module's collection - and the msg
    # carries no removal tail; only the console line does).
    def self.text_import_deprecation_result_entries(name : String?) : Array(JSON::Any)
      text_import_deprecation_symbols(name).map do |symbol|
        deprecation_result_entry("Importing '#{symbol}' from 'ansible.module_utils._text' is deprecated.")
      end
    end

    # The console texts real prints when it loads one controller-side action
    # plugin: its `_text` imports in order, then the `_collections_compat`
    # module deprecation when it imports that too. Empty for every action
    # plugin krikri implements without one.
    def self.action_plugin_text_import_deprecation_texts(name : String?) : Array(String)
      return [] of String unless name
      symbols = ACTION_PLUGIN_TEXT_IMPORT_DEPRECATIONS[name.split(".").last?]? || return [] of String
      texts = symbols.map do |symbol|
        "Importing '#{symbol}' from 'ansible.module_utils._text' is deprecated. " \
        "This feature will be removed from ansible-core version 2.24. " \
        "Use ansible.module_utils.common.text.converters instead."
      end
      # The one catalogued action plugin imports _collections_compat beside
      # _text (synchronize.py:26), in that order.
      texts + [COLLECTIONS_COMPAT_DEPRECATION_TEXT]
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
  end
end
