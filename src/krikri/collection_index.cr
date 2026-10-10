require "base64"
require "compress/gzip"
require "json"
require "./builtin_module_names_data"

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
    @@collection_redirects = Hash(String, Hash(String, String)?).new
    @@role_meta_collections = Hash(String, Array(String)).new

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
      @@collection_redirects.clear
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
        # No ansible-core on this controller: the baked 2.19.11 name set
        # is the truth (same reason as builtin_redirects's fallback).
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
      cache = kind == "modules" ? @@builtin_redirects : @@builtin_action_redirects
      loaded = kind == "modules" ? @@builtin_redirects_loaded : @@builtin_action_redirects_loaded
      return cache if loaded

      if kind == "modules"
        @@builtin_redirects_loaded = true
      else
        @@builtin_action_redirects_loaded = true
      end
      ansible_pkg_dirs.each do |pkg|
        path = File.join(pkg, "config", "ansible_builtin_runtime.yml")
        next unless File.file?(path)
        table = parse_runtime_redirects(path, kind)
        if kind == "modules"
          @@builtin_redirects = table
        else
          @@builtin_action_redirects = table
        end
        return table
      end
      # No ansible-core installation discoverable: fall back to the
      # BAKED-IN 2.19.11 tables (krikri replaces ansible-core on this
      # controller - its redirect truth is the same data the missing
      # package would carry; round 5440000's confirm roles ran because
      # this fallback used to return nil and every refusal degraded to
      # "unsure").
      baked_modules, baked_action = Krikri.builtin_runtime_redirects
      if kind == "modules"
        @@builtin_redirects = baked_modules
        return baked_modules
      else
        @@builtin_action_redirects = baked_action
        return baked_action
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
    # missing_collection_warning mirrors the [WARNING] ansible-core's
    # collection loader prints ahead of its refusal when resolution dies
    # on a collection that cannot be IMPORTED from any search path - the
    # full "Error loading plugin '<plugin>': No module named
    # 'ansible_collections.<ns>[.<coll>]'" line, with <plugin> the FQCN
    # being resolved at the point of death: the as-written FQCN itself,
    # or the redirect TARGET's FQCN for a bare name (live-verified vs
    # 2.19.11: bare `gc_storage:` warns about community.google.gc_storage;
    # an absent namespace warns 'ansible_collections.<ns>', an absent
    # collection inside a present namespace
    # 'ansible_collections.<ns>.<coll>'). A collection that IS installed
    # (module file merely missing) resolves far enough that real prints
    # no warning.
    alias Resolution = {resolves: Bool?, missing_collection_warning: String?}
    alias ChainResult = {resolves: Bool?, warning: String?}

    def self.controller_resolves?(name : String,
                                  task_collections : Array(String) = [] of String,
                                  role_path : String? = nil,
                                  playbook_dir : String? = nil) : Resolution
      unsure : Resolution = {resolves: nil, missing_collection_warning: nil}
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
      unsure : Resolution = {resolves: nil, missing_collection_warning: nil}
      return unsure if ns == "ansible" && (coll == "builtin" || coll == "legacy")
      fq = "#{ns}.#{coll}.#{leaf}"
      result = chain_resolves?("modules", fq, Set(String).new)
      return {resolves: true, missing_collection_warning: nil} if result[:resolves] == true
      # Module routing definitively dead: real still consults the action
      # routing before refusing (bare `ios:` resolves only through
      # cisco.ios's action plugin, live-verified vs 2.19.11). Unsure
      # module outcome stays unsure.
      return unsure unless result[:resolves] == false
      action = chain_resolves?("action", fq, Set(String).new)
      return {resolves: true, missing_collection_warning: nil} if action[:resolves] == true
      return {resolves: false, missing_collection_warning: result[:warning]} if action[:resolves] == false
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
        return {resolves: true, missing_collection_warning: nil}
      when nil
        # No ansible-core installation discoverable: krikri's own native
        # resolution is the only builtin signal available, and
        # inventing a refusal without it would be the dangerous
        # direction.
        return {resolves: nil, missing_collection_warning: nil}
      end

      if redirects = builtin_redirects("modules")
        if target = redirects[name]?
          # The warning (when the chain dies on an absent collection)
          # names the redirect TARGET, live-verified vs 2.19.11: bare
          # `gc_storage:` warns about community.google.gc_storage, not
          # about anything named gc_storage-as-plugin... the plugin name
          # in the warning IS the target FQCN.
          result = chain_resolves?("modules", target, Set(String).new)
          return {resolves: result[:resolves], missing_collection_warning: result[:warning]} unless result[:resolves].nil?
        end
      else
        # No readable runtime data at all: unsure, keep running.
        return {resolves: nil, missing_collection_warning: nil}
      end

      # Action routing: the module file is gone but an action-plugin
      # redirect still resolves the name (bare `yum:` ->
      # ansible.builtin.dnf, live-verified vs 2.19.11).
      if action_redirects = builtin_redirects("action")
        if target = action_redirects[name]?
          result = chain_resolves?("action", target, Set(String).new)
          return {resolves: result[:resolves], missing_collection_warning: nil} unless result[:resolves].nil?
        end
      end

      task_collections.each do |entry|
        next unless entry.count('.') == 1
        module_result = chain_resolves?("modules", "#{entry}.#{name}", Set(String).new)
        action_result = module_result[:resolves] == false ? chain_resolves?("action", "#{entry}.#{name}", Set(String).new) : nil
        if module_result[:resolves] == true || action_result.try(&.[:resolves]) == true
          return {resolves: true, missing_collection_warning: nil}
        end
        # a listed collection that cannot provide it is skipped, not
        # fatal - real tries the next listed collection (or the legacy
        # search path) before refusing.
      end

      return {resolves: true, missing_collection_warning: nil} if library_module?(name, role_path, playbook_dir)

      {resolves: false, missing_collection_warning: nil}
    end

    # The ImportError text ansible-core's collection loader surfaces when
    # resolution dies on a collection that cannot be imported from any
    # search root: "No module named 'ansible_collections.<ns>'" for an
    # absent namespace, '...ansible_collections.<ns>.<coll>' for an absent
    # collection inside a present namespace (live-verified vs 2.19.11).
    private def self.missing_collection_reason(namespace : String, collection : String) : String
      ns_present = collection_dirs.keys.any?(&.starts_with?("#{namespace}."))
      module_name = ns_present ? "ansible_collections.#{namespace}.#{collection}" : "ansible_collections.#{namespace}"
      "No module named '#{module_name}'"
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
    # collections, e.g. community.general.docker_service). The warning
    # travels back from the point of death: an absent collection's import
    # failure, nil for every other outcome.
    #
    # On the "action" kind a leaf counts as present when EITHER the
    # collection's action plugin file OR its module file exists - a
    # module without a dedicated action plugin still runs, through the
    # generic normal action.
    private def self.chain_resolves?(kind : String, fqcn : String, seen : Set(String)) : ChainResult
      return {resolves: nil, warning: nil} if seen.includes?(fqcn) || seen.size > MAX_REDIRECT_HOPS
      seen << fqcn

      parts = fqcn.split('.')
      return {resolves: nil, warning: nil} if parts.size < 3
      ns, coll = parts[0], parts[1]
      leaf = parts[2..].join('.')

      if ns == "ansible" && coll == "builtin"
        # Redirect target inside ansible-core itself.
        return {resolves: builtin_target?(kind, leaf), warning: nil}
      end

      if dirs = collection_dirs["#{ns}.#{coll}"]?
        return installed_collection_resolution(kind, leaf, dirs, fqcn, seen)
      end

      # Collection directory absent: the builtin runtime's FQCN redirect
      # is the only remaining chance.
      if redirects = builtin_redirects(kind)
        if target = redirects[fqcn]?
          result = chain_resolves?(kind, target, seen)
          return result unless result[:resolves].nil?
        end
        return {resolves: false, warning: "Error loading plugin '#{fqcn}': #{missing_collection_reason(ns, coll)}"}
      end
      {resolves: nil, warning: nil}
    end

    # Does ansible-core provide `leaf` under this routing kind? A module
    # file for "modules"; for "action" either the action plugin file or
    # the module file (a module without a dedicated action plugin still
    # runs through the generic normal action). nil = no ansible-core
    # installation discoverable, unsure.
    private def self.builtin_target?(kind : String, leaf : String) : Bool?
      return builtin_module?(leaf) if kind == "modules"
      case action_file = builtin_action_file?(leaf)
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
    # collection IS importable), so a refusal here carries no warning.
    private def self.installed_collection_resolution(kind : String, leaf : String, dirs : Array(String),
                                                     fqcn : String, seen : Set(String)) : ChainResult
      dirs.each do |dir|
        return {resolves: true, warning: nil} if collection_leaf_file?(kind, dir, leaf)
      end
      dirs.each do |dir|
        cache_key = "#{dir}\0#{kind}"
        redirects = @@collection_redirects[cache_key]?
        if redirects.nil? && !@@collection_redirects.has_key?(cache_key)
          redirects = collection_redirects_uncached(dir, kind)
          @@collection_redirects[cache_key] = redirects
        end
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
      {resolves: false, warning: nil}
    end

    private def self.collection_leaf_file?(kind : String, dir : String, leaf : String) : Bool
      return true if File.exists?(File.join(dir, "plugins", "modules", "#{leaf}.py"))
      kind == "action" && File.exists?(File.join(dir, "plugins", "action", "#{leaf}.py"))
    end

    # Role-private / playbook-adjacent `library/<name>` module source -
    # the same lookup PythonModuleRunner.find_source performs at run
    # time (any extension except Ansible's MODULE_IGNORE_EXTS), so the
    # parse-time refusal never fires for a module the runner would
    # actually execute.
    private def self.library_module?(name : String, role_path : String?, playbook_dir : String?) : Bool
      short = name.rpartition('.')[2]
      return false if short.empty?

      ignore_exts = [".pyc", ".pyo", ".swp", ".bak", "~", ".rpm", ".md", ".txt", ".rst", ".yaml", ".yml", ".ini"]
      roots = [] of String
      roots << File.join(role_path, "library") if role_path
      roots << File.join(playbook_dir, "library") if playbook_dir && !playbook_dir.empty?

      roots.each do |root|
        return true if File.file?(File.join(root, "#{short}.py"))
        return true if File.file?(File.join(root, short))
        found = Dir.glob(File.join(root, "#{short}.*")).sort.any? do |other|
          !ignore_exts.any? { |ext| other.ends_with?(ext) }
        end
        return true if found
      end
      false
    end
  end
end
