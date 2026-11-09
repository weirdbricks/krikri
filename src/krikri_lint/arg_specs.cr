require "json"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's args[module] rule (a warning
    # upstream) validates a task's module parameters against that
    # module's own AnsibleModule argument spec. The specs are
    # data/argspecs.json - the generated table the engine's own
    # ArgspecValidator runs at task-execution time (ground truth = the
    # installed ansible-core + collections, captured by
    # scripts/gen_argspecs.py) - so the linter and the engine agree on
    # every module krikri ships a plugin for, whatever spelling the task
    # wrote.
    module ArgSpecs
      extend self

      TABLE = JSON.parse({{ read_file("#{__DIR__}/../../data/argspecs.json") }}).as_h

      # community.libvirt.virt_net is registered only under its bare
      # name (module_registry.cr), which scripts/gen_argspecs.py skips
      # because it extracts dotted spellings only - so the generated
      # table has no key for it. Transcribed here from the module's own
      # AnsibleModule(...) call (the same capture the generator makes).
      VIRT_NET = JSON.parse(<<-JSON)
        {
          "options": {
            "name": {"aliases": ["network"]},
            "state": {"type": "str", "choices": ["active", "inactive", "present", "absent"]},
            "command": {"type": "str", "choices": ["create", "status", "start", "stop", "undefine", "destroy", "get_xml", "define", "modify", "list_nets", "facts", "info"]},
            "uri": {"type": "str", "default": "qemu:///system"},
            "xml": {"type": "str"},
            "autostart": {"type": "bool"}
          },
          "mutually_exclusive": [],
          "required_together": [],
          "required_one_of": [],
          "required_if": [
            ["command", "create", ["name"]],
            ["command", "status", ["name"]],
            ["command", "start", ["name"]],
            ["command", "stop", ["name"]],
            ["command", "undefine", ["name"]],
            ["command", "destroy", ["name"]],
            ["command", "get_xml", ["name"]],
            ["command", "define", ["name"]],
            ["command", "modify", ["name"]]
          ],
          "required_by": {}
        }
        JSON

      # Modules upstream's args rule never validates: its load_plugin
      # resolves the ACTION plugin first (whose file has no `main`, the
      # rule's own gate), or the module file is a doc-only stub with no
      # main of its own. Verified name by name against ansible-lint
      # 25.2.1 (each probe keeps a known-good canary match alive).
      # krikri's pseudo-modules (facts, py_module) land in the same
      # skip: upstream cannot resolve them at all.
      ACTION_ONLY = Set{
        "add_host", "assemble", "assert", "async_status", "command",
        "copy", "debug", "dnf", "facts", "fail", "fetch",
        "gather_facts", "group_by", "package", "pause", "py_module",
        "reboot", "script", "service", "set_fact", "set_stats", "shell",
        "template", "unarchive", "uri", "wait_for_connection", "yum",
        "synchronize",
      }

      # Modules whose mocked module run RAISES inside ansible-lint's
      # args rule ("Ignored exception from ArgsRule.matchtasks"), which
      # loses every args match for the WHOLE file - nothing may be
      # reported for a file containing one either. mount_facts' module
      # code raises "'NoneType' object has no attribute '__dict__'" in
      # the mocked context (verified with a canary probe).
      CRASHES = Set{"mount_facts"}

      # Same, but only for the bare spelling: bare `set_fact` resolves
      # to ansible's set_fact ACTION plugin, whose `from . import
      # VariableLayer` cannot load outside a package, while the FQCN
      # spelling resolves to the doc stub and skips quietly (verified
      # against the reference install's action plugins).
      BARE_CRASHES = Set{"set_fact"}

      # The table entry for a module name as a task wrote it: the exact
      # key, then the ansible.builtin/ansible.legacy spelling of a bare
      # name, then any registered spelling sharing the bare leaf (a bare
      # name in a `collections:` scope). entry's key is what the module
      # is registered under.
      def find(module_name : String) : {String, JSON::Any}?
        if entry = lookup(module_name)
          return {module_name, entry}
        end
        bare = module_name.split(".").last
        {"ansible.builtin.", "ansible.legacy."}.each do |prefix|
          key = prefix + bare
          if entry = lookup(key)
            return {key, entry}
          end
        end
        TABLE.each do |table_key, table_entry|
          return {table_key, table_entry} if table_key.split(".").last == bare
        end
        nil
      end

      # Whether upstream's args rule skips this name outright, or takes
      # the file's whole args output down with it.
      def skip?(module_name : String) : Bool
        leaf = module_name.split(".").last
        ACTION_ONLY.includes?(leaf) ||
          (BARE_CRASHES.includes?(leaf) && !module_name.includes?(".")) ||
          CRASHES.includes?(leaf)
      end

      def crash?(module_name : String) : Bool
        leaf = module_name.split(".").last
        CRASHES.includes?(leaf) ||
          (BARE_CRASHES.includes?(leaf) && !module_name.includes?("."))
      end

      private def lookup(key : String) : JSON::Any?
        return VIRT_NET if key == "virt_net" || key == "community.libvirt.virt_net"
        TABLE[key]?
      end

      # The options map in the module's own argument_spec DECLARATION
      # order - ansible-core's validation walks the spec dict in that
      # order, so the first failing option (not the JSON decode order)
      # decides which message comes out. Crystal's JSON object decode
      # preserves insertion order, which the generated table maintains.
      def options(entry : JSON::Any) : Array(Tuple(String, JSON::Any))
        (entry["options"]?.try(&.as_h?) || Hash(String, JSON::Any).new).to_a
      end

      # alias => canonical, for every alias the spec declares.
      def alias_map(options : Array(Tuple(String, JSON::Any))) : Hash(String, String)
        map = Hash(String, String).new
        options.each do |name, spec|
          if list = spec["aliases"]?.try(&.as_a?)
            list.each do |alias_node|
              map[alias_node.as_s] = name
            end
          end
        end
        map
      end

      # The option's declared type; ansible's implicit default is str.
      def wanted_type(spec : JSON::Any) : String
        spec["type"]?.try(&.as_s?) || "str"
      end

      def default_of(spec : JSON::Any) : JSON::Any?
        spec["default"]?
      end

      # Non-null defaults, as _set_defaults' first pass materializes
      # them before the required/type/value checks.
      def defaults(options : Array(Tuple(String, JSON::Any))) : Hash(String, JSON::Any)
        map = Hash(String, JSON::Any).new
        options.each do |name, spec|
          if value = spec["default"]?
            map[name] = value unless value.raw.nil?
          end
        end
        map
      end

      # Python "%s"-style rendering of a spec default / required_if
      # trigger value (booleans print True/False, null prints None).
      def literal(value : JSON::Any) : String
        case raw = value.raw
        when Bool   then raw ? "True" : "False"
        when Nil    then "None"
        when String then raw
        else             value.to_s
        end
      end

      # The message rendering of a choices list: declaration order,
      # Python str() of each member (bools as True/False).
      def choice_strings(choices : Array(JSON::Any)) : Array(String)
        choices.map { |choice| literal(choice) }
      end
    end
  end
end
