require "set"
require "yaml"
require "./collection_runtime_data"
require "./builtin_module_names_data"
require "./python_filter_runner"
require "./ansible_config"

# krikri's module-name reference data - and nothing else. Every answer here
# comes from krikri's OWN baked tables (collection_runtime_data.cr,
# builtin_module_names_data.cr), the role/playbook `library/` and
# `action_plugins/` files beside a playbook, or its natively ported plugin
# set. krikri never reads an installed ansible-core or collections tree to
# make a decision: its behavior is identical on a controller that has
# neither installed (see KNOWN_MISSING.md's "krikri never consults an
# installed ansible-core or collections tree").
#
# The tables are CAPTURED at dev time by scripts/gen_collection_runtime_data.py
# from a pinned ansible-core + collections environment (a collection's first
# copy in real's own search order, so the redirect chains, release versions
# and deprecation events match what real's loader would read there). This
# engine previously walked the controller's own installs for all of it,
# which made resolution, version gating and deprecation output depend on
# whatever happened to be installed.
#
# What is deliberately NOT here: anything about EXECUTING a python plugin.
# A role's or playbook's `library/*.py` module, a collection's python plugin
# and the `ansible.module_utils` imports those executed modules resolve are
# plugin execution, not reference data - they still come from the
# environment (see #roots, PythonModuleRunner).
module Krikri
  module CollectionIndex
    # Maximum redirect chain depth before giving up - no real chain comes
    # close; the cap only stops adversarial cycles.
    private MAX_REDIRECT_HOPS = 12

    # ansible-core's own MODULE_IGNORE_EXTS: the extensions its loader's
    # fuzzy module match skips, so an editor backup or a README beside a
    # module never counts as the module.
    MODULE_IGNORE_EXTS = %w[.pyc .pyo .swp .bak ~ .rpm .md .txt .rst .yaml .yml .ini]

    # What krikri's baked tables can say about a module name: true
    # (resolves), false (definitely unresolvable) or nil (undecidable - a
    # collection the capture kept no file tree for, a templated name).
    alias Resolution = {resolves: Bool?}

    # Collection roots: directories that CONTAIN an `ansible_collections/`
    # tree, in real's own search order. Kept ONLY for python plugin
    # execution: an executed module's `from ansible_collections.ns.coll...`
    # and `ansible.module_utils` imports are resolved from these (see
    # PythonModuleRunner#collection_search_roots). No name-resolution,
    # version or deprecation answer reads them.
    @@roots : Array(String)? = nil
    @@role_meta_collections = Hash(String, Array(String)).new

    # Test seam: forget the per-role memo (a spec can point at a scratch
    # role and re-read its meta/main.yml). The baked tables are constants,
    # so nothing else is cached state.
    def self.reset! : Nil
      @@role_meta_collections.clear
      @@roots = nil
    end

    def self.roots : Array(String)
      cached = @@roots
      return cached if cached

      roots = [] of String
      if configured = ENV["ANSIBLE_COLLECTIONS_PATH"]? || ENV["ANSIBLE_COLLECTIONS_PATHS"]?
        configured.split(':').each do |entry|
          next if entry.empty?
          candidate = entry.chomp('/')
          roots << candidate unless roots.includes?(candidate)
        end
      end
      if home = ENV["HOME"]?
        roots << File.join(home, ".ansible", "collections")
      end
      roots << "/usr/share/ansible/collections"

      # The python package directories, where a distro/pip ansible-core
      # install keeps its shipped ansible_collections tree. Only an
      # already-installed `ansible_collections` subtree is a root; the
      # python interpreter that `python3 -c "import sysconfig"` names is
      # covered by the glob below.
      package_bases.each do |base|
        candidate = File.join(base, "ansible_collections")
        roots << candidate if Dir.exists?(candidate)
      end

      roots = roots.uniq
      @@roots = roots
      roots
    end

    # Base directories that may contain an `ansible/` package. Globbed
    # rather than hardcoded so point releases (/usr/lib/python3.11 vs
    # python3.12) both match.
    private def self.package_bases : Array(String)
      bases = [] of String
      ["/usr/lib", "/usr/local/lib", "/opt"].each do |prefix|
        Dir.glob("#{prefix}/python3*").each do |pydir|
          ["dist-packages", "site-packages"].each do |leaf|
            candidate = File.join(pydir, leaf)
            bases << candidate if Dir.exists?(candidate)
          end
        end
      end
      if home = ENV["HOME"]?
        Dir.glob("#{home}/.local/lib/python3*/site-packages").each do |candidate|
          bases << candidate if Dir.exists?(candidate)
        end
      end
      bases.uniq
    rescue
      # Dir.glob raises when the process's own working directory vanished
      # (a plugin's `chdir:` case) - no roots is the honest answer.
      [] of String
    end

    # Is "ns.coll" a collection krikri's captured environment could see?
    # Stays true for collections krikri only keeps routing/version data on
    # (there are 90+ of them) - a name inside one resolves or not per that
    # data, never per what this controller has installed.
    def self.known_collection?(namespace : String, collection : String) : Bool
      CollectionRuntimeData.known_collections.includes?("#{namespace}.#{collection}")
    end

    def self.known_collection?(fq : String) : Bool
      CollectionRuntimeData.known_collections.includes?(fq)
    end

    # The captured release version of a collection ("ns.coll"), or nil when
    # the capture saw no MANIFEST.json for it (a raw git checkout carries
    # galaxy.yml instead) or never saw the collection at all.
    def self.collection_version(fq : String) : String?
      CollectionRuntimeData.collection(fq).try(&.version)
    end

    # The version of the collection release whose module source `name`
    # resolves to, following the same redirect chain real's loader walks
    # (bare `mount:` -> ansible.posix.mount through the builtin runtime
    # table, the FQCN spellings straight through), pinned from the captured
    # environment. nil when the name resolves to ansible-core itself, to a
    # role-private library/ module, or when the captured release carries no
    # version - callers keep their existing modeling then (see
    # version_before?'s unknown-version default).
    def self.module_provider_version(name : String) : String?
      if pinned = CollectionRuntimeData.module_versions[name]?
        return pinned[1].empty? ? nil : pinned[1]
      end
      module_provider_collection(name).try { |collection_fq| collection_version(collection_fq) }
    end

    # The collection whose module source `name` resolves to (its FQCN
    # `namespace.collection`), following the same redirect chain real's
    # loader walks. nil when the name resolves to ansible-core itself or to
    # a role-private library/ module.
    def self.module_provider_collection(name : String) : String?
      return nil if name.empty? || name.includes?("{{")
      if pinned = CollectionRuntimeData.module_versions[name]?
        return pinned[0]
      end
      resolved = module_redirect_chain(name)
      parts = resolved.split('.')
      if parts.size >= 3
        return nil if parts[0] == "ansible" && (parts[1] == "builtin" || parts[1] == "legacy")
        return "#{parts[0]}.#{parts[1]}"
      end
      # A bare name with no redirect entry is matched against every
      # captured collection's plugins/modules/ in FQCN order (real's loader
      # scans each of them; the captured data is sorted so the answer does
      # not depend on directory-listing order).
      CollectionRuntimeData.collections.each do |collection_fq, entry|
        paths = entry.paths || next
        return collection_fq if paths.includes?("plugins/modules/#{resolved}.py")
      end
      nil
    end

    # Whether `version` (a collection release's MANIFEST.json `version`)
    # predates major.minor.patch, comparing the numeric leading segments.
    # An unknown/unparseable version counts as predating: the callers model
    # the OLDER module line when they cannot pin the resolved release
    # (ansible-core's own modules, role-private library/ sources, releases
    # without a MANIFEST.json) - the same conservative default the engine
    # hardcoded before the resolved release became visible.
    def self.version_before?(version : String?, major : Int32, minor : Int32, patch : Int32 = 0) : Bool
      return true unless version
      numbers = version.split('.').map { |segment| segment.to_i? || 0 }
      got_major = numbers[0]? || 0
      got_minor = numbers[1]? || 0
      got_patch = numbers[2]? || 0
      return got_major < major if got_major != major
      return got_minor < minor if got_minor != minor
      got_patch < patch
    end

    # Could real's plugin loader resolve a BARE lookup plugin name
    # (`query('dig', ...)`)? Bare lookup (and filter) names are scanned
    # across EVERY collection in the captured environment, and the builtin
    # runtime's plugin_routing.lookup redirect table participates first
    # (`redis` -> community.general) - all baked, so the answer is the same
    # on a controller with no collections installed at all (issue #1508: a
    # bare `lookup('kpg_raise')` used to render the literal "undefined"
    # where real fails the task with "was not found").
    def self.bare_lookup_resolves?(name : String) : Bool?
      return nil if name.empty? || name.includes?(".")
      return true if Krikri.builtin_lookup_names.includes?(name)
      if redirects = baked_redirects("lookup")
        if target = redirects[name]?
          return true if lookup_chain_resolves?(target, Set(String).new)
        end
      end
      CollectionRuntimeData.lookup_providers.includes?(name)
    end

    # Follows a lookup routing target through collection redirect tables
    # (the captured environment's own plugin_routing.lookup chains): does
    # the chain land on a lookup plugin file?
    private def self.lookup_chain_resolves?(fqcn : String, seen : Set(String)) : Bool
      return false if seen.includes?(fqcn) || seen.size > MAX_REDIRECT_HOPS
      seen << fqcn
      parts = fqcn.split('.')
      return false if parts.size < 3
      leaf = parts[2..].join('.')
      if parts[0] == "ansible" && parts[1] == "builtin"
        return Krikri.builtin_lookup_names.includes?(leaf)
      end
      fq = "#{parts[0]}.#{parts[1]}"
      if paths = CollectionRuntimeData.collection(fq).try(&.paths)
        return true if paths.includes?("plugins/lookup/#{leaf}.py")
      end
      if target = CollectionRuntimeData.collection(fq).try(&.redirects["lookup"]?.try(&.[leaf]?))
        return lookup_chain_resolves?(target, seen)
      end
      false
    end

    # The ansible_builtin_runtime.yml redirect tables (bare name or FQCN key
    # -> redirect target), one per routing kind ("modules", "action" and
    # "lookup"). Baked from the pinned ansible-core release - the action
    # table is what makes bare `yum:` resolve (its module is gone from
    # ansible-core but the action routing redirects onto ansible.builtin.dnf,
    # and real runs it, live-verified vs 2.19.11).
    private def self.baked_redirects(kind : String) : Hash(String, String)
      modules, action, lookups = Krikri.builtin_runtime_redirects
      case kind
      when "modules" then modules
      when "action"  then action
      else                lookups
      end
    end

    # A bare module name's ansible_builtin_runtime.yml redirect target
    # ("modules" routing), when the builtin runtime carries one for it (bare
    # `docker_service:` -> community.general.docker_service) - the hop real's
    # loader takes a bare name through before any target collection's own
    # meta/runtime.yml (and its tombstones) is consulted. nil when the name
    # has no builtin-runtime redirect.
    def self.builtin_module_redirect(name : String) : String?
      baked_redirects("modules")[name]?
    end

    # The module name real's loader reports after chasing the FULL redirect
    # chain: ansible_builtin_runtime.yml hops (for a bare name or an
    # ansible.builtin./ansible.legacy. leaf) and then every target
    # collection's own plugin_routing.modules redirect from the captured
    # environment, until no entry matches (cycle-limited like real's own
    # chase). A name with no redirect entry comes back unchanged; a
    # collection the capture never saw ends the chain exactly where real's
    # loader would stop without that collection installed.
    #
    # The name real reports in the task-args finalization error is the chain
    # END, not the first hop (issue #800: 'hetzner.hcloud.ssh_key', not the
    # intermediate FQCN, live-verified vs 2.19.11 for both the bare and the
    # FQCN spelling).
    def self.module_redirect_chain(name : String) : String
      current = name
      seen = Set{name}
      while seen.size <= MAX_REDIRECT_HOPS
        target = redirect_target(current) || break
        break if seen.includes?(target)
        seen << target
        current = target
      end
      current
    end

    # One hop of the chain for `current`: the redirect entry that matches
    # it, or nil at the chain end (no entry anywhere). Mirrors the split
    # real's loader makes: a bare name and an ansible.builtin./
    # ansible.legacy. leaf hop through ansible_builtin_runtime.yml, a
    # collection FQCN's leaf through the collection's own runtime.yml.
    private def self.redirect_target(current : String) : String?
      parts = current.split('.')
      if parts.size == 1
        builtin_module_redirect(current)
      elsif parts[0] == "ansible" && (parts[1] == "builtin" || parts[1] == "legacy")
        leaf = parts[2..].join('.')
        leaf.empty? ? nil : builtin_module_redirect(leaf)
      else
        leaf = parts[2..].join('.')
        return nil if leaf.empty?
        CollectionRuntimeData.collection("#{parts[0]}.#{parts[1]}")
          .try(&.redirects["modules"]?.try(&.[leaf]?))
      end
    end

    # Is `<leaf>` an ansible-core builtin module? The baked ansible-core
    # name set is the modules/ files plus every ansible_builtin_runtime.yml
    # redirect key - but a redirect key is not a module FILE: real resolves
    # such a bare name through the redirect chain (bare `gc_storage:` ->
    # community.google.gc_storage), so the redirect keys are subtracted
    # again here and those names take the chain instead.
    def self.builtin_module?(leaf : String) : Bool
      Krikri.builtin_module_names.includes?(leaf) &&
        !baked_redirects("modules").has_key?(leaf) &&
        !baked_redirects("action").has_key?(leaf)
    end

    # Does ansible-core itself ship an action plugin named `<leaf>`?
    def self.builtin_action_plugin?(leaf : String) : Bool
      CollectionRuntimeData.action_plugins.fetch("ansible.builtin", nil).try(&.has_key?(leaf)) || false
    end

    # Whether real's plugin loader would find an ACTION plugin for the task
    # action AS WRITTEN, inside the task's own collections scope - the thing
    # that decides which collection action plugins real IMPORTS (and thus
    # whose deprecated module_utils imports it prints).
    #
    # Real's TaskExecutor._get_action_handler runs
    # `action_loader.has_plugin(action, collection_list=task.collections)`
    # before importing one, and the module LOADER is the permissive one: it
    # searches every collection for a bare module name (bare `k8s:` found
    # kubernetes.core.k8s with no `collections:` keyword), while the ACTION
    # loader only searches the collections the task scopes. Real therefore
    # runs such a task through `normal` and imports no action plugin, so its
    # `to_bytes`/`to_native`/`to_text` deprecations never print (issue
    # #1352, shonpaz123.dockercoins). A bare name does load one when
    # ansible_builtin_runtime.yml redirects the ACTION routing for it (bare
    # `synchronize:`/`patch:`) or a collection the task's scope lists
    # provides it. nil/unknown scope and one-dot names stay permissive.
    def self.action_plugin_in_scope?(name : String, task_collections : Array(String)? = nil) : Bool
      return true if name.empty? || name.includes?("{{")
      parts = name.split('.')
      return true if parts.size == 2
      if parts.size >= 3
        return true if parts[0] == "ansible" && (parts[1] == "builtin" || parts[1] == "legacy")
        return collection_has_action_plugin?(parts[0], parts[1], parts[2..].join('.')) != false
      end
      return true if builtin_module?(name)
      return true unless task_collections
      if target = baked_redirects("action")[name]?
        result = action_chain_resolves?(target, Set(String).new)
        return result unless result.nil?
      end
      task_collections.any? { |entry| listed_collection_provides?(name, entry) }
    end

    # Would the captured collection `<ns>.<coll>` ship an action plugin (or
    # the module file the generic `normal` action would run) for `leaf`?
    # nil for a collection the capture kept no file tree on - the caller
    # must stay permissive then.
    private def self.collection_has_action_plugin?(namespace : String, collection : String, leaf : String) : Bool?
      paths = CollectionRuntimeData.collection("#{namespace}.#{collection}").try(&.paths)
      return nil unless paths
      return true if action_plugin_events_key?(namespace, collection, leaf)
      paths.includes?("plugins/modules/#{leaf}.py") || paths.includes?("plugins/action/#{leaf}.py")
    end

    private def self.action_plugin_events_key?(namespace : String, collection : String, leaf : String) : Bool
      CollectionRuntimeData.action_plugins.fetch("#{namespace}.#{collection}", nil).try(&.has_key?(leaf)) || false
    end

    private def self.listed_collection_provides?(leaf : String, entry : String) : Bool
      return false unless entry.count('.') == 1
      namespace, collection = entry.split('.', 2)
      # The action plugin inventory covers every captured collection, even
      # the ones with no baked module tree.
      return true if action_plugin_events_key?(namespace, collection, leaf)
      collection_has_action_plugin?(namespace, collection, leaf) == true
    end

    # One hop of an ACTION routing target, nil when undecidable.
    private def self.action_chain_resolves?(fqcn : String, seen : Set(String)) : Bool?
      return nil if seen.includes?(fqcn) || seen.size > MAX_REDIRECT_HOPS
      seen << fqcn
      parts = fqcn.split('.')
      return nil if parts.size < 3
      return true if parts[0] == "ansible" && parts[1] == "builtin" && builtin_action_plugin?(parts[2..].join('.'))
      leaf = parts[2..].join('.')
      result = collection_has_action_plugin?(parts[0], parts[1], leaf)
      return result unless result == false
      cached = CollectionRuntimeData.collection("#{parts[0]}.#{parts[1]}")
      if target = cached.try(&.redirects["action"]?.try(&.[leaf]?))
        return action_chain_resolves?(target, seen)
      end
      false
    end

    # Whether real's loader resolves `name` to a module file known to the
    # captured environment. Returns false ONLY when krikri's own tables say
    # the name cannot resolve (an ansible-core builtin/redirect miss, or a
    # captured collection that ships no such module file); nil means
    # undecidable (a collection the capture kept no file tree on, a
    # redirect cycle, a templated name) and callers must stay permissive.
    #
    # This is krikri-lint's module-existence check (ansible-lint's
    # `syntax-check` rule). It is NOT the playbook parser's decision: krikri
    # does not refuse a playbook wholesale over an unknown module name - an
    # unresolvable name takes the executor's unavailable-module flow, so a
    # when:-gated task real would never resolve still skips cleanly here
    # (round 811000; the parse-time refusal this replaced was never
    # approved, and it made the whole run depend on the controller's
    # installed collections).

    def self.reference_resolves?(name : String,
                                 task_collections : Array(String) = [] of String,
                                 role_path : String? = nil,
                                 playbook_dir : String? = nil) : Resolution
      unsure : Resolution = {resolves: nil}
      return unsure if name.empty? || name.includes?("{{")

      parts = name.split('.')
      return fqcn_resolution(name) if parts.size >= 3
      # A one-dot name is not a module FQCN (collections are two
      # components); what real does with one is not worth deciding.
      return unsure if parts.size == 2

      bare_resolution(name, task_collections, role_path, playbook_dir)
    end

    # The FQCN (three-dot-plus) branch. ansible.builtin./ansible.legacy.
    # spellings stay on krikri's own resolution - the builtin collection is
    # by definition always present and krikri's core set is the curated
    # truth there.
    private def self.fqcn_resolution(name : String) : Resolution
      parts = name.split('.')
      ns, coll = parts[0], parts[1]
      leaf = parts[2..].join('.')
      unsure : Resolution = {resolves: nil}
      return unsure if ns == "ansible" && (coll == "builtin" || coll == "legacy")
      fq = "#{ns}.#{coll}.#{leaf}"
      result = chain_resolves?("modules", fq, Set(String).new)
      return {resolves: true} if result[:resolves] == true
      # Module routing definitively dead: real still consults the action
      # routing before refusing (bare `ios:` resolves only through
      # cisco.ios's action plugin, live-verified vs 2.19.11).
      return unsure unless result[:resolves] == false
      action = action_chain_resolves?(fq, Set(String).new)
      action.nil? ? unsure : {resolves: action}
    end

    # The bare-name branch: ansible-core module file, builtin-runtime
    # redirect, the `collections:` keyword's listed collections, then the
    # role/playbook-private library/ roots.
    private def self.bare_resolution(name : String,
                                     task_collections : Array(String),
                                     role_path : String?,
                                     playbook_dir : String?) : Resolution
      return {resolves: true} if builtin_module?(name)

      # A library/ source outranks everything collection-side: ansible
      # resolves a bare name against the role's / playbook's own
      # `library/` BEFORE the collection loader, so a redirect chain that
      # dies in a removed module (issue #724: bare `consul_acl:` ->
      # community.general.consul_acl's tombstone) is never consulted when
      # the library file exists.
      return {resolves: true} if library_module?(name, role_path, playbook_dir)

      if target = baked_redirects("modules")[name]?
        result = chain_resolves?("modules", target, Set(String).new)
        return {resolves: result[:resolves]} unless result[:resolves].nil?
      end

      # Action routing: the module file is gone but an action-plugin redirect
      # still resolves the name (bare `yum:` -> ansible.builtin.dnf).
      if target = baked_redirects("action")[name]?
        action = action_chain_resolves?(target, Set(String).new)
        return {resolves: action} unless action.nil?
      end

      return {resolves: true} if task_collections.any? { |entry| listed_collection_provides?(name, entry) }

      # A role-local action plugin: ansible's observed behaviour
      # (gwerlas.libvirt, issue #517) is that shipping
      # `action_plugins/warn.py` inside a role makes the bare action name
      # `warn:` resolve at load time.
      return {resolves: true} if local_action_plugin?(name, role_path, playbook_dir)

      {resolves: false}
    end

    # The redirect-chain resolution for an FQCN along one routing kind: the
    # captured collection must ship the plugin file, or redirect onward
    # through its own routing table, with ansible_builtin_runtime.yml's
    # FQCN keys consulted when the collection chain ends.
    private def self.chain_resolves?(kind : String, fqcn : String, seen : Set(String)) : Resolution # ameba:disable Metrics/CyclomaticComplexity
      return {resolves: nil} if seen.includes?(fqcn) || seen.size > MAX_REDIRECT_HOPS
      seen << fqcn

      parts = fqcn.split('.')
      return {resolves: nil} if parts.size < 3
      ns, coll = parts[0], parts[1]
      leaf = parts[2..].join('.')

      return {resolves: builtin_target?(kind, leaf)} if ns == "ansible" && coll == "builtin"

      if paths = CollectionRuntimeData.collection("#{ns}.#{coll}").try(&.paths)
        return captured_collection_resolution(kind, paths, "#{ns}.#{coll}", leaf, fqcn, seen)
      end

      # The LEGACY-CORE collections (posix/netcommon/utils/windows) are part
      # of the ansible.builtin surface this engine implements: ansible-core's
      # own runtime data binds their names into builtin resolution and the
      # distro ansible packages ship them with it.
      if ns == "ansible" && {"posix", "netcommon", "utils", "windows", "legacy"}.includes?(coll)
        return {resolves: true}
      end

      # The capture kept only routing/version data for this collection (it
      # provides none of the modules krikri runs): its own FQCN redirect can
      # still resolve the name, everything else stays undecidable.
      if cached = CollectionRuntimeData.collection("#{ns}.#{coll}")
        if target = cached.redirects[kind]?.try(&.[leaf]?)
          result = chain_resolves?(kind, target, seen)
          return result unless result[:resolves].nil?
        end
        if target = baked_redirects(kind)[fqcn]?
          result = chain_resolves?(kind, target, seen)
          return result unless result[:resolves].nil?
        end
        return {resolves: nil}
      end
      {resolves: nil}
    end

    # Does ansible-core provide `leaf` under this routing kind? For "action"
    # either the action plugin file or the module file (a module without a
    # dedicated action plugin still runs through the generic normal action).
    private def self.builtin_target?(kind : String, leaf : String) : Bool
      case kind
      when "modules"
        builtin_module?(leaf)
      when "lookup"
        Krikri.builtin_lookup_names.includes?(leaf)
      else
        builtin_action_plugin?(leaf) || builtin_module?(leaf)
      end
    end

    # A captured collection's own resolution: the plugin file, then its
    # routing redirects, then the builtin runtime's FQCN redirect. The
    # captured tree IS real's first-copy view, so a file it does not carry
    # is definitively absent for real too.
    private def self.captured_collection_resolution(kind : String, paths : Set(String), fq : String,
                                                    leaf : String, fqcn : String, seen : Set(String)) : Resolution
      return {resolves: true} if collection_leaf_file?(kind, paths, leaf)
      if target = CollectionRuntimeData.collection(fq).try(&.redirects[kind]?.try(&.[leaf]?))
        result = chain_resolves?(kind, target, seen)
        return result unless result[:resolves].nil?
      end
      # Names that moved collections keep a builtin-runtime entry even after
      # the source collection dropped them.
      if target = baked_redirects(kind)[fqcn]?
        result = chain_resolves?(kind, target, seen)
        return result unless result[:resolves].nil?
      end
      {resolves: false}
    end

    private def self.collection_leaf_file?(kind : String, paths : Set(String), leaf : String) : Bool
      # A dotted leaf is not a file name at all: ansible-core's FQCR
      # grammar reads it as subdir segments (below the plugin-type dir) plus
      # the resource.
      return collection_subdir_leaf_file?(kind, paths, leaf) if leaf.includes?('.')
      # The lookup kind checks ONLY the lookup plugin directory - a
      # collection that ships a module named X does not provide a lookup
      # named X.
      return paths.includes?("plugins/lookup/#{leaf}.py") if kind == "lookup"
      return true if paths.includes?("plugins/modules/#{leaf}.py")
      kind == "action" && paths.includes?("plugins/action/#{leaf}.py")
    end

    # An FQCR may carry plugin-type SUBDIR segments
    # (`ns.coll.subdir.resource`), and ansible-core resolves one by
    # importing `ansible_collections.ns.coll.plugins.<kind>.<subdirs>` as a
    # package and looking the resource up beside it. A subdir segment naming
    # a plugin FILE (plugins/modules/subdir.py) is imported as a package
    # whose dirname is the plugin-type directory itself, so the resource
    # lookup happens in that directory: that is why
    # `community.general.locale_gen.locale_gen` resolves to
    # plugins/modules/locale_gen.py and RUNS it (live-verified against
    # ansible-core 2.21.6 - lifeofguenter.reset_locale, issue #1253).
    private def self.collection_subdir_leaf_file?(kind : String, paths : Set(String), leaf : String) : Bool
      segments = leaf.split('.')
      resource = segments.pop
      return false if segments.empty? || resource.empty?

      base = "plugins/#{kind}"
      segments.each_with_index do |segment, index|
        nested = "#{base}/#{segment}"
        if paths.any? { |path| path.starts_with?("#{nested}/") }
          base = nested
          next
        end
        return false unless index == segments.size - 1 && paths.includes?("#{base}/#{segment}.py")
        return plugin_resource_file?(kind, paths, base, resource)
      end
      plugin_resource_file?(kind, paths, base, resource)
    end

    # The resource file beside a resolved subdir "package": modules load
    # extension-lessly (exact name, then a fuzzy `<resource>.*` match
    # excluding MODULE_IGNORE_EXTS), action/lookup plugins need `.py`.
    private def self.plugin_resource_file?(kind : String, paths : Set(String), base : String, resource : String) : Bool
      exact = "#{base}/#{resource}"
      case kind
      when "modules"
        return true if paths.includes?(exact)
        paths.any? do |path|
          path.starts_with?("#{exact}.") && !path[(exact.size + 1)..].includes?('/') &&
            !MODULE_IGNORE_EXTS.any? { |ext| path.ends_with?(ext) }
        end
      else
        paths.includes?("#{base}/#{resource}.py")
      end
    end

    # Whether real's loader resolves `name` as an FQCR whose subdir segments
    # sit below the captured collection's plugins/modules/ dir (see
    # collection_subdir_leaf_file?). The parser uses this to map such a name
    # onto the resource module it actually runs.
    def self.fqcr_subdir_resolves?(name : String) : Bool
      parts = name.split('.')
      return false if parts.size < 4
      return false if parts[0] == "ansible" && (parts[1] == "builtin" || parts[1] == "legacy")
      paths = CollectionRuntimeData.collection("#{parts[0]}.#{parts[1]}").try(&.paths) || return false
      collection_subdir_leaf_file?("modules", paths, parts[2..].join('.'))
    end

    # Role-private / playbook-adjacent `library/<name>` module source - the
    # same lookup PythonModuleRunner.find_source performs at run time (any
    # extension except Ansible's MODULE_IGNORE_EXTS), so the parse-time
    # checks never fire for a module the runner would actually execute.
    def self.library_module?(name : String, role_path : String?, playbook_dir : String?) : Bool
      short = name.rpartition('.')[2]
      return false if short.empty?

      roots = [] of String
      roots << File.join(role_path, "library") if role_path
      roots.concat(PythonFilterRunner.loaded_role_roots("library"))
      roots << File.join(playbook_dir, "library") if playbook_dir && !playbook_dir.empty?
      # ansible's configured module path (ansible.cfg `[defaults] library` /
      # ANSIBLE_LIBRARY) is searched after the role- and playbook-local
      # extra dirs.
      roots.concat(AnsibleConfig.library_paths || [] of String)

      roots.each do |root|
        return true if File.file?(File.join(root, "#{short}.py"))
        return true if File.file?(File.join(root, short))
        # A dangling symlink (debops-contrib.btrfs ships library/
        # btrfs_subvolume.py -> ../submodules/..., an uninitialised git
        # submodule) is no module file.
        found = Dir.glob(File.join(root, "#{short}.*")).sort.any? do |other|
          File.file?(other) && !MODULE_IGNORE_EXTS.any? { |ext| other.ends_with?(ext) }
        end
        return true if found
      end
      false
    end

    # The action-plugin analogue of library_module?: ansible resolves a bare
    # action name to a role's (or the playbook's) own
    # `action_plugins/<short>.py` at load time (issue #517:
    # gwerlas.libvirt's `warn:` handler). Only `.py` files count here -
    # unlike `library/`, action plugins cannot be extensionless shell
    # scripts.
    private def self.local_action_plugin?(name : String, role_path : String?, playbook_dir : String?) : Bool
      short = name.rpartition('.')[2]
      return false if short.empty?

      roots = [] of String
      roots << File.join(role_path, "action_plugins") if role_path && !role_path.empty?
      roots.concat(PythonFilterRunner.loaded_role_roots("action_plugins"))
      roots << File.join(playbook_dir, "action_plugins") if playbook_dir && !playbook_dir.empty?
      roots.concat(PythonFilterRunner.configured_roots("action", "ANSIBLE_ACTION_PLUGINS"))

      roots.any? { |root| File.file?(File.join(root, "#{short}.py")) }
    end

    # A role's own meta/main.yml `collections:` list - the role's
    # declaration of the collections its bare module names resolve through,
    # which ansible-core folds into the task's collection search
    # (live-verified vs 2.19.11: a role declaring
    # `collections: [community.crypto]` resolves its bare `x509_certificate:`
    # task). Memoized per role path; a role with no meta/main.yml or an
    # unreadable one contributes nothing.
    def self.role_meta_collections(role_path : String?) : Array(String)
      return [] of String unless role_path
      cached = @@role_meta_collections[role_path]?
      return cached if cached

      collections = [] of String
      meta = File.join(role_path, "meta", "main.yml")
      if File.file?(meta)
        begin
          parsed = YAML.parse(File.read(meta))
          if list = parsed["collections"]?.try(&.as_a?)
            list.each do |entry|
              name = entry.as_s?
              collections << name if name
            end
          end
        rescue
          # unreadable meta contributes nothing
        end
      end
      @@role_meta_collections[role_path] = collections
      collections
    end
  end
end
