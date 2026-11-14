require "base64"
require "colorize"
require "compress/gzip"
require "json"
require "yaml"
require "./builtin_module_names_data"
require "./python_filter_runner"

# Controller collection-set awareness (real's module-name resolution,
# discovered from the controller this engine runs on rather than
# modeled): krikri-playbook runs on the SAME controller real
# ansible-playbook would, so instead of hardcoding which collections a
# "typical" controller has, enumerate what is actually installed and
# apply ansible-core's own load-time resolution rules to each task's
# module name. A name real could not resolve - a bare name that is
# neither an ansible-core module nor redirected by
# ansible_builtin_runtime.yml, an FQCN whose collection directory is
# absent, or an FQCN whose collection is installed but ships no such
# module file - makes ansible-core refuse the WHOLE playbook at load
# (rc=4, zero tasks run, "couldn't resolve module/action '<name>'" +
# the task's Origin block, probed live against 2.19.11 for bare
# `docker:`, bare `ec2_facts:`, `freeipa.ansible_freeipa.*` and an
# installed-collection module file that does not exist). This engine
# previously ran (or lazily skipped) every such name because it
# implements community modules natively without caring whether the
# controller has them.
#
# Deliberately conservative in the risky direction: refusing a playbook
# real would run is worse than running one real refuses, so every
# "unsure" outcome (no ansible-core installation discoverable, an
# unreadable/malformed runtime.yml, a redirect cycle, an unknown path
# layout) returns nil and the caller keeps today's behavior - the
# refusal only fires when a needed directory/file is DEFINITELY absent
# from every path real itself would search.
module Krikri
  module CollectionIndex
    # Maximum meta/runtime.yml redirect chain depth before giving up as
    # "unsure" - real's own loader has no explicit cap but no real chain
    # comes close to this; the cap only stops adversarial cycles.
    private MAX_REDIRECT_HOPS = 12

    # ansible-core's own MODULE_IGNORE_EXTS: the extensions its loader's
    # fuzzy module match skips, so an editor backup or a README beside a
    # module never counts as the module.
    MODULE_IGNORE_EXTS = %w[.pyc .pyo .swp .bak ~ .rpm .md .txt .rst .yaml .yml .ini]

    # Collection roots: directories that CONTAIN an `ansible_collections/`
    # tree, in real's own search order (ANSIBLE_COLLECTIONS_PATH first,
    # then the user and system install locations, then the ansible-core
    # package's own shipped collections). Memoized once per process -
    # a playbook parse consults this dozens of times.
    @@roots : Array(String)? = nil
    @@collection_dirs : Hash(String, Array(String))? = nil
    @@builtin_modules : Set(String)? = nil
    @@ansible_pkg_dirs : Array(String)? = nil
    @@builtin_redirects : Hash(String, String)? = nil
    @@builtin_redirects_loaded = false
    @@builtin_action_redirects : Hash(String, String)? = nil
    @@builtin_action_redirects_loaded = false
    @@builtin_lookup_redirects : Hash(String, String)? = nil
    @@builtin_lookup_redirects_loaded = false
    @@collection_redirects = Hash(String, Hash(String, String)?).new
    @@role_meta_collections = Hash(String, Array(String)).new
    @@collection_versions = Hash(String, String?).new

    # Test seam: forget everything scanned, so a spec can point
    # ANSIBLE_COLLECTIONS_PATH at a fixture and rescan (same pattern as
    # ActionGroups.reset!).
    def self.reset! : Nil
      @@role_meta_collections.clear
      @@roots = nil
      @@collection_dirs = nil
      @@builtin_modules = nil
      @@ansible_pkg_dirs = nil
      @@builtin_redirects = nil
      @@builtin_redirects_loaded = false
      @@builtin_action_redirects = nil
      @@builtin_action_redirects_loaded = false
      @@builtin_lookup_redirects = nil
      @@builtin_lookup_redirects_loaded = false
      @@collection_redirects.clear
      @@collection_versions.clear
    end

    # Directories that contain an `ansible_collections/` subtree, real's
    # search order. Beyond the env var and the two config-default
    # locations this also scans the standard Python package directories
    # for an `ansible_collections` tree (Debian/Ubuntu install
    # ansible-core's dependency collections under
    # /usr/lib/python3/dist-packages/ansible_collections, which
    # `ansible-galaxy collection list` reports as a search path) and -
    # when it can - follows the `ansible-playbook` on PATH's shebang to
    # a virtualenv's site-packages, whose collections a bare
    # dist-packages scan would otherwise miss.
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

      # The ansible-core package tree itself: its config/, modules/ and
      # shipped ansible_collections/ live under one of the standard
      # python package dirs. Also derived from the ansible-playbook on
      # PATH's shebang so a virtualenv installation's collections are
      # found even when they are not under a globbed prefix.
      package_bases(ansible_playbook_shebang_prefix).each do |base|
        ["#{base}/ansible_collections", "#{base}/ansible/_internal/ansible_collections"].each do |candidate|
          roots << candidate if Dir.exists?(candidate)
        end
      end

      roots = roots.uniq
      @@roots = roots
      roots
    end

    # Base directories that may contain an `ansible/` package (and thus
    # config/ansible_builtin_runtime.yml and modules/), plus any
    # shebang-derived virtualenv base. Globbed rather than hardcoded so
    # point releases (/usr/lib/python3.11 vs python3.12) both match.
    private def self.package_bases(shebang_prefix : String?) : Array(String)
      bases = [] of String
      ["/usr/lib", "/usr/local/lib", "/opt"].each do |prefix|
        Dir.glob("#{prefix}/python3*").each do |pydir|
          ["dist-packages", "site-packages"].each do |leaf|
            candidate = File.join(pydir, leaf)
            bases << candidate if Dir.exists?(candidate)
          end
        end
      end
      if shebang_prefix
        Dir.glob("#{shebang_prefix}/lib/python3*/site-packages").each do |candidate|
          bases << candidate if Dir.exists?(candidate)
        end
      end
      # pip's "default user install" (`pip3 install ansible-core` as a
      # non-root user falls back to --user): ~/.local/lib/python3.X/
      # site-packages - the harness's own ansible-core install path on
      # the batch hosts, and home to its ansible_collections too
      # (round 5440000's four confirm roles: the index found nothing
      # there and every refusal degraded to unsure -> run).
      if home = ENV["HOME"]?
        Dir.glob("#{home}/.local/lib/python3*/site-packages").each do |candidate|
          bases << candidate if Dir.exists?(candidate)
        end
      end
      bases.uniq
    end

    # The `ansible-playbook` executable on PATH's shebang interpreter
    # directory (e.g. /opt/venv/bin for `#!/opt/venv/bin/python3`), or
    # nil. A pipx-style shim (`#!/bin/sh` wrapper execing the real
    # interpreter) defeats this - those fall through to the globbed
    # bases above.
    private def self.ansible_playbook_shebang_prefix : String?
      path = ENV["PATH"]?
      return nil unless path
      path.split(':').each do |dir|
        next if dir.empty?
        candidate = File.join(dir, "ansible-playbook")
        next unless File::Info.executable?(candidate) && File.file?(candidate)
        begin
          first = File.open(candidate, &.read_line)
        rescue
          next
        end
        if first.starts_with?("#!") && first.includes?("python")
          bin_dir = File.dirname(first.lchop("#!").strip)
          return bin_dir unless bin_dir == "/usr/bin" || bin_dir == "/bin" ||
                                bin_dir == "/usr/local/bin"
        end
        return nil
      end
      nil
    end

    # "ns.coll" => the existing collection directories, in search order
    # (first hit is the one real's loader would import from).
    private def self.collection_dirs : Hash(String, Array(String))
      cached = @@collection_dirs
      return cached if cached

      dirs = Hash(String, Array(String)).new
      roots.each do |root|
        # The env var and defaults name collections ROOTS (each containing
        # an ansible_collections/ tree), but a path pointing directly AT
        # an ansible_collections dir also works - scan both shapes.
        trees = [File.join(root, "ansible_collections"), root]
        trees.uniq.each do |tree|
          next unless Dir.exists?(tree) && File.basename(tree) == "ansible_collections"
          Dir.children(tree).each do |namespace|
            next if namespace.starts_with?(".")
            ns_dir = File.join(tree, namespace)
            next unless Dir.exists?(ns_dir)
            Dir.children(ns_dir).each do |collection|
              next if collection.starts_with?(".")
              coll_dir = File.join(ns_dir, collection)
              next unless Dir.exists?(coll_dir)
              fq = "#{namespace}.#{collection}"
              (dirs[fq] ||= Array(String).new) << coll_dir
            end
          end
        end
      end
      @@collection_dirs = dirs
      dirs
    end

    # Is the collection directory present under any search root?
    def self.installed?(namespace : String, collection : String) : Bool
      collection_dirs.has_key?("#{namespace}.#{collection}")
    end

    # The `version` of an installed collection's MANIFEST.json - the
    # release `ansible-galaxy` wrote into the copy real's loader would
    # import from (collection_dirs' first hit). nil when the collection
    # is not installed or no version field is readable; a tree installed
    # any other way (a raw git checkout, which carries galaxy.yml rather
    # than a MANIFEST.json) reports nil rather than guessing.
    def self.collection_version(fq : String) : String?
      if @@collection_versions.has_key?(fq)
        return @@collection_versions[fq]
      end
      version = nil
      if dir = collection_dirs[fq]?.try(&.first?)
        version = manifest_version(dir)
      end
      @@collection_versions[fq] = version
      version
    end

    private def self.manifest_version(dir : String) : String?
      path = File.join(dir, "MANIFEST.json")
      return nil unless File.file?(path)
      info = JSON.parse(File.read(path))["collection_info"]?
      info.try { |entry| entry["version"]?.try(&.as_s?) }
    rescue
      nil
    end

    # The version of the collection release whose module source `name`
    # resolves to, following the same redirect chain real's loader walks
    # (bare `mount:` -> ansible.posix.mount through the builtin runtime
    # table, the FQCN spellings straight through). A bare name with no
    # redirect entry is matched against every installed collection's
    # plugins/modules/. nil when the name resolves to ansible-core
    # itself, to a role-private library/ module, or when no release
    # version is readable - callers keep their existing modeling then
    # (see version_before?'s unknown-version default).
    def self.module_provider_version(name : String) : String?
      module_provider_collection(name).try { |collection_fq| collection_version(collection_fq) }
    end

    # The collection whose module source `name` resolves to (its FQCN
    # `namespace.collection`), following the same redirect chain real's
    # loader walks. nil when the name resolves to ansible-core itself or
    # to a role-private library/ module.
    def self.module_provider_collection(name : String) : String?
      return nil if name.empty? || name.includes?("{{")
      resolved = module_redirect_chain(name)
      parts = resolved.split('.')
      if parts.size >= 3
        return nil if parts[0] == "ansible" && (parts[1] == "builtin" || parts[1] == "legacy")
        return "#{parts[0]}.#{parts[1]}"
      end
      collection_dirs.each do |collection_fq, collection_paths|
        next unless collection_paths.any? { |path| collection_leaf_file?("modules", path, resolved) }
        return collection_fq
      end
      nil
    end

    # Whether `version` (a collection release's MANIFEST.json `version`)
    # predates major.minor.patch, comparing the numeric leading segments.
    # An unknown/unparseable version counts as predating: the callers
    # model the OLDER module line when they cannot pin the resolved
    # release (ansible-core's own modules, role-private library/ sources,
    # trees without a MANIFEST.json) - the same conservative default the
    # engine hardcoded before the resolved release became visible.
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
    # (`query('dig', ...)`)? Unlike modules/actions - whose bare names
    # search only ansible.legacy, ansible.builtin and the task's listed
    # collections - lookup (and filter) names are scanned across EVERY
    # installed collection (live-verified vs 2.19.11: bare `dig`/
    # `dnstxt` run community.general's own plugins with no `collections:`
    # keyword anywhere). The builtin runtime's plugin_routing.lookup
    # redirect table participates first (`redis` -> community.general),
    # so an ansible-core present but redirect-target collection absent
    # is a definite false, not unsure. nil = unsure (no ansible-core
    # installation discoverable) - the caller must not refuse on nil.
    def self.bare_lookup_resolves?(name : String) : Bool?
      return nil if name.empty? || name.includes?(".")
      case builtin_target?("lookup", name)
      when true
        return true
      when nil
        # No ansible-core installation discoverable: the installed-
        # collection scan is still a definite positive when it hits,
        # but everything else stays unsure - inventing a refusal
        # without the runtime data would be the dangerous direction.
        return true if collection_provides_lookup?(name)
        return nil
      end

      # The builtin runtime's lookup redirect table (`redis` ->
      # community.general.redis): the hop real's loader takes a bare
      # name through before the installed-collection scan. A chain that
      # dies on an absent collection is NOT returned directly - the
      # installed-collection scan below still gets its say (a bare name
      # can also resolve as a plain file elsewhere), and only a scan
      # miss makes the negative definite.
      if redirects = builtin_redirects("lookup")
        if target = redirects[name]?
          result = chain_resolves?("lookup", target, Set(String).new)
          return true if result[:resolves] == true
          return nil if result[:resolves].nil?
        end
      else
        return nil
      end

      collection_provides_lookup?(name) ? true : false
    end

    # Does any INSTALLED collection provide the bare lookup name - a
    # plugins/lookup/<name>.py file, or a meta/runtime.yml
    # plugin_routing.lookup redirect whose target resolves? Bare lookup
    # (and filter) names are scanned across EVERY installed collection
    # - not just the task's listed ones - and each collection's own
    # redirect table participates in its scan the same way it does for
    # an FQCN.
    private def self.collection_provides_lookup?(name : String) : Bool
      collection_dirs.each_value do |dirs|
        dirs.each do |dir|
          return true if File.file?(File.join(dir, "plugins", "lookup", "#{name}.py"))
          cache_key = "#{dir}\0lookup"
          redirects = @@collection_redirects[cache_key]?
          if redirects.nil? && !@@collection_redirects.has_key?(cache_key)
            redirects = collection_redirects_uncached(dir, "lookup")
            @@collection_redirects[cache_key] = redirects
          end
          next unless redirects && (target = redirects[name]?)
          result = chain_resolves?("lookup", target, Set(String).new)
          return true if result[:resolves] == true
        end
      end
      false
    end

    # The ansible-core package directories (dirs containing an `ansible/`
    # package with a modules/ or config/ tree). Empty when no python
    # ansible installation is discoverable - every builtin-dependent
    # answer then degrades to nil ("unsure").
    private def self.ansible_pkg_dirs : Array(String)
      cached = @@ansible_pkg_dirs
      return cached if cached

      dirs = [] of String
      (package_bases(ansible_playbook_shebang_prefix) + ["/usr/lib/python3/dist-packages",
                                                         "/usr/local/lib/python3/dist-packages"]).uniq.each do |base|
        pkg = File.join(base, "ansible")
        next unless Dir.exists?(pkg)
        dirs << pkg if Dir.exists?(File.join(pkg, "modules")) || File.file?(File.join(pkg, "config", "ansible_builtin_runtime.yml"))
      end
      @@ansible_pkg_dirs = dirs
      dirs
    end

    # Is `<leaf>` an ansible-core builtin module (a module file shipped
    # inside the ansible-core package)? nil when no ansible-core
    # installation is discoverable - the caller must then not refuse.
    def self.builtin_module?(leaf : String) : Bool?
      if ansible_pkg_dirs.empty?
        # No ansible-core on this controller: the baked 2.21.6 data is
        # the truth (same reason as builtin_redirects's fallback). The
        # baked name set is the modules/ FILES plus every
        # ansible_builtin_runtime.yml redirect key - but a redirect key
        # is not a module FILE: real resolves such a bare name through
        # the redirect chain and refuses it when the target collection
        # is absent (bare `gc_storage:` -> community.google.gc_storage,
        # live-verified vs 2.19.11). Excluding the redirect keys here
        # lets bare_resolution fall through to that chain instead of
        # short-circuiting every redirected name into "resolves".
        if redirects = builtin_redirects("modules")
          return Krikri.builtin_module_names.includes?(leaf) &&
            !redirects.has_key?(leaf) &&
            !builtin_redirects("action").try(&.has_key?(leaf))
        end
        return Krikri.builtin_module_names.includes?(leaf)
      end

      cached = @@builtin_modules
      modules = cached || begin
        set = Set(String).new
        ansible_pkg_dirs.each do |pkg|
          Dir.glob(File.join(pkg, "modules", "**", "*.py")).each do |path|
            set << File.basename(path, ".py")
          end
          # A real ansible.builtin collection tree (some pip layouts ship
          # one under ansible_collections/ansible/builtin) counts too.
          Dir.glob(File.join(pkg, "..", "ansible_collections", "ansible", "builtin",
            "plugins", "modules", "*.py")).each do |path|
            set << File.basename(path, ".py")
          end
        end
        @@builtin_modules = set
        set
      end
      modules.includes?(leaf)
    end

    # ansible_builtin_runtime.yml's redirect tables (bare name or FQCN
    # key -> redirect target), one per routing kind ("modules" and
    # "action" - the action table is what makes bare `yum:` resolve: its
    # module was removed from ansible-core but the action routing still
    # redirects it onto ansible.builtin.dnf, and real runs it, live
    # -verified vs 2.19.11). nil table = the yml was not found or could
    # not be parsed (no ansible-core discoverable) - the caller must not
    # treat "no redirect" as proof of anything then.
    private def self.builtin_redirects(kind : String) : Hash(String, String)?
      cache, loaded = case kind
                      when "modules" then {@@builtin_redirects, @@builtin_redirects_loaded}
                      when "action"  then {@@builtin_action_redirects, @@builtin_action_redirects_loaded}
                      else                {@@builtin_lookup_redirects, @@builtin_lookup_redirects_loaded}
                      end
      return cache if loaded

      ansible_pkg_dirs.each do |pkg|
        path = File.join(pkg, "config", "ansible_builtin_runtime.yml")
        next unless File.file?(path)
        table = parse_runtime_redirects(path, kind)
        case kind
        when "modules"
          @@builtin_redirects = table
          @@builtin_redirects_loaded = true
        when "action"
          @@builtin_action_redirects = table
          @@builtin_action_redirects_loaded = true
        else
          @@builtin_lookup_redirects = table
          @@builtin_lookup_redirects_loaded = true
        end
        return table
      end
      # No ansible-core installation discoverable: fall back to the
      # BAKED-IN 2.21.6 tables (krikri replaces ansible-core on this
      # controller - its redirect truth is the same data the missing
      # package would carry; round 5440000's confirm roles ran because
      # this fallback used to return nil and every refusal degraded to
      # "unsure").
      baked_modules, baked_action = Krikri.builtin_runtime_redirects
      if kind == "modules"
        @@builtin_redirects = baked_modules
        @@builtin_redirects_loaded = true
        return baked_modules
      elsif kind == "action"
        @@builtin_action_redirects = baked_action
        @@builtin_action_redirects_loaded = true
        return baked_action
      end
      # The lookup kind has no baked table: without a discoverable
      # ansible-core the caller must treat the answer as unsure (the
      # bare-name lookup not-found gate only refuses on a definite
      # negative).
      nil
    end

    # A bare module name's ansible_builtin_runtime.yml redirect target
    # ("modules" routing), when the builtin runtime carries one for it
    # (bare `docker_service:` -> community.general.docker_service) - the
    # hop real's loader takes a bare name through before any target
    # collection's own meta/runtime.yml (and its tombstones) is
    # consulted. nil when the name has no builtin-runtime redirect; the
    # baked 2.21.6 table is the fallback when no ansible-core
    # installation is discoverable, same as builtin_redirects.
    def self.builtin_module_redirect(name : String) : String?
      builtin_redirects("modules").try(&.[name]?)
    end

    # One collection directory's meta/runtime.yml redirect table for a
    # routing kind, memoized per directory (the same cache
    # installed_collection_resolution fills inline).
    private def self.collection_redirects(dir : String, kind : String) : Hash(String, String)?
      cache_key = "#{dir}\0#{kind}"
      redirects = @@collection_redirects[cache_key]?
      if redirects.nil? && !@@collection_redirects.has_key?(cache_key)
        redirects = collection_redirects_uncached(dir, kind)
        @@collection_redirects[cache_key] = redirects
      end
      redirects
    end

    # The module name real's loader reports after chasing the FULL
    # redirect chain: ansible_builtin_runtime.yml hops (for a bare name
    # or an ansible.builtin./ansible.legacy. leaf) and then every target
    # collection's own meta/runtime.yml plugin_routing.modules redirect,
    # until no entry matches (cycle-limited like the resolution paths).
    # The two sources chain: ansible-core's builtin runtime still
    # redirects the legacy bare `hcloud_ssh_key` spelling onto
    # hetzner.hcloud.hcloud_ssh_key, while hetzner.hcloud 7.x's own
    # runtime.yml renames that FQCN onto the unprefixed module file
    # `hetzner.hcloud.ssh_key` - and the name real reports in the
    # task-args finalization error is the chain END, not the first hop
    # (issue #800: 'hetzner.hcloud.ssh_key', not the intermediate FQCN,
    # live-verified vs 2.19.11 for both the bare and the FQCN spelling).
    # A name with no redirect entry comes back unchanged; a collection
    # that is not installed ends the chain (no runtime.yml to consult),
    # exactly where real's loader stops chasing.
    def self.module_redirect_chain(name : String) : String
      current = name
      seen = Set(String).new
      seen << current
      while seen.size <= MAX_REDIRECT_HOPS
        target = redirect_target(current) || break
        break if seen.includes?(target)
        seen << target
        current = target
      end
      current
    end

    # The installed collection's module payload file real's loader would
    # execute for `name`, nil when no installed collection ships it. What
    # that payload imports is only knowable from the installed file: the
    # payload is versioned with the COLLECTION, not the engine -
    # ansible.posix 2.1.x's mount.py imports to_bytes/to_native from the
    # deprecated `ansible.module_utils._text` path while 2.2.x migrated
    # the same import to ansible.module_utils.common.text.converters and
    # warns nothing (issue #1061). Builtin payloads are deliberately not
    # returned: they travel from the installed ansible-core, whose own
    # modules never import from the deprecated path.
    def self.module_source_file(name : String) : String?
      parts = module_redirect_chain(name).split('.')
      return nil if parts.size < 3
      return nil if parts[0] == "ansible" && (parts[1] == "builtin" || parts[1] == "legacy")
      leaf = parts[2..].join('.')
      dirs = collection_dirs["#{parts[0]}.#{parts[1]}"]? || return nil
      dirs.each do |dir|
        path = File.join(dir, "plugins", "modules", "#{leaf}.py")
        return path if File.file?(path)
      end
      nil
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
        collection_redirect_target("#{parts[0]}.#{parts[1]}", leaf)
      end
    end

    # The first installed copy's meta/runtime.yml redirect for `leaf`, or
    # nil when the collection is not installed or carries no redirect
    # entry for it - both are chain ends for the reported name.
    private def self.collection_redirect_target(collection_fq : String, leaf : String) : String?
      dirs = collection_dirs[collection_fq]? || return nil
      dirs.each do |dir|
        if redirects = collection_redirects(dir, "modules")
          if found = redirects[leaf]?
            return found
          end
        end
      end
      nil
    end

    # One collection's meta/runtime.yml redirect table for a routing
    # kind, lazily read and memoized per collection directory. nil = no
    # redirects (file missing, no plugin_routing.<kind> section,
    # unreadable).
    private def self.collection_redirects_uncached(dir : String, kind : String) : Hash(String, String)?
      path = File.join(dir, "meta", "runtime.yml")
      return nil unless File.file?(path)
      parse_runtime_redirects(path, kind)
    end

    private def self.parse_runtime_redirects(path : String, kind : String) : Hash(String, String)?
      parsed = YAML.parse(File.read(path))
      routing = parsed["plugin_routing"]?.try(&.as_h?)
      return nil unless routing
      entries = routing[kind]?.try(&.as_h?)
      return nil unless entries

      table = Hash(String, String).new
      entries.each do |name, entry|
        next unless entry.as_h?
        if redirect = entry["redirect"]?.try(&.as_s?)
          redirect = redirect.strip
          table[name.to_s] = redirect unless redirect.empty?
        end
        # Tombstone entries deliberately NOT recorded here: whether a
        # name is refused-with-removal-message is the existing
        # REMOVED_MODULE_TOMBSTONES table's job (it keeps priority); this
        # index only reports where a resolvable module FILE lives.
      end
      table
    rescue
      nil
    end

    # Would the real controller resolve `name` (exactly as a task wrote
    # it) to an existing module file? Follows real's own rules:
    # ansible.builtin.*/ansible.legacy.* spellings, builtin files,
    # ansible_builtin_runtime.yml redirects, collection meta/runtime.yml
    # redirects (chained, cycle-limited), the `collections:` keyword's
    # listed collections, and role/playbook-private library/ modules.
    # Returns false ONLY when a needed directory/file is definitely
    # absent from every path real would search - nil means unsure
    # (missing ansible-core installation, unreadable runtime data,
    # redirect cycle), and the caller keeps the permissive path.
    #
    # A name that dies on a collection that cannot be imported refuses
    # SILENTLY: ansible-core 2.21's loader catches the ImportError while
    # it reads that collection's routing metadata (2.19 let it escape,
    # which is where the "Error loading plugin '<name>': No module named
    # ..." [WARNING] line came from), so real prints no warning ahead of
    # the refusal and resolution carries no text for the caller.
    alias Resolution = {resolves: Bool?}
    alias ChainResult = {resolves: Bool?}

    def self.controller_resolves?(name : String,
                                  task_collections : Array(String) = [] of String,
                                  role_path : String? = nil,
                                  playbook_dir : String? = nil) : Resolution
      unsure : Resolution = {resolves: nil}
      return unsure if name.empty? || name.includes?("{{")

      parts = name.split('.')
      return fqcn_resolution(name) if parts.size >= 3
      # A one-dot name is not a module FQCN (collections are two
      # components); what real does with one is not worth refusing
      # over - unsure.
      return unsure if parts.size == 2

      bare_resolution(name, task_collections, role_path, playbook_dir)
    end

    # The FQCN (three-dot-plus) branch. ansible.builtin./ansible.legacy.
    # spellings stay on krikri's own resolution (today's behavior) - the
    # builtin collection is by definition always present on a controller
    # that can run real at all, and krikri's core set is already the
    # curated truth here.
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
      # cisco.ios's action plugin, live-verified vs 2.19.11). Unsure
      # module outcome stays unsure.
      return unsure unless result[:resolves] == false
      action = chain_resolves?("action", fq, Set(String).new)
      return {resolves: true} if action[:resolves] == true
      return {resolves: false} if action[:resolves] == false
      unsure
    end

    # The bare-name branch: ansible-core module file, builtin-runtime
    # redirect, the `collections:` keyword's listed collections, then the
    # role/playbook-private library/ roots.
    private def self.bare_resolution(name : String,
                                     task_collections : Array(String),
                                     role_path : String?,
                                     playbook_dir : String?) : Resolution
      case builtin_module?(name)
      when true
        return {resolves: true}
      when nil
        # No ansible-core installation discoverable: krikri's own native
        # resolution is the only builtin signal available, and
        # inventing a refusal without it would be the dangerous
        # direction.
        return {resolves: nil}
      end

      # A library/ source outranks everything collection-side: ansible
      # resolves a bare name against the role's / playbook's own
      # `library/` BEFORE the collection loader, so a redirect chain that
      # dies in a removed module (issue #724: bare `consul_acl:` ->
      # community.general.consul_acl's tombstone) is never consulted
      # when the library file exists.
      if library_module?(name, role_path, playbook_dir)
        return {resolves: true}
      end

      if redirects = builtin_redirects("modules")
        if target = redirects[name]?
          result = chain_resolves?("modules", target, Set(String).new)
          return {resolves: result[:resolves]} unless result[:resolves].nil?
        end
      else
        # No readable runtime data at all: unsure, keep running.
        return {resolves: nil}
      end

      # Action routing: the module file is gone but an action-plugin
      # redirect still resolves the name (bare `yum:` ->
      # ansible.builtin.dnf, live-verified vs 2.19.11).
      if resolution = action_redirect_resolution(name)
        return resolution
      end

      if listed_collections_provide?(name, task_collections)
        return {resolves: true}
      end

      # Same treatment for a role-local action plugin: ansible's observed
      # behaviour (gwerlas.libvirt, issue #517) is that shipping
      # `action_plugins/warn.py` inside a role makes the bare action name
      # `warn:` resolve at load time, so the playbook runs - parse must
      # not refuse a name whose only source is such a file.
      if local_action_plugin?(name, role_path, playbook_dir)
        return {resolves: true}
      end

      {resolves: false}
    end

    private def self.action_redirect_resolution(name : String) : Resolution?
      action_redirects = builtin_redirects("action") || return nil
      target = action_redirects[name]? || return nil
      result = chain_resolves?("action", target, Set(String).new)
      return nil if result[:resolves].nil?
      {resolves: result[:resolves]}
    end

    # A listed collection that cannot provide the name is skipped, not
    # fatal - real tries the next listed collection (or the legacy
    # search path) before refusing.
    private def self.listed_collections_provide?(name : String, task_collections : Array(String)) : Bool
      task_collections.any? do |entry|
        next false unless entry.count('.') == 1
        module_result = chain_resolves?("modules", "#{entry}.#{name}", Set(String).new)
        action_result = module_result[:resolves] == false ? chain_resolves?("action", "#{entry}.#{name}", Set(String).new) : nil
        module_result[:resolves] == true || action_result.try(&.[:resolves]) == true
      end
    end

    # A role's own meta/main.yml `collections:` list - the role's
    # declaration of the collections its bare module names resolve
    # through, which ansible-core folds into the task's collection
    # search (live-verified vs 2.19.11: a role declaring
    # `collections: [community.crypto]` resolves its bare
    # `x509_certificate:` task). Memoized per role path; a role with no
    # meta/main.yml or an unreadable one contributes nothing.
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

    # The redirect-chain resolution for an FQCN along one routing kind
    # ("modules" or "action"): the collection directory must exist (its
    # plugin file present, or its own meta/runtime.yml redirecting
    # onward), with the ansible_builtin_runtime.yml consulted for FQCN
    # keys when the collection directory is absent (real's builtin
    # runtime carries FQCN keys for names that moved between
    # collections, e.g. community.general.docker_service).
    #
    # On the "action" kind a leaf counts as present when EITHER the
    # collection's action plugin file OR its module file exists - a
    # module without a dedicated action plugin still runs, through the
    # generic normal action.
    private def self.chain_resolves?(kind : String, fqcn : String, seen : Set(String)) : ChainResult
      return {resolves: nil} if seen.includes?(fqcn) || seen.size > MAX_REDIRECT_HOPS
      seen << fqcn

      parts = fqcn.split('.')
      return {resolves: nil} if parts.size < 3
      ns, coll = parts[0], parts[1]
      leaf = parts[2..].join('.')

      if ns == "ansible" && coll == "builtin"
        # Redirect target inside ansible-core itself.
        return {resolves: builtin_target?(kind, leaf)}
      end

      # An installed collection is the truth for its own names: real
      # ansible refuses an FQCN whose installed collection ships no such
      # module (ansible.netcommon 8.1.0 has no cli_parse, and
      # ansible-playbook dies at load with rc=4 on it), so this check
      # must come first - the blanket legacy rule below would otherwise
      # swallow every ansible.netcommon.* name.
      if dirs = collection_dirs["#{ns}.#{coll}"]?
        return installed_collection_resolution(kind, leaf, dirs, fqcn, seen)
      end

      # The LEGACY-CORE collections (posix/netcommon/utils/windows) are
      # part of the ansible.builtin surface this engine implements:
      # ansible-core's own runtime data binds their names into builtin
      # resolution, the distro ansible packages ship them with it, and
      # the batch reference host resolved ansible.builtin.mount's
      # posix-backed module on a pip-only install (round 5410225's
      # mount payload carried ansible_collections/ansible/posix).
      # Treating them as always-resolvable keeps the firewalld/mount/
      # sysctl family running on controllers with no collections tree
      # (krikri-only hosts, test containers) while the check keeps its
      # teeth for the genuinely optional community collections.
      if ns == "ansible" && {"posix", "netcommon", "utils", "windows", "legacy"}.includes?(coll)
        return {resolves: true}
      end

      # Collection directory absent: the builtin runtime's FQCN redirect
      # is the only remaining chance.
      if redirects = builtin_redirects(kind)
        if target = redirects[fqcn]?
          result = chain_resolves?(kind, target, seen)
          return result unless result[:resolves].nil?
        end
        return {resolves: false}
      end
      {resolves: nil}
    end

    # Does ansible-core provide `leaf` under this routing kind? A module
    # file for "modules"; for "action" either the action plugin file or
    # the module file (a module without a dedicated action plugin still
    # runs through the generic normal action). nil = no ansible-core
    # installation discoverable, unsure.
    private def self.builtin_target?(kind : String, leaf : String) : Bool?
      return builtin_module?(leaf) if kind == "modules"
      if kind == "lookup"
        # A lookup plugin's file under ansible-core's own plugins/lookup/
        # - no module-file fallback (a module never serves a lookup name).
        return nil if ansible_pkg_dirs.empty?
        return ansible_pkg_dirs.any? { |pkg| File.file?(File.join(pkg, "plugins", "lookup", "#{leaf}.py")) }
      end
      case builtin_action_file?(leaf)
      when true
        return true
      when nil
        # no ansible-core dir discovered - unsure
        return nil
      end
      builtin_module?(leaf)
    end

    private def self.builtin_action_file?(leaf : String) : Bool?
      return nil if ansible_pkg_dirs.empty?
      ansible_pkg_dirs.any? { |pkg| File.file?(File.join(pkg, "plugins", "action", "#{leaf}.py")) }
    end

    # An installed collection's own resolution: the plugin file, then its
    # meta/runtime.yml redirects, then (still before "absent") the
    # builtin runtime's FQCN redirect. No import failure anywhere (the
    # collection IS importable).
    private def self.installed_collection_resolution(kind : String, leaf : String, dirs : Array(String),
                                                     fqcn : String, seen : Set(String)) : ChainResult
      dirs.each do |dir|
        return {resolves: true} if collection_leaf_file?(kind, dir, leaf)
      end
      dirs.each do |dir|
        redirects = collection_redirects(dir, kind)
        if redirects && (target = redirects[leaf]?)
          result = chain_resolves?(kind, target, seen)
          return result unless result[:resolves].nil?
        end
      end
      # Names that moved collections keep a builtin-runtime entry even
      # after the source collection dropped them.
      if redirects = builtin_redirects(kind)
        if target = redirects[fqcn]?
          result = chain_resolves?(kind, target, seen)
          return result unless result[:resolves].nil?
        end
      end
      {resolves: false}
    end

    private def self.collection_leaf_file?(kind : String, dir : String, leaf : String) : Bool
      # A dotted leaf is not a file name at all: ansible-core's FQCR
      # grammar reads it as subdir segments (below the plugin-type dir)
      # plus the resource and resolves it via the collection package
      # importer - see collection_subdir_leaf_file?.
      return collection_subdir_leaf_file?(kind, dir, leaf) if leaf.includes?('.')
      # The lookup kind checks ONLY the lookup plugin directory - a
      # collection that ships a module named X does not provide a lookup
      # named X, and treating it as one would keep the bare-name
      # not-found gate from firing on real's own not-found error.
      return File.exists?(File.join(dir, "plugins", "lookup", "#{leaf}.py")) if kind == "lookup"
      return true if File.exists?(File.join(dir, "plugins", "modules", "#{leaf}.py"))
      kind == "action" && File.exists?(File.join(dir, "plugins", "action", "#{leaf}.py"))
    end

    # An FQCR may carry plugin-type SUBDIR segments
    # (`ns.coll.subdir.resource`), and ansible-core resolves one by
    # importing `ansible_collections.ns.coll.plugins.<kind>.<subdirs>` as
    # a package and looking the resource up beside it. A subdir segment
    # naming a plugin FILE (plugins/modules/subdir.py) is imported as a
    # package whose dirname is the plugin-type directory itself, so the
    # resource lookup happens in that directory: that is why
    # `community.general.locale_gen.locale_gen` resolves to
    # plugins/modules/locale_gen.py and RUNS it (live-verified against
    # ansible-core 2.21.6 - lifeofguenter.reset_locale, issue #1253,
    # where real ran the role past this task while this engine refused
    # the whole playbook at load). A segment that is neither a real
    # directory nor the LAST segment naming a plugin file kills the
    # import, and real refuses the name.
    private def self.collection_subdir_leaf_file?(kind : String, dir : String, leaf : String) : Bool
      segments = leaf.split('.')
      resource = segments.pop
      return false if segments.empty? || resource.empty?

      path = File.join(dir, "plugins", kind)
      segments.each_with_index do |segment, index|
        nested = File.join(path, segment)
        if Dir.exists?(nested)
          path = nested
          next
        end
        return false unless index == segments.size - 1 && File.exists?(File.join(path, "#{segment}.py"))
        return plugin_resource_file?(kind, path, resource)
      end
      plugin_resource_file?(kind, path, resource)
    end

    # The resource file beside a resolved subdir "package": modules load
    # extension-lessly (exact name, then a fuzzy `<resource>.*` match
    # excluding MODULE_IGNORE_EXTS), action/lookup plugins need `.py`.
    private def self.plugin_resource_file?(kind : String, dir : String, resource : String) : Bool
      exact = File.join(dir, resource)
      case kind
      when "modules"
        return true if File.exists?(exact)
        Dir.glob("#{exact}.*").sort.any? do |candidate|
          File.file?(candidate) && !MODULE_IGNORE_EXTS.any? { |ext| candidate.ends_with?(ext) }
        end
      else
        File.exists?(File.join(dir, "#{resource}.py"))
      end
    end

    # Whether real's loader resolves `name` as an FQCR whose subdir
    # segments sit below the collection's plugins/modules/ dir (see
    # collection_subdir_leaf_file?). The parser uses this to map such a
    # name onto the resource module it actually runs, so a name the
    # controller would refuse never resolves here either.
    def self.fqcr_subdir_resolves?(name : String) : Bool
      parts = name.split('.')
      return false if parts.size < 4
      return false if parts[0] == "ansible" && (parts[1] == "builtin" || parts[1] == "legacy")
      dirs = collection_dirs["#{parts[0]}.#{parts[1]}"]?
      return false unless dirs
      leaf = parts[2..].join('.')
      dirs.any? { |dir| collection_subdir_leaf_file?("modules", dir, leaf) }
    end

    # Role-private / playbook-adjacent `library/<name>` module source -
    # the same lookup PythonModuleRunner.find_source performs at run
    # time (any extension except Ansible's MODULE_IGNORE_EXTS), so the
    # parse-time refusal never fires for a module the runner would
    # actually execute.
    def self.library_module?(name : String, role_path : String?, playbook_dir : String?) : Bool
      short = name.rpartition('.')[2]
      return false if short.empty?

      roots = [] of String
      roots << File.join(role_path, "library") if role_path
      roots.concat(PythonFilterRunner.loaded_role_roots("library"))
      roots << File.join(playbook_dir, "library") if playbook_dir && !playbook_dir.empty?

      roots.each do |root|
        return true if File.file?(File.join(root, "#{short}.py"))
        return true if File.file?(File.join(root, short))
        # A dangling symlink (debops-contrib.btrfs ships library/
        # btrfs_subvolume.py -> ../submodules/..., an uninitialised git
        # submodule) is no module file: ansible-core refuses the name.
        found = Dir.glob(File.join(root, "#{short}.*")).sort.any? do |other|
          File.file?(other) && !MODULE_IGNORE_EXTS.any? { |ext| other.ends_with?(ext) }
        end
        return true if found
      end
      false
    end

    # The action-plugin analogue of library_module?: ansible resolves a
    # bare action name to a role's (or the playbook's) own
    # `action_plugins/<short>.py` at load time (issue #517:
    # gwerlas.libvirt's `warn:` handler), so the name counts as resolved
    # whenever such a file exists. Ansible's configured action dirs come
    # after every extra dir in that search (issue #793). Only `.py` files
    # count here - unlike `library/`, action plugins cannot be extensionless
    # shell scripts.
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
  end
end
