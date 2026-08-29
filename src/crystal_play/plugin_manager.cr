require "json"
require "base64"
require "digest/md5"
require "colorize"
require "file_utils"
require "./ssh_manager"
require "./local_executor"
require "./playbook_parser"
require "./inventory_parser"
require "./task_executor/output_routing"
require "./action_plugin_manager"
require "./timing_profile"

module CrystalPlay
  # Plugin Manager - Handles plugin execution locally or remotely
  # For remote hosts, uploads plugin binary and executes it there
  class PluginManager
    # Where plugin binaries live on the *remote* host. Deliberately
    # `/var/tmp`, not `/tmp`: several real hardening roles (konstruktoid-
    # hardening's "Start tmp.mount" task among them) mount a fresh, empty
    # systemd tmpfs over `/tmp` mid-play as part of hardening it - which
    # silently wipes out every plugin binary already uploaded there,
    # breaking every subsequent task and handler with "command not
    # found" even though `ensure_uploaded`'s cache still (correctly, as
    # far as it knows) believes they're present. Those same roles
    # generally redirect their own `$TMPDIR`/`$TMP` to `/var/tmp` for
    # exactly this reason (konstruktoid-hardening's tmp.mount task does),
    # which is survivable across a tmpfs remount the way `/tmp` isn't.
    REMOTE_PLUGIN_DIR = "/var/tmp/.crystal-play/plugins"

    # Cache of plugins already uploaded to remote hosts
    @@uploaded_plugins = Hash(String, Set(String)).new

    # OPUS_PERFORMANCE_IMPROVEMENTS.md item 6a - the safe half of "an
    # agent that outlives the run".
    #
    # A warm run's bootstrap is two round trips before any real work:
    # one `exec_script` listing the remote `.md5` files to decide what
    # needs uploading, and one fact gather. Measured with item 0's
    # profile across ten real roles, that bootstrap is 4.9% of a
    # 15-second run but **59-74% of a sub-second one** - it dominates
    # exactly the small roles that items 1-3 cannot help, because they
    # have too few tasks to batch.
    #
    # This removes the first of those two. The remote binaries already
    # persist between runs (REMOTE_PLUGIN_DIR is under /var/tmp), so the
    # listing round trip is pure re-verification of something that was
    # true when we last looked. Recording the verified md5 set on the
    # CONTROLLER lets a later run skip it.
    #
    # Deliberately NOT the systemd unit the plan describes: that would
    # install a persistent service on every managed host, which is a
    # real operational and security imposition that no amount of speed
    # justifies doing by default. Fact caching, the other half of the
    # plan's item 6, is not here either - see #facts_cacheable? for the
    # measurement showing it cannot be made airtight.
    #
    # Safety rests entirely on the recovery path: if the remote binary
    # turns out to be missing after all (a /var/tmp sweep, a rebuilt
    # host, a `tmp.mount` remount), #recover_missing_plugin! invalidates
    # this state and re-uploads. Without that this would be a
    # correctness bug, not an optimization - see its own comment.
    HOST_STATE_TTL = 24.hours

    @@host_state : Hash(String, Hash(String, String))? = nil
    @@host_state_dirty = false
    @@host_state_cache_enabled = true

    def self.host_state_cache_enabled=(value : Bool)
      @@host_state_cache_enabled = value
    end

    def self.host_state_path : String
      base = ENV["XDG_CACHE_HOME"]? || File.join(Path.home.to_s, ".cache")
      File.join(base, "crystal-ansible", "plugin-state.json")
    end

    # {host_key => {plugin_name => md5}}, plus a "_verified_at" key per
    # host carrying the epoch seconds of the last real verification.
    private def self.host_state : Hash(String, Hash(String, String))
      cached = @@host_state
      return cached if cached

      loaded = begin
        path = host_state_path
        if File.exists?(path)
          parsed = Hash(String, Hash(String, String)).from_json(File.read(path))
          parsed
        else
          Hash(String, Hash(String, String)).new
        end
      rescue
        # A corrupt or unreadable cache is never fatal - it only ever
        # means "verify the slow way this time".
        Hash(String, Hash(String, String)).new
      end

      @@host_state = loaded
    end

    # True when every *plugin_names* entry was verified present on this
    # host with exactly the md5 the local binary has now, recently
    # enough to trust. Any doubt at all returns false and the caller
    # does the full listing round trip.
    private def self.host_state_satisfies?(host_key : String, plugin_names : Array(String)) : Bool
      return false unless @@host_state_cache_enabled

      entry = host_state[host_key]?
      return false unless entry

      verified_at = entry["_verified_at"]?.try(&.to_i64?)
      return false unless verified_at
      return false if Time.utc.to_unix - verified_at > HOST_STATE_TTL.total_seconds.to_i64

      plugin_names.all? do |name|
        recorded = entry[name]?
        next false unless recorded
        recorded == cached_md5(get_local_plugin_path(name))
      end
    end

    private def self.record_host_state(host_key : String, md5s : Hash(String, String)) : Nil
      entry = host_state[host_key]? || Hash(String, String).new
      md5s.each { |name, md5| entry[name] = md5 }
      entry["_verified_at"] = Time.utc.to_unix.to_s
      host_state[host_key] = entry
      @@host_state_dirty = true
    end

    # Drops everything known about a host, so the next check verifies
    # the slow way. Called from the missing-binary recovery path.
    def self.invalidate_host_state(host_key : String) : Nil
      return unless host_state.has_key?(host_key)
      host_state.delete(host_key)
      @@host_state_dirty = true
      flush_host_state
    end

    # Written once at the end of a run (crystal-play.cr), not on every
    # mutation - this is a cache, and losing the last run's entry only
    # costs one round trip next time.
    def self.flush_host_state : Nil
      return unless @@host_state_dirty
      state = @@host_state
      return unless state

      path = host_state_path
      Dir.mkdir_p(File.dirname(path))
      File.write(path, state.to_json)
      @@host_state_dirty = false
    rescue
      # Never let a cache write failure affect the run.
    end

    # Plugins already staged to REMOTE_PLUGIN_DIR for a *local*-connection
    # become_user execution this process - see #staged_local_plugin_path.
    @@staged_local_plugins = Set(String).new

    # Digest of each *local* plugin binary, keyed by resolved local path.
    # The local file cannot change mid-run, so this is computed once per
    # binary per process instead of once per binary per host - with 44
    # plugins totalling ~100 MB, re-digesting them for every host in a
    # large inventory was the dominant cost of an otherwise no-op warm run.
    @@local_md5_cache = Hash(String, String).new

    # One entry per *distinct underlying file* seen so far (path => md5) -
    # see cached_md5's own comment for why this is separate from
    # @@local_md5_cache above, not a duplicate of it.
    @@local_md5_representatives = Hash(String, String).new

    # Verbose mode flag
    @@verbose = false

    # Resolved path of the running binary - see get_local_plugin_path.
    @@executable_path : String?

    # OPUS_PERFORMANCE_IMPROVEMENTS.md items 1-3 - opt-in only, set
    # by `--persistent-daemon` on the CLI (crystal-play.cr). Default
    # `false` means #execute_remote_plugin's behavior is byte-for-byte
    # unchanged from before this item landed - nothing here is reached
    # unless a user explicitly asks for it.
    @@daemon_enabled = false

    # Set verbose mode
    def self.verbose=(value : Bool)
      @@verbose = value
    end

    def self.daemon_enabled=(value : Bool)
      @@daemon_enabled = value
    end

    def self.daemon_enabled? : Bool
      @@daemon_enabled
    end

    # Empty, and deliberately kept rather than deleted: it is the one
    # place a module can be pulled back off the daemon path if one ever
    # needs to be.
    #
    # `facts` (gather_facts) used to be the sole entry, because it was
    # the one real remote module missing from the fat plugin binary's
    # dispatch table - a daemon request for it would only have hit the
    # generated dispatcher's "unknown plugin" fallback. That exclusion
    # cost a fresh ssh fork and remote process spawn for the one task
    # that runs on every host in every play, so
    # OPUS_PERFORMANCE_IMPROVEMENTS.md item 2 put `facts` INTO the fat
    # binary (`build.sh`'s FAT_EXTRA_MODULES) and removed it from here.
    # `debug`/`assert`/`fail`/`set_fact`/`pause` need no entry here
    # at all: `ActionPluginManager.skips_module_dispatch?` already keeps
    # every one of them from ever reaching #execute_remote_plugin in the
    # first place (verified directly - they're controller-side action
    # plugins, no target-side module dispatch ever happens for them,
    # remote or local).
    #
    # `become:` used to be excluded here unconditionally - the original
    # landing's documented scope cut. OPUS_PERFORMANCE_IMPROVEMENTS.md
    # item 1 closed it: nearly every real Galaxy role runs `become:
    # true`, so excluding it meant the single biggest measured
    # optimization in the project was switched off for the
    # overwhelming majority of tasks in the overwhelming majority of
    # real playbooks. A daemon is still one resident process running as
    # one fixed user - that part was never the problem - so a `become:`
    # task simply gets its OWN daemon, spawned through the same `sudo
    # -n -u <become_user> --` wrapper #remote_plugin_target already
    # builds for the one-shot path, keyed on become_user in
    # SSHManager's own daemon table.
    DAEMON_INELIGIBLE_PLUGINS = Set(String).new

    def self.daemon_eligible?(plugin_name : String, become : Bool) : Bool
      _ = become
      !DAEMON_INELIGIBLE_PLUGINS.includes?(simple_plugin_name(plugin_name))
    end

    # Pre-upload all plugins needed for a playbook to all remote hosts
    # This is called once before task execution begins
    # Much more efficient than uploading plugins one at a time during execution
    def self.batch_upload_plugins_for_playbook(
      playbook : Playbook,
      inventory : Inventory,
      forks : Int32 = 5,
    ) : Array(String)
      # Collect all unique module names used in the playbook
      required_plugins = Set(String).new

      # Track if any play needs facts gathering
      needs_facts = false

      playbook.plays.each do |play|
        # Check if this play gathers facts
        needs_facts = true if play.gather_facts?

        collect_required_plugins(play.tasks, required_plugins)

        # Real crash found benchmarking geerlingguy.jenkins: its own
        # "restart jenkins" handler is `include_tasks: tasks/restart.yml`
        # - a pseudo-module ("_include_tasks", no corresponding plugin
        # binary) exactly like the block:/include_tasks:/include_role:
        # cases #collect_required_plugins above already guards against
        # for regular tasks:, but this separate handlers loop had no such
        # guard at all, so it went straight to get_local_plugin_path and
        # crashed the whole process outright for any playbook with a
        # handler written this way and a real (non-local) target host.
        collect_required_plugins(play.handlers, required_plugins)
      end

      # Add facts plugin if any play needs it
      required_plugins.add("facts") if needs_facts

      return [] of String if required_plugins.empty?

      # Collect all unique remote hosts from the playbook
      remote_hosts = [] of Host
      host_keys_seen = Set(String).new

      playbook.plays.each do |play|
        hosts = inventory.get_hosts(play.hosts.to_s)

        hosts.each do |host|
          # Skip localhost. Checked against the HOST's own inventory
          # vars only, not any individual task's connection: override -
          # this pass runs once per play, before any task is even
          # looked at, aggregating every module the whole play might
          # need against every host. A play whose ONLY use of some
          # module is via a task-level `connection: local` override
          # (see Task#connection / TaskExecutor#build_vars_context)
          # still eagerly uploads that module to the real remote host
          # here, unnecessarily - harmless when the host is actually
          # reachable (the per-task dispatch still correctly runs
          # locally once execution reaches that task), but means a
          # genuinely unreachable host can hang HERE, before ever
          # reaching the task that would've run locally instead. Real-
          # world impact is low (a play targeting an unreachable host
          # generally has other, non-overridden tasks that would fail
          # identically anyway) - documented rather than fixed, since
          # correctly scoping this pass to "does EVERY use of this
          # module for this host happen under a local override" needs
          # a full pass over every play's tasks up front, not just
          # their hosts:.
          next if local_connection?(host, host.vars)

          # Deduplicate by connection details
          connection_host = get_connection_host(host, host.vars)
          host_key = "#{host.user}@#{connection_host}:#{host.port}"

          unless host_keys_seen.includes?(host_key)
            remote_hosts << host
            host_keys_seen.add(host_key)
          end
        end
      end

      return [] of String if remote_hosts.empty?

      puts "Preparing plugins for remote execution...".colorize(:cyan) if @@verbose

      plugin_list = required_plugins.to_a

      # Pre-seed every host's uploaded-plugin set and the local digest
      # cache *before* spawning anything, so each fiber below only reads
      # shared structures or writes its own disjoint key - the same
      # pre-seeding TaskExecutor#initialize does for @results/@facts.
      # Nothing here can race under cooperative scheduling anyway, but
      # pre-seeding removes the question entirely.
      remote_hosts.each do |host|
        connection_host = get_connection_host(host, host.vars)
        @@uploaded_plugins["#{host.user}@#{connection_host}:#{host.port}"] ||= Set(String).new
      end
      plugin_list.each do |plugin_name|
        cached_md5(get_local_plugin_path(plugin_name))
      end

      # Each host's uploads are entirely disjoint and order-independent,
      # so they run concurrently through the same bounded-fiber Channel
      # gate gather_facts_for_all_hosts and the --forks per-task fan-out
      # use. This loop runs before both of them and is the first thing a
      # user waits on: serially it cost one SSH round trip per host even
      # on a fully warm run.
      max_parallel = Math.min(remote_hosts.size, forks)
      max_parallel = 1 if max_parallel < 1
      gate = Channel(Nil).new(max_parallel)
      max_parallel.times { gate.send(nil) }
      done = Channel(Nil).new
      buffers = Hash(String, IO::Memory).new
      failures = Hash(String, Exception).new

      remote_hosts.each do |host|
        spawn do
          gate.receive
          buffer = IO::Memory.new
          OutputRouting.redirect_current_fiber_to(buffer)
          begin
            upload_plugins_to_host(host, plugin_list)
          rescue ex
            # Captured rather than left to propagate: an exception
            # escaping a spawned fiber takes the whole process down with
            # an "Unhandled exception in spawn" trace, and *which* host
            # reported first would depend on scheduling. Re-raised below
            # in deterministic order instead, so this still fails the run
            # exactly as the old serial loop did.
            failures[host.name] = ex
          ensure
            OutputRouting.clear_current_fiber_redirect
          end
          buffers[host.name] = buffer
        ensure
          gate.send(nil)
          done.send(nil)
        end
      end

      remote_hosts.size.times { done.receive }

      # Flushed in remote_hosts order only after every fiber has finished,
      # so concurrent hosts' progress lines never interleave.
      remote_hosts.each do |host|
        if buffer = buffers[host.name]?
          print buffer.to_s
        end
      end

      # An upload failure means the host could not be reached at all.
      # Previously this re-raised, and nothing up the call chain caught
      # it - so ONE unreachable host in an inventory killed the whole
      # process with a raw Crystal stack trace, no recap at all, and the
      # results of every reachable host were lost. Real ansible-playbook
      # reports the host UNREACHABLE!, keeps going for the others, and
      # exits 4. Returning the names lets the caller do the same.
      unreachable = [] of String
      remote_hosts.each do |host|
        next unless ex = failures[host.name]?
        unreachable << host.name
        puts %(fatal: [#{host.name}]: UNREACHABLE! => {"changed": false, "msg": "#{ex.message.to_s.lines.first?.to_s.gsub('"', "'")}", "unreachable": true}).colorize(:red)
      end

      puts "" if @@verbose
      unreachable
    end

    # Walks *tasks*, adding every real plugin module name to *required*,
    # recursing into block:/rescue:/always: nested lists so plugins used
    # only inside a block still get pre-uploaded. block?/include_tasks?/
    # include_role? tasks are pseudo-modules ("_block"/"_include_tasks"/
    # "_include_role") with no corresponding plugin binary - previously
    # added to the required set unconditionally, which crashed
    # get_local_plugin_path outright for any playbook with a block: task
    # targeting a real remote host (never caught before: every existing
    # block: fixture in this repo happens to run against a local
    # connection, which never reaches this code path at all).
    # include_tasks:/include_role: are deliberately not recursed into -
    # their contents are only known at runtime (the file/role may be
    # templated), so plugins used exclusively inside one aren't
    # pre-uploaded; a known, narrower limitation, not a regression from
    # this fix.
    private def self.collect_required_plugins(tasks : Array(Task), required : Set(String))
      tasks.each do |task|
        if task.block?
          collect_required_plugins(task.block_tasks || [] of Task, required)
          collect_required_plugins(task.rescue_tasks || [] of Task, required) if task.rescue_tasks
          collect_required_plugins(task.always_tasks || [] of Task, required) if task.always_tasks
          next
        end

        # meta: (task.meta?) is another pseudo-module ("_meta", no
        # corresponding plugin binary) alongside the others already
        # excluded here - real crash found benchmarking robertdebock's
        # own roles over a genuine remote SSH host (round 18): every
        # prior use of `meta: clear_facts` in this engine's own specs
        # ran against `localhost`, which skips this whole pre-upload
        # path entirely (remote_hosts stays empty), so "_meta" being
        # added to required_plugins here never actually got looked up
        # as a real plugin binary until a real remote host exercised it -
        # `get_local_plugin_path("_meta")` then raised outright, crashing
        # the whole run before a single task executed.
        next if task.include_tasks? || task.include_role? || task.include_vars? || task.validate_argument_spec? || task.meta?

        # unavailable_module (see Task's own doc) has no plugin binary by
        # definition - it's unconditionally skipped at run time via
        # when_passes?, so pre-uploading it would crash the same way the
        # pseudo-modules above used to: get_local_plugin_path would raise
        # "Plugin binary not found" for a module this engine never built
        # (found live benchmarking round171's robertdebock.php - apache2_
        # module - right after unavailable_module started keeping these
        # tasks instead of dropping them at parse time).
        next if task.unavailable_module

        # ansible.builtin.reboot has no plugin binary at all (see
        # TaskExecutor#execute_reboot's own comment - it can't run ON
        # the target, since the target is about to reboot). Same crash
        # shape as the "_meta"/"_include_tasks" pseudo-modules above if
        # left in required_plugins: get_local_plugin_path("reboot") would
        # raise outright the first time a real remote host used it.
        next if task.module_name == "ansible.builtin.reboot"

        # debug:/assert:/fail:/set_fact:/pause: - now controller-side
        # action plugins that always produce the whole result themselves
        # (see ActionPluginManager::CONTROLLER_ONLY_MODULES) - no module
        # ever runs, local or remote, so pre-uploading their binaries to
        # a remote host was pure waste. Their binaries stay built for
        # `--async`/manual invocation, just never added to a remote
        # host's required-plugins set.
        next if ActionPluginManager.skips_module_dispatch?(task.module_name)

        required.add(simple_plugin_name(task.module_name))
      end
    end

    # Strips the FQCN collection prefix a module name may carry
    # (`ansible.builtin.debug` -> `debug`) down to the bare name used to
    # look up both the plugin binary and the upload/full-vars predicates
    # below. Shared rather than inlined per call site (was duplicated
    # once already, in collect_required_plugins, before this extraction).
    def self.simple_plugin_name(module_name : String) : String
      module_name.sub(/^(ansible\.(builtin|legacy|posix|mysql)|community.(general|docker|mysql|postgresql|crypto|rabbitmq)|amazon\.aws)\./, "")
    end

    # Plugins that actually read the "vars" field of their config JSON -
    # everything else only ever reads the 3 connection keys BasePlugin
    # itself pulls out (ansible_connection/ansible_host/
    # ansible_ssh_private_key_file), confirmed by
    # `grep -l '@vars\[' plugins/*.cr` -> debug.cr and assert.cr only
    # (debug: `msg: "{{ var }}"` needs live lookup against the full vars
    # context; assert: `that:` conditions evaluate against it the same
    # way `when:` does). Everyone else gets a pruned config instead of
    # the full vars_context - see build_plugin_config's use of this.
    # Unreachable on the normal execution path, and kept only as the
    # explicit statement of the rule: `debug`/`assert` are the only
    # modules that read the vars context inside the plugin process, and
    # both are controller-side action plugins
    # (`ActionPluginManager::CONTROLLER_ONLY_MODULES`), so neither ever
    # reaches a module dispatch. Removing this would make
    # `build_plugin_config`'s pruning look unconditional and invite
    # someone to "simplify" it into always sending the full context.
    NEEDS_FULL_VARS = Set{"debug", "assert"}

    def self.needs_full_vars?(module_name : String) : Bool
      NEEDS_FULL_VARS.includes?(simple_plugin_name(module_name))
    end

    # Same @@local_md5_cache contract (computed once per distinct local
    # file per process), but aware that build.sh's fat plugin binary
    # means many DIFFERENT plugin names now resolve to the SAME
    # underlying file (hardlinked, see build_fat_plugin's own comment in
    # build.sh) - a naive per-path cache still re-hashes that one file
    # once per name (measured: 81 `md5sum` calls against the same ~15 MB
    # fat binary took ~1.6s real time - real, avoidable cost before any
    # SSH round trip even starts). `File.same?` (a cheap stat-based
    # device+inode comparison, no file content read) checks the small
    # set of already-seen DISTINCT files first; only a genuinely new file
    # pays the real `Digest::MD5` read.
    private def self.cached_md5(path : String) : String
      if md5 = @@local_md5_cache[path]?
        return md5
      end

      @@local_md5_representatives.each do |repr_path, repr_md5|
        if File.same?(path, repr_path)
          @@local_md5_cache[path] = repr_md5
          return repr_md5
        end
      end

      md5 = Digest::MD5.new.file(path).hexfinal
      @@local_md5_cache[path] = md5
      @@local_md5_representatives[path] = md5
      md5
    end

    # Upload a set of plugins to a specific host.
    #
    # Collapsed to 3 SSH round trips total (was 2N+1): one to mkdir +
    # dump every existing remote .md5 in one pass, one rsync/scp transfer
    # for whatever needs uploading, one to write all the new .md5 files.
    private def self.upload_plugins_to_host(host : Host, plugin_names : Array(String))
      connection_host = get_connection_host(host, host.vars)
      host_key = "#{host.user}@#{connection_host}:#{host.port}"
      user = host.user || "root"
      identity_file = host.vars["ansible_ssh_private_key_file"]?.try(&.as_s?)

      # Initialize plugin cache for this host
      @@uploaded_plugins[host_key] ||= Set(String).new

      remote_plugin_dir = REMOTE_PLUGIN_DIR

      candidates = plugin_names.reject { |name| @@uploaded_plugins[host_key].includes?(name) }
      return if candidates.empty?

      # Item 6a: a previous run already verified these exact binaries on
      # this host, so skip the listing round trip entirely. If that
      # belief turns out to be wrong, #recover_missing_plugin! catches
      # it at dispatch time and re-uploads - which is what makes this an
      # optimization rather than a correctness bug.
      if host_state_satisfies?(host_key, candidates)
        candidates.each { |name| @@uploaded_plugins[host_key].add(name) }
        return
      end

      # Round trip 1: create the dir and dump every existing remote .md5
      # in one pass, so we don't need one `cat` per plugin to check it.
      list_script = <<-SCRIPT
        mkdir -p #{remote_plugin_dir}
        for f in #{remote_plugin_dir}/*.md5; do
          [ -f "$f" ] && echo "$(basename "$f" .md5) $(cat "$f")"
        done
        true
        SCRIPT
      remote_md5s = Hash(String, String).new
      SSHManager.exec_script(connection_host, user, list_script, host.port, identity_file: identity_file)[:stdout]
        .each_line do |line|
          name, _, md5 = line.strip.partition(' ')
          remote_md5s[name] = md5 unless name.empty?
        end

      # Local digest computed exactly once per plugin *per run* (streamed,
      # not loaded fully into memory), memoized in @@local_md5_cache so a
      # second host reuses it, and reused for both the compare and the
      # eventual .md5 write.
      local_paths = Hash(String, String).new
      local_md5s = Hash(String, String).new
      candidates.each do |plugin_name|
        path = get_local_plugin_path(plugin_name)
        local_paths[plugin_name] = path
        local_md5s[plugin_name] = cached_md5(path)
      end

      plugins_to_upload = candidates.select do |plugin_name|
        remote_md5s[plugin_name]? != local_md5s[plugin_name]
      end
      (candidates - plugins_to_upload).each { |name| @@uploaded_plugins[host_key].add(name) }

      # Everything we just confirmed present is worth remembering for
      # the next run, whether or not anything needed uploading.
      verified = Hash(String, String).new
      (candidates - plugins_to_upload).each { |name| verified[name] = local_md5s[name] }
      record_host_state(host_key, verified) unless verified.empty?

      return if plugins_to_upload.empty?

      # Most of plugins_to_upload are typically hardlinks to the same
      # local fat-plugin binary (build.sh's build_fat_plugin - see
      # get_local_plugin_path, which returns whatever real path is on
      # disk for that name, hardlink or not) and therefore share an
      # identical md5. Uploading "N module names" used to mean "N
      # transfers of that same multi-MB payload" - group by md5 first so
      # only one representative name per unique md5 actually crosses the
      # wire; every other name sharing that md5 is materialized on the
      # remote side afterward (round trip 3) via a cheap same-filesystem
      # `ln`, not a second transfer.
      #
      # That alone isn't enough for a role using include_tasks:/
      # import_role: (their contents - and therefore the modules inside
      # them - are only discovered at runtime, so PluginManager.
      # ensure_uploaded gets called separately, once per newly-discovered
      # name, each its own upload_plugins_to_host call with a single-name
      # candidate list). A grouping that only looks at THIS call's own
      # candidates never learns that an earlier, separate call already
      # uploaded byte-identical content under a different name - real bug
      # found live-benchmarking willshersystems.sshd (round-independent
      # of a correctness round, found chasing a perf number): 5 separate
      # ensure_uploaded calls for one play, each re-transferring the same
      # ~9 MB fat binary under its own new name, 8 physically distinct
      # remote copies of identical content confirmed via `ls -i` (same
      # size, different inodes) - worse than the pre-fat-binary baseline
      # for exactly this role shape. Fixed by checking round trip 1's
      # FULL remote `.md5` listing (already dumps every existing name,
      # not just this call's candidates) for a content match first - a
      # name whose md5 already exists remotely under ANY name needs no
      # transfer at all, this call or any prior one.
      remote_name_by_md5 = Hash(String, String).new
      remote_md5s.each { |name, md5| remote_name_by_md5[md5] ||= name }

      by_md5 = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
      plugins_to_upload.each { |name| by_md5[local_md5s[name]] << name }

      # Groups whose content has no remote match anywhere yet - these are
      # the only ones that need a real transfer; their first name becomes
      # the source every other name (in this group, or a same-md5 group
      # with no remote match) links from.
      needs_transfer = by_md5.reject { |md5, _| remote_name_by_md5.has_key?(md5) }
      representatives = needs_transfer.map { |_, names| names.first }

      if representatives.empty?
        puts "   → All #{plugins_to_upload.size} module name(s) already present remotely under a different name - linking only, no transfer".colorize(:cyan) if @@verbose
        rsync_ok = true
      else
        # Round trip 2: transfer only the representatives that genuinely
        # need it.
        puts "   → Uploading #{representatives.size} distinct plugin binar#{representatives.size == 1 ? "y" : "ies"} (#{plugins_to_upload.size} names) to #{connection_host} via rsync".colorize(:cyan) if @@verbose

        local_plugin_paths = representatives.map { |name| local_paths[name] }
        rsync_ok = SSHManager.rsync_upload_batch(
          connection_host,
          user,
          local_plugin_paths,
          remote_plugin_dir,
          host.port,
          mode: 0o755,
          identity_file: identity_file
        )

        unless rsync_ok
          puts "   → Rsync unavailable, using scp for #{representatives.size} plugin binaries".colorize(:yellow) if @@verbose
          representatives.each do |plugin_name|
            # mode: nil - the per-file `chmod 755` this used to do was a
            # whole extra SSH round trip *per plugin* (88 of them for a
            # 44-plugin cold upload). One `chmod` for the batch is folded
            # into round trip 3 below instead.
            SSHManager.upload(
              connection_host,
              user,
              local_paths[plugin_name],
              "#{remote_plugin_dir}/#{plugin_name}",
              host.port,
              mode: nil,
              identity_file: identity_file
            )
          end
        end
      end

      # Round trip 3: materialize every non-source name from its group's
      # source - either a pre-existing remote name found above (no
      # transfer needed at all) or the freshly-uploaded representative
      # (`ln` first, since REMOTE_PLUGIN_DIR is one directory so a
      # hardlink always applies; `cp -p` only as a fallback for whatever
      # non-POSIX-hardlink edge case might exist on an unusual remote
      # filesystem) - write every name's own .md5 (so a later run's
      # remote_md5s lookup - round trip 1 above - still matches per name,
      # not just per source), plus, on the scp path, the single chmod
      # that covers everything scp just wrote (rsync already applied
      # mode 0o755 during the transfer).
      write_script = String.build do |str|
        if !rsync_ok && !representatives.empty?
          representatives.each do |plugin_name|
            str << "chmod 755 #{remote_plugin_dir}/#{plugin_name}\n"
          end
        end
        by_md5.each do |md5, names|
          source = remote_name_by_md5[md5]? || names.first
          names.each do |name|
            next if name == source
            str << "ln -f #{remote_plugin_dir}/#{source} #{remote_plugin_dir}/#{name} 2>/dev/null || cp -p #{remote_plugin_dir}/#{source} #{remote_plugin_dir}/#{name}\n"
          end
        end
        plugins_to_upload.each do |plugin_name|
          str << "echo '#{local_md5s[plugin_name]}' > #{remote_plugin_dir}/#{plugin_name}.md5\n"
        end
      end
      SSHManager.exec_script(connection_host, user, write_script, host.port, identity_file: identity_file)

      plugins_to_upload.each { |name| @@uploaded_plugins[host_key].add(name) }

      # Item 6a: freshly uploaded binaries are verified-by-construction,
      # so record them too - otherwise the run after a version bump
      # would still pay the listing round trip.
      just_uploaded = Hash(String, String).new
      plugins_to_upload.each { |name| just_uploaded[name] = local_md5s[name] }
      record_host_state(host_key, just_uploaded)

      verb = rsync_ok ? "Successfully uploaded" : "Uploaded"
      via = rsync_ok ? "" : " via scp"
      puts "   ✓ #{verb} #{representatives.size} plugin binar#{representatives.size == 1 ? "y" : "ies"} covering #{plugins_to_upload.size} module names#{via}".colorize(:green) if @@verbose
    end

    # fetch: pulls a file FROM the target TO the controller - the reverse
    # direction of every other plugin, which read/write whichever
    # filesystem they end up running on. The normal local/remote dispatch
    # below uploads a plugin binary and executes it directly ON a remote
    # target (forcing ansible_connection=local into its config so its own
    # internal filesystem calls correctly mean "the target's filesystem");
    # that's exactly backwards for fetch, which needs to run on the
    # controller and pull via BasePlugin#remote_download (SSHManager, using
    # the *original*, non-overridden host/vars) instead.
    CONTROLLER_ONLY_PLUGINS = {"fetch", "ansible.builtin.fetch"}

    # Whether *plugin_name* must run on the controller regardless of the
    # target host. Exposed so callers building a config String up front
    # (see the String entry point below) can make the same local/remote
    # decision this class makes internally, and therefore know whether
    # the payload needs `ansible_connection=local` injected.
    def self.controller_only?(plugin_name : String) : Bool
      CONTROLLER_ONLY_PLUGINS.includes?(plugin_name)
    end

    # Whether a plugin invocation actually goes over SSH: everything that
    # isn't controller-only and isn't a local connection.
    def self.remote_execution?(plugin_name : String, host : Host, vars : Hash(String, JSON::Any)) : Bool
      !controller_only?(plugin_name) && !local_connection?(host, vars)
    end

    # String-config entry point - the one the hot paths use.
    #
    # *config* must already be the exact JSON the plugin will receive on
    # stdin, including `ansible_connection=local` inside "vars" when
    # `remote_execution?` is true (TaskExecutor builds it that way, the
    # same way #prepare_batch_step already did for the batch path).
    # *become*/*become_user* must already be resolved and validated by
    # the caller via `valid_become_user?`.
    #
    # The point of taking a String: the whole variable context used to
    # make three full passes on this path - serialize in
    # build_plugin_config, parse in execute_task_once, then dup and
    # re-serialize here - purely so one key could be injected after the
    # fact. The batch path never did that; now neither does this one.
    def self.execute_plugin(
      plugin_name : String,
      config : String,
      host : Host,
      vars : Hash(String, JSON::Any),
      become : Bool,
      become_user : String?,
    ) : JSON::Any
      if remote_execution?(plugin_name, host, vars)
        execute_remote_plugin(plugin_name, config, host, vars, become, become_user)
      elsif controller_only?(plugin_name)
        # A controller-only plugin (fetch, see CONTROLLER_ONLY_PLUGINS'
        # own comment) always runs unprivileged on the controller itself,
        # regardless of the task's own become: - real Ansible's fetch
        # never needs local privilege escalation to write its own
        # download to disk; only the REMOTE read of a privileged source
        # file would need become, which fetch.cr's own remote_exec/
        # remote_download already handle by connecting as the inventory
        # user over SSH, entirely independent of this local process spawn.
        # Found live benchmarking round172's buluma.sosreport (connecting
        # as root already, so no become was even needed for the read, yet
        # the LOCAL fetch process spawn was still wrapped in `sudo -n -u
        # root --`, which fails outright with "sudo: a password is
        # required" on any controller account without passwordless sudo
        # configured for itself - unrelated to the actual remote target).
        execute_local_plugin(plugin_name, config, false, nil)
      else
        execute_local_plugin(plugin_name, config, become, become_user)
      end
    end

    # JSON::Any entry point: resolves become:/become_user: back out of the
    # config itself and injects `ansible_connection` for the remote case.
    # Retained for `__async_run`, which reads an already-serialized config
    # back from a job file and has no separate become context to pass.
    def self.execute_plugin(
      plugin_name : String,
      config : JSON::Any,
      host : Host,
      vars : Hash(String, JSON::Any),
    ) : JSON::Any
      become, become_user, become_error = resolve_become(config)
      return become_error if become_error

      if remote_execution?(plugin_name, host, vars)
        execute_remote_plugin(plugin_name, with_local_connection(config), host, vars, become, become_user)
      elsif controller_only?(plugin_name)
        # See the other execute_plugin overload's own comment.
        execute_local_plugin(plugin_name, config.to_json, false, nil)
      else
        execute_local_plugin(plugin_name, config.to_json, become, become_user)
      end
    end

    # Serializes *config* with `ansible_connection=local` forced into its
    # "vars" - once a plugin is actually running on the remote, its own
    # internal local-vs-remote logic needs to see itself as local.
    private def self.with_local_connection(config : JSON::Any) : String
      config_hash = config.as_h.dup
      if config_hash["vars"]?
        config_hash["vars"].as_h["ansible_connection"] = JSON::Any.new("local")
      else
        config_hash["vars"] = JSON::Any.new({"ansible_connection" => JSON::Any.new("local")})
      end
      JSON::Any.new(config_hash).to_json
    end

    # Execute plugin locally
    private def self.execute_local_plugin(plugin_name : String, config : String, become : Bool, become_user : String?) : JSON::Any
      TimingProfile.measure("transport.local_exec", "transport") do
        execute_local_plugin_impl(plugin_name, config, become, become_user)
      end
    end

    private def self.execute_local_plugin_impl(plugin_name : String, config : String, become : Bool, become_user : String?) : JSON::Any
      plugin_path = get_local_plugin_path(plugin_name)
      plugin_path = staged_local_plugin_path(plugin_name, plugin_path) if become && become_user

      # Execute plugin with config via stdin using Process
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      begin
        process = if become && (sudo_user = become_user)
                    # No shell involved (args passed as a real argv array,
                    # not interpolated into a command string), so
                    # become_user doesn't need shell-escaping here - unlike
                    # the remote/SSH path below, where it does.
                    Process.new(
                      "sudo",
                      ["-n", "-u", sudo_user, "--", plugin_path],
                      input: Process::Redirect::Pipe,
                      output: stdout,
                      error: stderr
                    )
                  else
                    Process.new(
                      plugin_path,
                      input: Process::Redirect::Pipe,
                      output: stdout,
                      error: stderr
                    )
                  end

        # Write config to stdin
        process.input.print(config)
        process.input.close

        process.wait
        output = stdout.to_s

        # Try to parse JSON output
        begin
          JSON.parse(output)
        rescue ex
          # Parsing failed - return error with details
          JSON.parse({
            "changed"     => false,
            "failed"      => true,
            "msg"         => "Failed to parse plugin output",
            "stdout"      => output,
            "stderr"      => stderr.to_s,
            "parse_error" => ex.message,
          }.to_json)
        end
      rescue ex
        # Execution failed
        JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Plugin execution failed: #{ex.message}",
          "stderr"  => stderr.to_s,
        }.to_json)
      end
    end

    # Execute plugin remotely (uploads if needed, then runs).
    # *config* is already the exact payload to send - see the String
    # entry point above for who is responsible for injecting
    # `ansible_connection=local` into it.
    private def self.execute_remote_plugin(
      plugin_name : String,
      config : String,
      host : Host,
      vars : Hash(String, JSON::Any),
      become : Bool,
      become_user : String?,
    ) : JSON::Any
      # Get the actual connection host (checks ansible_host)
      connection_host = get_connection_host(host, vars)

      ensure_uploaded(host, plugin_name, vars)

      # OPUS_PERFORMANCE_IMPROVEMENTS.md items 1-3: try the
      # persistent daemon connection first when opted in and eligible -
      # on ANY failure (never established, broken pipe, timed out,
      # target rebooted mid-play and the old pipe is stale) this rescues
      # and falls through to the proven per-task path below unchanged,
      # for THIS one call - see SSHManager.daemon_send's own comment for
      # why that's the entire reconnect story, not just a stopgap.
      #
      # The path handed to `daemon_send` as "where to start the daemon
      # FROM" is deliberately THIS plugin's own already-uploaded
      # hardlink (`ensure_uploaded` above just guaranteed it exists),
      # not a separate literal `.fat-plugin` name - that name is a
      # LOCAL build artifact only (`build.sh`'s own canonical filename
      # before per-module hardlinks get materialized); nothing ever
      # uploads or names a remote file that literally - confirmed live,
      # not assumed, chasing a real regression this exact mistake caused
      # (every daemon start failed against a nonexistent remote path,
      # paying a wasted SSH attempt on top of the normal per-task
      # fallback on EVERY call). Once started, the SAME daemon process
      # can dispatch ANY of the 81 fat-plugin modules regardless of
      # which hardlink name launched it - the dispatch table is compiled
      # into the binary itself, not read off the filesystem - so this
      # path only matters the very first time a host needs a daemon;
      # every later call for a DIFFERENT module on the same host reuses
      # the cached process without re-touching this argument at all.
      # OPUS_PERFORMANCE_IMPROVEMENTS.md item 1: a `become:` task uses a
      # daemon of its own, spawned as become_user - so the daemon_user
      # here is the become_user for a privileged task and nil for an
      # unprivileged one, which is exactly SSHManager's daemon key.
      # `become_user` has already been validated against
      # `valid_become_user?` by whoever resolved become for this task
      # (see #resolve_become and #remote_plugin_target's own note) -
      # required, because it is interpolated into the daemon's own ssh
      # command line the same way the one-shot target string is.
      daemon_user = become ? (become_user || "root") : nil

      if @@daemon_enabled && daemon_eligible?(plugin_name, become) &&
         !SSHManager.daemon_unavailable?(connection_host, host.user || "root", host.port, daemon_user)
        begin
          return SSHManager.daemon_send(
            connection_host,
            host.user || "root",
            host.port,
            "#{REMOTE_PLUGIN_DIR}/#{simple_plugin_name(plugin_name)}",
            simple_plugin_name(plugin_name),
            JSON.parse(config),
            identity_file: vars["ansible_ssh_private_key_file"]?.try(&.as_s?),
            become_user: daemon_user
          )
        rescue
          # Fall through to the per-task path below.
        end
      end

      target = remote_plugin_target(plugin_name, become, become_user)

      # Execute plugin remotely with config via stdin.
      #
      # HISTORICAL, and worth stating precisely because it misled a later
      # performance plan: *config* USED to embed the task's whole
      # vars_context - ansible_facts, every registered var accumulated so
      # far in the play, gathered package facts - and could reach
      # hundreds of KB deep into a long role. It no longer does.
      # `TaskExecutor#build_plugin_config` prunes the wire vars to three
      # connection keys for every module except `debug`/`assert`, and
      # those two are in `ActionPluginManager::CONTROLLER_ONLY_MODULES`,
      # so they never reach a module dispatch at all - which makes
      # `PluginManager::NEEDS_FULL_VARS` unreachable on the normal path.
      # Measured on a play including `package_facts:`, every task's
      # config is 215-242 bytes and stays flat as the context grows
      # (62 -> 65 vars, payload unchanged). See
      # OPUS_PERFORMANCE_IMPROVEMENTS.md item 4, which was written
      # against this stale comment and closed as already-satisfied.
      #
      # The execve() reasoning below is still live and still the reason
      # this path uses exec_script rather than exec - a task's PARAMS can
      # legitimately be large (copy:/template: inline their content), and
      # that has nothing to do with the vars context.
      #
      # `SSHManager.exec` builds a single `/bin/bash -c <string>` argv
      # element, so embedding config directly in that string (as this used
      # to) makes *that one argument* grow with it - and eventually blows
      # the local `ssh` process's own execve() argument-length limit
      # ("Argument list too long"), independent of anything on the remote
      # side. Found running konstruktoid-hardening's handlers late in the
      # play, after 80+ prior tasks had accumulated enough vars context to
      # cross that limit.
      #
      # `SSHManager.exec_script` (already used by the batching path -
      # BatchScript - for exactly this reason, see its own base64 + `|
      # base64 -d |` pattern) sends the script over the *SSH process's own
      # stdin* instead, which has no such limit - config size no longer
      # matters. Base64-encoded (not just single-quoted) so a `'` or
      # newline inside the JSON can't break the remote `echo` line either.
      encoded = Base64.strict_encode(config)
      script = "echo #{shell_single_quote(encoded)} | base64 -d | #{target}\n"
      result = SSHManager.exec_script(
        connection_host,
        host.user || "root",
        script,
        host.port,
        identity_file: vars["ansible_ssh_private_key_file"]?.try(&.as_s?)
      )

      interpreted = interpret_remote_result(result[:exit_code], result[:stdout], result[:stderr])

      # Item 6a's safety net. Skipping the verification round trip means
      # trusting that a binary recorded as present still IS present. It
      # might not be: /var/tmp gets swept, a host gets rebuilt behind
      # the same address, or a hardening role remounts /tmp mid-play
      # (the reason REMOTE_PLUGIN_DIR lives under /var/tmp at all).
      #
      # Rather than let that surface as an inscrutable task failure -
      # which is what happened BEFORE this item too, since nothing
      # re-uploaded mid-run either - detect it, drop the stale belief,
      # upload for real, and retry once. Bounded to a single retry so a
      # genuinely broken target still fails instead of looping.
      if missing_remote_binary?(interpreted, target)
        recover_missing_plugin!(host, plugin_name, vars)
        retry_result = SSHManager.exec_script(
          connection_host,
          host.user || "root",
          script,
          host.port,
          identity_file: vars["ansible_ssh_private_key_file"]?.try(&.as_s?)
        )
        return interpret_remote_result(retry_result[:exit_code], retry_result[:stdout], retry_result[:stderr])
      end

      interpreted
    end

    # Does this failure look like "the plugin binary is not on the
    # target"? Deliberately narrow: a real module failing normally
    # returns parseable JSON, so this only fires on the shell's own
    # "command not found"/"No such file" shapes.
    # Spec seams. The real methods stay private because nothing outside
    # this class should be making these decisions; these exist so the
    # two properties the safety argument rests on can be pinned.
    def self.missing_remote_binary_for_spec?(result : JSON::Any) : Bool
      missing_remote_binary?(result, "#{REMOTE_PLUGIN_DIR}/command")
    end

    def self.host_state_satisfies_for_spec?(host_key : String, names : Array(String)) : Bool
      host_state_satisfies?(host_key, names)
    end

    private def self.missing_remote_binary?(result : JSON::Any, target : String) : Bool
      return false unless result["failed"]?.try(&.as_bool?)

      text = "#{result["stdout"]?.try(&.as_s?)}#{result["stderr"]?.try(&.as_s?)}"
      return false if text.empty?
      return false unless text.includes?("No such file or directory") ||
                          text.includes?("command not found")

      # The message has to be about OUR binary, not about some path the
      # module itself was asked to operate on.
      text.includes?(REMOTE_PLUGIN_DIR) || target.includes?(REMOTE_PLUGIN_DIR)
    end

    # Batch-path counterpart: one invalidation, one upload covering
    # every module the group needs.
    def self.recover_missing_plugins!(host : Host, plugin_names : Array(String), vars : Hash(String, JSON::Any)) : Nil
      connection_host = get_connection_host(host, vars)
      host_key = "#{host.user}@#{connection_host}:#{host.port}"
      simple_names = plugin_names.map { |name| simple_plugin_name(name) }.uniq!

      invalidate_host_state(host_key)
      if set = @@uploaded_plugins[host_key]?
        simple_names.each { |name| set.delete(name) }
      end
      upload_plugins_to_host(host, simple_names)
    end

    private def self.recover_missing_plugin!(host : Host, plugin_name : String, vars : Hash(String, JSON::Any)) : Nil
      connection_host = get_connection_host(host, vars)
      host_key = "#{host.user}@#{connection_host}:#{host.port}"
      simple_name = simple_plugin_name(plugin_name)

      invalidate_host_state(host_key)
      @@uploaded_plugins[host_key]?.try(&.delete(simple_name))
      upload_plugins_to_host(host, [simple_name])
    end

    # Resolves a plugin's remote path (`REMOTE_PLUGIN_DIR/<simple name>`)
    # and, if `become`, wraps it in `sudo -n -u <become_user> --`.
    # Shared by the normal one-task-at-a-time remote path above and by
    # TaskExecutor's batch script generation (batching, on by default),
    # so both ways of reaching a remote plugin resolve the exact same
    # target string. `become_user` is expected to
    # already have passed `valid_become_user?` - this only formats, it
    # doesn't validate (the SSH path interpolates the result directly
    # into a shell command, unlike the local/args-array path, so
    # validation happens once, at the call site, before this is ever
    # invoked with untrusted input).
    # Uploads *plugin_name* to *host* if this run hasn't already put it
    # there. Pre-upload (batch_upload_plugins_for_playbook) covers
    # everything statically reachable from the playbook, but it cannot
    # see inside a runtime `include_tasks:`/`include_role:` - those name
    # a file that may itself be templated, so their contents are unknown
    # until they actually run. A module used *only* inside one therefore
    # reached the target with no binary present and failed with a bare
    # "REMOTE_PLUGIN_DIR/set_fact: No such file or directory",
    # which is both confusing and, for a role like dev-sec's
    # os_hardening, fatal on the first included task.
    #
    # Calling this before every remote execution makes pre-upload a pure
    # optimization rather than a correctness requirement: it is a hash
    # lookup when the plugin is already there (the overwhelmingly common
    # case, since pre-upload got it), and costs the upload round trips
    # only the first time an unforeseen module is actually needed.
    def self.ensure_uploaded(host : Host, plugin_name : String, vars : Hash(String, JSON::Any))
      simple_name = plugin_name.sub(/^(ansible\.(builtin|legacy|posix|mysql)|community.(general|docker|mysql|postgresql|crypto|rabbitmq)|amazon\.aws)\./, "")
      connection_host = get_connection_host(host, vars)
      host_key = "#{host.user}@#{connection_host}:#{host.port}"

      return if @@uploaded_plugins[host_key]?.try(&.includes?(simple_name))

      upload_plugins_to_host(host, [simple_name])
    end

    # Single-quotes *str* for shell embedding, escaping any embedded
    # single quote - str here is always our own base64 output (alphabet
    # `[A-Za-z0-9+/=]`, never contains a quote), so this is belt-and-
    # suspenders, not load-bearing, but cheap enough to keep unconditional.
    # Same helper as BatchScript's own private copy (kept separate rather
    # than shared - this class doesn't otherwise depend on BatchScript).
    private def self.shell_single_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end

    def self.remote_plugin_target(plugin_name : String, become : Bool, become_user : String?) : String
      simple_name = plugin_name.sub(/^(ansible\.(builtin|legacy|posix|mysql)|community.(general|docker|mysql|postgresql|crypto|rabbitmq)|amazon\.aws)\./, "")
      remote_plugin_path = "#{REMOTE_PLUGIN_DIR}/#{simple_name}"
      become ? "sudo -n -u #{become_user} -- #{remote_plugin_path}" : remote_plugin_path
    end

    # Same become_user allow-list `resolve_become` already enforces,
    # exposed for TaskExecutor's batch path (item 3), which resolves
    # become/become_user per task itself (from Task#become/#become_user,
    # already substituted the same way the non-batched path does) rather
    # than going through the config-JSON-embedded fields resolve_become
    # reads. One shared regex, two call sites, no risk of the two
    # diverging.
    def self.valid_become_user?(user : String) : Bool
      !!user.match(/\A[a-zA-Z_][a-zA-Z0-9_.-]{0,31}\z/)
    end

    # Same interpretation `execute_remote_plugin` already applies to a
    # single task's raw SSH result - exit code wins first (a nonzero exit
    # means the plugin crashed or couldn't run at all, so its stdout, if
    # any, isn't trustworthy JSON), otherwise the plugin's own stdout is
    # parsed as its authoritative result. Exposed so TaskExecutor's batch
    # path (item 3) interprets each step's captured result exactly the
    # same way, instead of re-deriving this logic.
    def self.interpret_remote_result(exit_code : Int32, stdout : String, stderr : String) : JSON::Any
      if exit_code != 0
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Plugin execution failed on remote",
          "stdout"  => stdout,
          "stderr"  => stderr,
        }.to_json)
      end

      begin
        JSON.parse(stdout)
      rescue
        JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Failed to parse plugin output from remote",
          "stdout"  => stdout,
          "stderr"  => stderr,
        }.to_json)
      end
    end

    # Reads become:/become_user: back out of the config JSON (embedded by
    # TaskExecutor#build_plugin_config) and validates become_user, since
    # both execute_local_plugin and execute_remote_plugin need the same
    # become/become_user/error-or-nil triple. Defaults become_user to
    # "root" when become: is set but become_user: wasn't given, matching
    # real Ansible's own default.
    #
    # No become password support (`ansible_become_pass`/
    # `--ask-become-pass`) - sudo always runs with `-n` (non-interactive),
    # so a become_user that needs a password to sudo to fails clearly
    # rather than hanging on a prompt nothing can ever answer. A
    # documented scope cut, not an oversight - matches how `pause:` also
    # has no real interactive-prompt model in this codebase.
    private def self.resolve_become(config : JSON::Any) : {Bool, String?, JSON::Any?}
      become = config["become"]?.try(&.as_s?) == "true"
      return {false, nil, nil} unless become

      become_user = config["become_user"]?.try(&.as_s?)
      become_user = "root" if become_user.nil? || become_user.empty?

      # Interpolated directly into a shell command on the remote/SSH path
      # (SSHManager always runs the whole command through `bash -c`, so
      # there's no args-array primitive to sidestep quoting with there) -
      # a strict allow-list is a real security boundary here, not just a
      # sanity check, so it's enforced for both paths uniformly rather
      # than only where it's strictly required.
      unless valid_become_user?(become_user)
        error = JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "become_user #{become_user.inspect} is not a valid username",
        }.to_json)
        return {true, nil, error}
      end

      {true, become_user, nil}
    end

    # Get local plugin path (compiled binary)
    private def self.get_local_plugin_path(plugin_name : String) : String
      # Strip FQCN to get simple plugin filename
      simple_name = plugin_name.sub(/^(ansible\.(builtin|legacy|posix|mysql)|community.(general|docker|mysql|postgresql|crypto|rabbitmq)|amazon\.aws)\./, "")

      # Resolve plugins/ next to the running binary itself, not relative to
      # the current working directory - otherwise crystal-ansible could
      # only ever be invoked from inside its own checkout (`cd
      # /path/to/crystal-ansible && ./bin/crystal-ansible playbook.yml`),
      # unlike real ansible-playbook, which can run from anywhere.
      # Memoized: this is a readlink("/proc/self/exe") syscall, and it
      # resolves a path that cannot change for the life of the process,
      # yet it was paid on every single plugin resolution.
      if executable = (@@executable_path ||= Process.executable_path)
        compiled = File.join(File.dirname(executable), "plugins", simple_name)
        return compiled if File.exists?(compiled)
      end

      # Fall back to a cwd-relative lookup (e.g. `crystal run` in dev,
      # where there's no real installed binary to resolve a sibling from).
      compiled = "./bin/plugins/#{simple_name}"
      return compiled if File.exists?(compiled)

      raise "Plugin binary not found: #{plugin_name} (looked for #{compiled})"
    end

    # Stages *source_path* (the compiled plugin binary, resolved next to
    # crystal-ansible's own executable) into the world-traversable
    # REMOTE_PLUGIN_DIR before a local-connection `become_user:` exec.
    #
    # Real Ansible never executes its own module files in place - it
    # always copies them to a tmp location the target user can reach
    # first. execute_local_plugin previously always ran the compiled
    # binary straight from wherever crystal-ansible itself was installed
    # - fine when become_user is the invoking user, but broken the
    # moment crystal-ansible lives under a directory that become_user
    # can't traverse (a root-owned install dir like /root/... is a
    # common real-world case for anything run as root). Found
    # benchmarking geerlingguy.solr's own "Ensure core configuration
    # directories exist." task (become_user: solr, crystal-ansible
    # installed under /root/crystal-ansible-bin): `sudo: Sorry, user
    # root is not allowed to execute '/root/.../plugins/command' as
    # solr` - not actually a sudoers policy denial (`sudo -n -u solr --
    # /bin/echo hi` worked fine on the same host), but a plain EACCES
    # from execve needing +x on every path component including /root
    # itself (mode 0700) - sudo's own error text doesn't distinguish
    # that from a real policy denial, so it read like one.
    #
    # Copies once per plugin per process (mirrors upload_plugins_to_
    # host's own memoization for the SSH path) - the local binary can't
    # change mid-run.
    private def self.staged_local_plugin_path(plugin_name : String, source_path : String) : String
      staged_path = File.join(REMOTE_PLUGIN_DIR, File.basename(source_path))
      return staged_path if @@staged_local_plugins.includes?(plugin_name)

      Dir.mkdir_p(REMOTE_PLUGIN_DIR)
      File.chmod(File.dirname(REMOTE_PLUGIN_DIR), 0o755)
      File.chmod(REMOTE_PLUGIN_DIR, 0o755)
      FileUtils.cp(source_path, staged_path)
      File.chmod(staged_path, 0o755)
      @@staged_local_plugins << plugin_name
      staged_path
    end

    # Check if connection is local. Public - TaskExecutor's batch path
    # (item 3) needs the same local/remote decision execute_plugin
    # already makes internally, before deciding whether batching even
    # applies to a given host.
    def self.local_connection?(host : Host, vars : Hash(String, JSON::Any)) : Bool
      # The host's OWN connection setting wins first. On a delegate_to:
      # task, `vars` here is the vars_context of the host the task would
      # otherwise have run on (build_vars_context injects
      # ansible_connection="ssh" into every non-local origin host's
      # context), NOT the delegated target's - so the passed vars must
      # never override the target host's own inventory setting. Found via
      # cloudalchemy.node_exporter (round 195): its get_url tasks use
      # `delegate_to: localhost`; the origin host's injected "ssh" won
      # the vars-first check, the local-connection decision went remote,
      # and the engine crashed with an unhandled "ssh: connect to host
      # localhost port 22: Connection refused" trying to upload the
      # get_url plugin binary to the controller as if it were a remote
      # target - where real Ansible runs the task locally and rc=0s.
      if conn = host.vars["ansible_connection"]?
        return conn.as_s? == "local"
      end

      # Check if host is localhost - "127.0.0.1" is real Ansible's other
      # well-known spelling for the controller itself (`delegate_to:
      # 127.0.0.1` is a common idiom for a controller-side task,
      # ansible-community.ansible-vault's own local package download/
      # unarchive tasks all use it) and is treated identically to
      # "localhost" - without this, a delegated task tried to SSH-upload
      # plugin binaries to "127.0.0.1" as if it were a genuine remote
      # target, which needs actual SSH access to itself and isn't what
      # `delegate_to: 127.0.0.1` means at all.
      return true if host.name == "localhost" || host.name == "127.0.0.1"

      # Fall back to the passed vars - for the same-host (non-delegate)
      # case this is the host's own merged context (inventory-set
      # ansible_connection, or the "ssh" default build_vars_context
      # injects), for a delegate it correctly loses to the checks above.
      if conn = vars["ansible_connection"]?
        return conn.as_s? == "local"
      end

      false
    end

    # Get the actual hostname to connect to (checks ansible_host
    # variable). Public - TaskExecutor's batch path needs this to know
    # which host to run the batch script against, same as the
    # non-batched remote path above.
    def self.get_connection_host(host : Host, vars : Hash(String, JSON::Any)) : String
      # Check for ansible_host variable (overrides inventory hostname)
      if ansible_host = vars["ansible_host"]?
        return ansible_host.as_s
      end

      # Fall back to inventory hostname
      host.name
    end

    # Clear uploaded plugins cache (for testing)
    def self.clear_cache
      @@uploaded_plugins.clear
      @@local_md5_cache.clear
      @@local_md5_representatives.clear
      @@host_state = nil
      @@host_state_dirty = false
    end
  end
end
