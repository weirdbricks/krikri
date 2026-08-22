require "json"
require "colorize"
require "digest/md5"
require "../playbook_parser"
require "../variable_substitutor"
require "../plugin_manager"
require "../conditional_evaluator"
require "./variable_context"
require "./result_display"
require "./handler_runner"
require "./output_routing"
require "../action_plugin_manager"
require "../inventory_parser"
require "../async_jobs"
require "../task_batcher"
require "../batch_script"
require "../ssh_manager"
require "../custom_stats"
require "random/secure"

module CrystalPlay
  # TaskExecutor - Executes tasks on hosts
  # Orchestrates task execution, variable substitution, and handler management
  class TaskExecutor
    property hosts : Array(Host)
    property tasks : Array(Task)
    property handlers : Array(Task)
    property check_mode : Bool
    property diff_mode : Bool
    property play_vars : Hash(String, JSON::Any)
    property gather_facts : Bool
    
    # Track results for recap
    getter results : Hash(String, Hash(String, Int32))
    # Track registered variables per host
    @registered_vars : Hash(String, Hash(String, JSON::Any))
    # Handler runner
    @handler_runner : HandlerRunner
    # Facts per host
    @facts : Hash(String, Hash(String, JSON::Any))
    # The "ansible_facts.*" dict form of @facts[host.name] (unprefixed
    # keys - `os_family` alongside the flat `ansible_os_family`), memoized
    # per host so build_vars_context doesn't re-walk every fact on every
    # single task - see facts_dict_for's own comment for the invalidation
    # contract this depends on.
    @facts_dict_cache = Hash(String, Hash(String, JSON::Any)).new
    # build_hostvars/build_groups are rebuilt on every #build_vars_context
    # call (once per task per host) and each rebuild walks the WHOLE
    # inventory, unlike facts_dict_for's per-host cost - quadratic in host
    # count (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #16, measured 14x
    # at 30 hosts). Shared generation counter (not a per-host cache like
    # facts_dict_cache above, since both methods build one whole-inventory
    # result per call, not a per-host slice) bumped at every mutation site
    # of the 3 real inputs: @facts (same 3 sites facts_dict_for already
    # tracks), @registered_vars (every register: write), and @inventory
    # (meta: refresh_inventory's reload_from!). build_groups only actually
    # depends on the inventory input, but shares the same counter per the
    # item's own writeup - cheaper to keep correct than two separate ones.
    @hv_generation = 0
    @hostvars_cache : Hash(String, JSON::Any)? = nil
    @hostvars_cache_generation = -1
    @groups_cache : Hash(String, JSON::Any)? = nil
    @groups_cache_generation = -1
    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #1: #build_vars_context
    # rebuilds its ENTIRE ~150-entry context from scratch on every single
    # (task, host) pair - most of that work is re-merging inputs that are
    # constant across every task run against a given host within this
    # play (@play_vars never changes after construction; host.vars never
    # mutates mid-play; @registered_vars/@included_vars/@facts change
    # only through the small set of mutation sites already audited for
    # @hv_generation above and facts_dict_for's own comment). Only
    # task.role_defaults/role_vars/task.vars and a handful of per-task
    # magic vars (role_name, connection:, ...) genuinely vary per call.
    #
    # Two per-host caches, not one, because the host-invariant inputs
    # don't sit contiguously in the real precedence order - task.vars
    # (per-task) has to land BETWEEN registered_vars and included_vars/
    # facts, not after all of them, or a real key collision would flip
    # priority (see #build_vars_context's own comment for why this
    # split exists and the exact real order it preserves). Both keyed by
    # host_name + @hv_generation, the SAME counter #build_hostvars/
    # #build_groups already use above - deliberately reused rather than
    # a separate one: it already gets bumped at every real mutation site
    # of @registered_vars/@facts (this cache's own inputs too), and one
    # more site (#execute_include_vars, the only @included_vars writer)
    # was added to cover this cache's one genuinely new input. A shared
    # counter over-invalidates slightly (an include_vars: write also
    # drops the registered_vars-only half), which is the same accepted
    # tradeoff #16's own writeup already made for build_groups.
    @base_context_a_cache = Hash(String, Hash(String, JSON::Any)).new
    @base_context_a_generation = Hash(String, Int32).new
    @base_context_b_cache = Hash(String, Hash(String, JSON::Any)).new
    @base_context_b_generation = Hash(String, Int32).new
    # Hosts that hit a failed task without ignore_errors: further tasks in
    # the play are skipped for them (Ansible's default "a failure aborts
    # the rest of the play for that host" behavior). Public - crystal-
    # play.cr reads this after #run to carry a failed host forward and
    # exclude it from every *remaining* play in the whole run too, not
    # just the rest of this one (real Ansible's actual behavior; see
    # git log's `0.9.61`-found, `0.9.64`-fixed cross-cutting engine
    # gap commit).
    getter halted_hosts : Set(String)
    # Subset of halted_hosts that got there via a CLEAN meta: end_host/
    # end_play, not a real task failure. Real Ansible's own semantics:
    # "causes the play to end WITHOUT FAILING the host(s)" - such a host
    # must still be excluded from the REST OF THIS PLAY (the existing
    # halted_hosts mechanism already does that for free, including
    # correctly propagating out of block:/rescue:/always: nesting and
    # suppressing its own pending notified handlers - both verified
    # against real ansible-playbook to behave identically to a real
    # failure for THIS play), but must NOT be treated as a failure by
    # crystal-play.cr's cross-play carry-forward (permanently_failed_
    # hosts) or count toward the run's overall failed/exit-code status.
    getter ended_hosts : Set(String)
    # Hosts a real failure halted in this play whose error state was
    # since cleared via meta: clear_host_errors. Real Ansible's own
    # documented semantics: "makes them available for targeting in
    # subsequent plays, but not continue execution in the current
    # play" - so, unlike ended_hosts, these stay in halted_hosts (the
    # current play still stops for them) but are excluded from
    # crystal-play.cr's cross-play carry-forward the same way.
    getter cleared_error_hosts : Set(String)
    # Full inventory, used to resolve delegate_to: targets that aren't
    # necessarily in this play's own host list (e.g. "localhost" when the
    # play targets a remote group). Optional - a caller that doesn't pass
    # one (or a delegate_to: target it can't find) falls back to a bare
    # Host constructed from the target name, same as Inventory#get_hosts's
    # own implicit-localhost behavior.
    @inventory : Inventory?
    # Path/script the current @inventory was parsed from - needed only by
    # meta: refresh_inventory, to know what to re-parse. Optional the
    # same way @inventory is: the `ansible` ad-hoc CLI's own TaskExecutor
    # never passes one (a single synthetic task, no plays to refresh
    # between), so refresh_inventory there is a documented no-op rather
    # than a crash.
    @inventory_path : String?
    # Batches consecutive independent tasks bound for the same remote
    # host into a single SSH round trip instead of one round trip per
    # task - default on since 0.9.63; --no-batching opts out. See
    # TaskBatcher for the batchability predicate and git log's
    # `0.9.61`/`0.9.62`/`0.9.63` commits for the design, hardening pass,
    # and the correctness/timing verification behind the default flip.
    @batching_enabled : Bool
    # Maps a task to the full group (including itself) TaskBatcher.plan
    # assigned it to - only populated for groups of size >= 2 (a size-1
    # "group" behaves identically to no entry at all: the normal
    # one-task-at-a-time path). Computed lazily per flat task list
    # (a play's top-level tasks, or one block's nested list) the first
    # time that list is iterated - see `ensure_grouped`.
    @task_group : Hash(Task, Array(Task))
    # Which flat task lists (by Array#object_id) have already been
    # planned, so `ensure_grouped` doesn't replan a block's own list on
    # every visit (loops, multiple hosts, etc.) - purely a memoization
    # concern, not a correctness one; replanning would just recompute the
    # exact same groups.
    @grouped_lists : Set(UInt64)
    # {host name, group object_id} for every batch group already executed
    # on that host. Separate from @batch_cache so cache entries can be
    # evicted as they are consumed without a later group member mistaking
    # the empty cache for "not yet run" - see try_batched_result.
    @batch_groups_run : Set({String, UInt64})
    # Variables loaded by include_vars:, per host. Kept separate from
    # @facts so they don't leak into the `ansible_facts` dict, and applied
    # after VariableContext.build but before facts, so a set_fact: still
    # wins - matching include_vars sitting below set_fact in real
    # Ansible's precedence ladder.
    @included_vars : Hash(String, Hash(String, JSON::Any))
    # Per host, per task: the result already fetched via a batch's single
    # SSH round trip (nil = that task's when: was false, already handled
    # - see `execute_batch_group`), consumed lazily as the task-major
    # loop naturally reaches each task, exactly where it would have
    # called execute_task_once for it otherwise. This is what lets
    # register:/notify:/changed_when:/stats/halt bookkeeping stay
    # completely unmodified by batching - only the transport that fills
    # this cache changes.
    #
    # Each entry also carries the vars_context that was built to prepare
    # that task's batch step, so `execute_task` can reuse it instead of
    # calling build_vars_context again when it reaches the same task -
    # otherwise every batched task pays for that construction twice.
    @batch_cache : Hash(String, Hash(Task, {JSON::Any?, Hash(String, JSON::Any)}))
    # Max hosts run concurrently per task via the --forks flag; defaults
    # to 5, matching real ansible-playbook's own default (--forks 1
    # restores the original one-host-at-a-time behavior). Only tasks
    # `task_forkable?` allows actually fan out - run_once:/block:/
    # include_role: (and a non-looped include_tasks:, batched by its own
    # execute_include_tasks_multi path instead) always run one host at a
    # time regardless of this value. A *looped* include_tasks: IS
    # forkable. See `run_task_for_hosts_in_parallel`.
    @forks : Int32
    # True for the `ansible` ad-hoc CLI (as opposed to `crystal-ansible`
    # running a playbook): suppresses the playbook-style "TASK [...]"
    # banner (ad-hoc has no task name to show - it's always exactly one
    # synthetic task) and switches finish_single_task's result display
    # to ResultDisplay.display_adhoc_result, matching real ansible's own
    # `host | SUCCESS => {...}` minimal-callback output instead of
    # ansible-playbook's `ok: [host]`.
    @adhoc : Bool
    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #22: one persistent
    # worker fiber per host, created lazily on first need, lives for
    # the executor's lifetime. Each worker loops receiving
    # `WorkMessage`s (task + host + per-call results/done_signal/gate),
    # executes the task against that host, writes the result, and
    # signals done. Eliminates the spawn-per-task fiber churn the old
    # `run_task_for_hosts_in_parallel` / `gather_facts_for_all_hosts`
    # patterns paid: 100 hosts x 100 tasks used to be 10,000 spawn/destroy
    # cycles, now one spawn per host (100 total).
    #
    # No explicit cleanup: workers loop on `receive` for the executor's
    # lifetime and are killed when the process exits. Crystal's runtime
    # reaps them. Safe here because crystal-ansible is a CLI tool (one
    # process per play invocation) - if it ever becomes a long-running
    # server, this would need explicit shutdown signaling.
    @host_worker_pool : Hash(String, Channel(WorkMessage)) = {} of String => Channel(WorkMessage)

    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #22: message payload
    # sent through each host's persistent worker channel. A class (not
    # a record) because the worker mutates state via the shared
    # `results` and `done_signal` references - both are reference types,
    # so even though the message itself is passed by value through the
    # Channel, the inner references are shared with the dispatcher's
    # own copies, which is exactly the sync we want.
    private class WorkMessage
      getter task : Task
      getter host : Host
      getter results : Hash(String, IO::Memory)
      getter done_signal : Channel(Nil)
      getter gate : Channel(Nil)

      def initialize(@task : Task, @host : Host, @results : Hash(String, IO::Memory), @done_signal : Channel(Nil), @gate : Channel(Nil))
      end
    end

    def initialize(
      @hosts,
      @tasks,
      @handlers = [] of Task,
      @check_mode = false,
      @diff_mode = false,
      @play_vars = {} of String => JSON::Any,
      @gather_facts = true,
      @inventory = nil,
      @inventory_path = nil,
      @batching_enabled = true,
      @forks = 5,
      @smart_gathering = false,
      fact_store : Hash(String, Hash(String, JSON::Any))? = nil,
      @adhoc = false
    )
      @results = Hash(String, Hash(String, Int32)).new
      @registered_vars = Hash(String, Hash(String, JSON::Any)).new
      # Under --gathering smart the caller owns a single run-scoped store
      # and hands the same one to every play's executor, so facts gathered
      # in play 1 are still there in play 4. With no store passed (the
      # default), this is per-play exactly as before.
      @facts = fact_store || Hash(String, Hash(String, JSON::Any)).new
      @halted_hosts = Set(String).new
      @ended_hosts = Set(String).new
      @cleared_error_hosts = Set(String).new
      @task_group = Hash(Task, Array(Task)).new
      @grouped_lists = Set(UInt64).new
      @batch_cache = Hash(String, Hash(Task, {JSON::Any?, Hash(String, JSON::Any)})).new
      @batch_groups_run = Set({String, UInt64}).new
      @included_vars = Hash(String, Hash(String, JSON::Any)).new

      @hosts.each do |host|
        @results[host.name] = {
          "ok"      => 0,
          "changed" => 0,
          "failed"  => 0,
          "skipped" => 0,
          "rescued" => 0,
          "ignored" => 0,
        }
        @registered_vars[host.name] = {} of String => JSON::Any
        # ||=, not =: a shared run-scoped store may already hold this
        # host's facts from an earlier play, and pre-seeding must not
        # wipe them. Registered vars deliberately stay per-play.
        @facts[host.name] ||= {} of String => JSON::Any
      end
      
      # Initialize handler runner
      @handler_runner = HandlerRunner.new(@handlers, @hosts)
    end
    
    # Main execution loop
    def run
      # Gather facts if enabled
      if @gather_facts
        gather_facts_for_all_hosts
      end

      run_task_batch(@tasks, @hosts)

      # Run handlers at the end of all tasks (Ansible behavior)
      run_handlers
    end

    # Whether *task* can safely fan out across hosts via --forks. Excluded:
    # run_once: (needs @hosts.first to have actually finished before other
    # hosts can copy its register via copy_run_once_register - a real
    # ordering dependency, not just a data-race concern), block?/
    # include_role? (recurse into their own nested task lists and
    # ensure_grouped calls via run_task_batch - kept serial to sidestep any
    # question of concurrent re-entrancy into the batching planner), and
    # the non-looped include_tasks? case (handled by its own
    # execute_include_tasks_multi path in run_task_batch before this is
    # ever consulted).
    #
    # A *looped* include_tasks: (task_has_loop? true - e.g. robertdebock.
    # users' "Loop over users_groups") IS allowed through here: each host's
    # execute_task -> execute_include_tasks call re-parses its own fresh
    # `included_tasks` Task array (no shared object with any other host's
    # fiber) and only ever touches per-host keys of hashes pre-seeded with
    # every host's key in #initialize - the same safety argument
    # run_task_for_hosts_in_parallel's own docs make for plain tasks. The
    # one shared mutable state a nested run_task_list/ensure_grouped call
    # touches is @task_group/@grouped_lists, keyed by each per-host task
    # list's own object_id, so concurrent hosts never collide on the same
    # key; TaskBatcher.plan itself does no I/O, so a fiber never yields
    # mid-mutation. Before this, a looped include_tasks: ran every whole
    # host's full loop serially before the next host started - the same
    # one-host-at-a-time bug round 37 (0.9.383) fixed for the non-looped
    # case, just never extended to this narrower, rarer shape.
    private def task_forkable?(task : Task) : Bool
      return false if task.run_once
      return false if task.block?
      return false if task.include_tasks? && !task_has_loop?(task)
      return false if task.include_role?
      true
    end

    # True if *task* has ANY loop source configured (loop:/with_items:/
    # with_dict:/with_fileglob:/with_first_found:/with_flattened:/
    # with_subelements:/etc), regardless of whether it can be resolved
    # yet. Used to keep a looped `include_tasks:` (rare - e.g.
    # robertdebock.users' own "Loop over users_groups") off
    # execute_include_tasks_multi below, which doesn't attempt to thread a
    # per-item `item` binding across a host group - it still goes through
    # execute_include_tasks's own single-host per-iteration loop, just now
    # fanned out across hosts concurrently via task_forkable? instead of
    # one whole host's loop finishing before the next host starts.
    private def task_has_loop?(task : Task) : Bool
      !task.loop_items.nil? || !task.loop_fileglob.nil? || !task.loop_first_found.nil? ||
        !task.loop_template.nil? || !task.loop_flattened.nil? || !task.loop_subelements_list.nil?
    end

    # Runs *tasks* against *hosts* as one shared batch: one "TASK [...]"
    # banner per task, fanned out across every currently-active host via
    # the same forkable/parallel path #run always used at the top level -
    # not resolved and re-run host-by-host in full serial passes. This is
    # the single engine behind both the play's own top-level task list
    # AND any nested list reached via include_tasks:/block:/rescue:/
    # always: (previously two different code paths: the top-level loop
    # here, and the single-host-only run_task_list/execute_include_tasks/
    # execute_block trio below, still kept as-is and still used for the
    # narrower cases this method defers to them for - a looped
    # include_tasks:, or any task reached via some other single-host
    # call site).
    #
    # Real bug found benchmarking a real 2-node geerlingguy.kubernetes
    # cluster bring-up (round 37, 0.9.383): geerlingguy.containerd/
    # geerlingguy.kubernetes both gate their OS-family setup via
    # `include_tasks: setup-Debian.yml` - an extremely common Ansible
    # idiom, not specific to these two roles. Every task previously
    # reached through execute_include_tasks's single-host run_task_list
    # ran against host 1 *to completion*, then host 2 *to completion*,
    # serially - never overlapping their SSH round trips or remote
    # command time despite `--forks` otherwise being available, because
    # include_tasks: itself was excluded from task_forkable? and the
    # tasks reached through it were dispatched one whole host at a time
    # regardless. Measured as a consistent ~1.8x cold-run wall-time
    # regression on a real 2-host cluster playbook (apt installs,
    # kubeadm image pulls) across two independent host pairs
    # (247.4s/252.1s vs a stable ~137s/135s for real ansible-playbook on
    # the same playbook) - not host-to-host jitter, since both engines'
    # own repeated measurements were reproducible within ~2%.
    private def run_task_batch(tasks : Array(Task), hosts : Array(Host))
      ensure_grouped(tasks)

      tasks.each do |task|
        active_hosts = hosts.reject { |host| @halted_hosts.includes?(host.name) }

        if task.block? && !active_hosts.empty?
          execute_block_multi(task, active_hosts)
          next
        end

        if task.include_tasks? && !task_has_loop?(task) && !active_hosts.empty?
          execute_include_tasks_multi(task, active_hosts)
          next
        end

        # The banner prints once per task, not per host - real Ansible's
        # own convention - so a templated name is rendered against
        # whichever host will actually run first (matches this file's
        # existing `run_once`-style "first host" precedent elsewhere).
        unless @adhoc
          display_host = active_hosts.first? || hosts.first
          puts "TASK [#{render_task_name_for_display(task, display_host)}]".colorize(:white).bold
          puts "*" * 70
        end

        if @forks > 1 && task_forkable?(task) && active_hosts.size > 1
          run_task_for_hosts_in_parallel(task, active_hosts)
        else
          active_hosts.each { |host| execute_task(task, host) }
        end

        puts "" unless @adhoc
      end
    end

    # Splits *hosts* by *task*'s own when: (true unless a when: is
    # actually present - matches ConditionalEvaluator's own default).
    # Shared by execute_block_multi and execute_include_tasks_multi,
    # both of which need to separate hosts that skip the whole nested
    # list from ones that actually run it before batching the latter.
    private def partition_by_when(task : Task, hosts : Array(Host)) : {Array(Host), Array(Host)}
      return {hosts, [] of Host} unless when_condition = task.when_condition

      run_hosts = [] of Host
      skip_hosts = [] of Host
      hosts.each do |host|
        vars_context = build_vars_context(task, host)
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        if ConditionalEvaluator.evaluate(substitutor.substitute(when_condition), vars_context)
          run_hosts << host
        else
          skip_hosts << host
        end
      end
      {run_hosts, skip_hosts}
    end

    # Multi-host counterpart to execute_block: batches block_tasks/
    # rescue_tasks/always_tasks across every host in *hosts* at once via
    # run_task_batch, instead of running the whole block one host at a
    # time. Per-host bookkeeping (failed/rescued counts, @halted_hosts)
    # mirrors execute_block's own single-host logic exactly, just driven
    # off host sets instead of one host.
    private def execute_block_multi(task : Task, hosts : Array(Host))
      run_hosts, skip_hosts = partition_by_when(task, hosts)

      skip_hosts.each do |host|
        # A block's when: is inherited by every task inside block: and
        # always: (verified against real ansible-playbook) - rescue: is
        # left alone since it only ever runs if the block itself
        # actually failed, which can't happen when it never ran at all.
        print_skipped_tasks(task.block_tasks || [] of Task, host)
        print_skipped_tasks(task.always_tasks || [] of Task, host)
      end
      return if run_hosts.empty?

      failed_before = Hash(String, Int32).new
      run_hosts.each { |host| failed_before[host.name] = @results[host.name]["failed"] }
      # Same block-level notify: tracking as execute_block's own
      # changed_before - see that method's comment.
      changed_before = Hash(String, Int32).new
      run_hosts.each { |host| changed_before[host.name] = @results[host.name]["changed"] }

      propagate_role_context(task, task.block_tasks || [] of Task)
      run_task_batch(task.block_tasks || [] of Task, run_hosts)

      block_failed = Hash(String, Bool).new
      run_hosts.each { |host| block_failed[host.name] = @halted_hosts.includes?(host.name) }

      if (rescue_tasks = task.rescue_tasks) && block_failed.any? { |_, failed| failed }
        rescue_hosts = run_hosts.select { |host| block_failed[host.name] }
        rescue_hosts.each { |host| @halted_hosts.delete(host.name) }
        propagate_role_context(task, rescue_tasks)
        run_task_batch(rescue_tasks, rescue_hosts)

        rescue_hosts.each do |host|
          still_failed = @halted_hosts.includes?(host.name)
          block_failed[host.name] = still_failed

          # rescue: succeeded - the block-body failure it recovered from
          # doesn't count as a play failure. Move it into "rescued"
          # instead, matching Ansible's recap (failed=0 ... rescued=1).
          unless still_failed
            recovered = @results[host.name]["failed"] - failed_before[host.name]
            if recovered > 0
              @results[host.name]["failed"] -= recovered
              @results[host.name]["rescued"] += recovered
            end
          end
        end
      end

      if always_tasks = task.always_tasks
        run_hosts.each { |host| @halted_hosts.delete(host.name) }
        propagate_role_context(task, always_tasks)
        run_task_batch(always_tasks, run_hosts)
        run_hosts.each { |host| block_failed[host.name] ||= @halted_hosts.includes?(host.name) }
      end

      notify_hosts_if_changed(task, run_hosts, changed_before)

      run_hosts.each do |host|
        @halted_hosts.delete(host.name)
        halt_if_failed(task, host, block_failed[host.name])
      end
    end

    private def notify_hosts_if_changed(task : Task, hosts : Array(Host), changed_before : Hash(String, Int32))
      return unless (notify_list = task.notify) && !notify_list.empty?

      hosts.each do |host|
        next unless @results[host.name]["changed"] > changed_before[host.name]
        notify_handlers(task, host, notify_list)
      end
    end

    # Multi-host counterpart to execute_include_tasks (the no-loop case
    # only - see task_has_loop?): resolves when:/the included file's path
    # PER HOST first (cheap - local template substitution, no remote
    # I/O), groups hosts that end up resolving the SAME file together,
    # then runs each group's included tasks via run_task_batch instead of
    # execute_include_tasks's single-host run_task_list. Real-world
    # include_tasks: almost always resolves identically for every host in
    # a homogeneous play (e.g. `include_tasks: setup-{{ ansible_os_family
    # }}.yml` across an all-Debian inventory - exactly what geerlingguy.
    # containerd/geerlingguy.kubernetes do), so this virtually always
    # collapses to one group holding every host - the case that actually
    # mattered for the ~1.8x cold-run slowdown this was written to fix.
    private def execute_include_tasks_multi(task : Task, hosts : Array(Host))
      puts "TASK [#{render_task_name_for_display(task, hosts.first)}]".colorize(:white).bold
      puts "*" * 70

      run_hosts, skip_hosts = partition_by_when(task, hosts)

      skip_hosts.each do |host|
        puts "skipping: [#{host.connection_host}]".colorize(:cyan)
        @results[host.name]["skipped"] += 1
      end

      run_groups = Hash(String, Array(Host)).new { |hash, key| hash[key] = [] of Host }
      run_hosts.each do |host|
        vars_context = build_vars_context(task, host)
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        file_rel = substitutor.substitute(task.include_file.as(String))
        resolved_path = PlaybookParser.resolve_include_path(file_rel, task.include_file_dir.as(String))

        unless File.exists?(resolved_path)
          fail_include(task, host, "Included tasks file not found: #{resolved_path}")
          next
        end

        # The include_tasks: task itself counts as one `ok` in the
        # recap, matching real Ansible and the single-host
        # execute_include_tasks path above - this multi-host batched
        # path never credited it at all, undercounting the recap's
        # `ok=` tally by one per host for every non-looped include_
        # tasks: task. Found benchmarking robertdebock.openvpn's own
        # "Setup openvpn server or client".
        @results[host.name]["ok"] += 1
        run_groups[resolved_path] << host
      end

      puts ""

      run_groups.each do |resolved_path, group_hosts|
        begin
          yaml = YAML.parse(Vault.maybe_decrypt(File.read(resolved_path)))
          unless yaml.as_a?
            group_hosts.each { |host| fail_include(task, host, "Included tasks file must be a YAML list: #{resolved_path}") }
            next
          end

          inherited = Play.new("", "")
          inherited.become = task.become
          inherited.become_user = task.become_user
          included_tasks = PlaybookParser.parse_tasks(yaml.as_a, inherited, "task in included #{resolved_path}", File.dirname(resolved_path))

          if include_vars = task.include_vars
            included_tasks.each do |included_task|
              include_vars.each { |key, value| included_task.vars[key] = value }
            end
          end

          # Task NAME substitution (e.g. a role default referenced in the
          # included tasks' own names) uses one representative host's
          # vars_context, same as the rest of this codebase's "first
          # host" precedent for cosmetic-only banner rendering - it can't
          # affect what actually runs.
          representative = group_hosts.first
          rep_vars_context = build_vars_context(task, representative)
          name_substitutor = VarSubstitutor.new(vars: rep_vars_context, host_name: representative.name)
          included_tasks.each do |included_task|
            included_task.name = name_substitutor.substitute(included_task.name)
          end

          propagate_role_context(task, included_tasks)

          connection_names = group_hosts.map { |host| host.vars["ansible_host"]?.try(&.as_s?) || host.name }
          puts "included: #{resolved_path} for #{connection_names.join(", ")}".colorize(:cyan)
          puts ""

          run_task_batch(included_tasks, group_hosts)
        rescue ex
          group_hosts.each { |host| fail_include(task, host, "Failed to load included tasks: #{ex.message}") }
        end
      end
    end

    # Runs *task* against every host in *hosts* concurrently instead of
    # one at a time, via a bounded pool of fibers (same Channel-gated
    # shape as gather_facts_for_all_hosts's Stage A parallelism) capped at
    # @forks. Safe with no locks: only one fiber runs Crystal code at any
    # instant (cooperative scheduling), and every per-host mutation this
    # touches (@results[host.name], @registered_vars[host.name],
    # @facts[host.name], @batch_cache[host.name], @halted_hosts.add) is
    # either a disjoint pre-seeded hash key or a Set#add with no yield
    # point mid-operation - never actually racing.
    #
    # The one real hazard is stdout: each host's fiber redirects its own
    # output to a private buffer via OutputRouting (so concurrent hosts'
    # lines never interleave), then every buffer is flushed in *hosts*
    # order only after every fiber has finished - output stays stable
    # regardless of which host's SSH round trip actually finished first.
    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #22: dispatch via the
    # `@host_worker_pool`'s persistent per-host fibers (one spawn per
    # host for the executor's lifetime) instead of spawning a fresh
    # fiber per (task, host) pair. The per-call gate is preserved so
    # `@forks` still bounds concurrency - the gate lives INSIDE the
    # worker loop now, so workers serialize on it the same way the old
    # per-call spawn pattern did, but the worker fiber itself survives
    # across tasks.
    private def run_task_for_hosts_in_parallel(task : Task, hosts : Array(Host))
      max_parallel = Math.min(hosts.size, @forks)
      pool = ensure_host_worker_pool(hosts)
      gate = Channel(Nil).new(max_parallel)
      max_parallel.times { gate.send(nil) }
      buffers = Hash(String, IO::Memory).new
      done = Channel(Nil).new(hosts.size)

      hosts.each do |host|
        pool[host.name].send(WorkMessage.new(task, host, buffers, done, gate))
      end

      hosts.size.times { done.receive }

      hosts.each do |host|
        if buffer = buffers[host.name]?
          print buffer.to_s
        end
      end
    end

    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #22: ensure a
    # persistent worker fiber exists for every host in `hosts`,
    # creating any missing entries in `@host_worker_pool` on demand.
    # Idempotent: callers can invoke this freely without spawning
    # duplicate workers. The worker loop is `receive -> gate.receive ->
    # execute_task -> store result -> signal done -> gate.send`, which
    # preserves the same parallelism-bounded-by-`@forks` semantics the
    # old per-call `spawn` pattern had (gate is consulted per-task, not
    # per-host).
    private def ensure_host_worker_pool(hosts : Array(Host)) : Hash(String, Channel(WorkMessage))
      hosts.each do |host|
        next if @host_worker_pool.has_key?(host.name)
        channel = Channel(WorkMessage).new
        @host_worker_pool[host.name] = channel
        spawn do
          loop do
            msg = channel.receive
            msg.gate.receive
            buffer = IO::Memory.new
            OutputRouting.redirect_current_fiber_to(buffer)
            begin
              execute_task(msg.task, msg.host)
            ensure
              OutputRouting.clear_current_fiber_redirect
            end
            msg.results[msg.host.name] = buffer
            msg.done_signal.send(nil)
            msg.gate.send(nil)
          end
        end
      end
      @host_worker_pool
    end
    
    # Gather facts for all hosts using the facts plugin
    # Each host's fact gathering is fully independent - writes only to
    # @facts[host.name] and @results[host.name], both pre-seeded per host
    # in #initialize, so no concurrent hash resizing - so it's gathered
    # in parallel via a bounded pool of fibers, one round trip's worth of
    # wall-clock time overlapping instead of summing across every host.
    # Bounded (not one fiber per host unconditionally) to avoid opening
    # an unbounded number of simultaneous SSH connections against a large
    # inventory. Output is collected per host and printed in deterministic
    # @hosts order only after every fiber has finished, so interleaved
    # completions never scramble the display - this was Stage A of the
    # cross-host parallelism work (`0.9.75`); Stage B, parallelizing the
    # per-task host loop itself via `--forks`, landed separately in
    # `0.9.77`. See git log for both.
    private def gather_facts_for_all_hosts
      # --gathering smart: a host whose facts this run already collected
      # (in an earlier play, via the shared run-scoped store) is not
      # queried again. Under the default `implicit` mode every play
      # re-gathers, matching real ansible-playbook's own default - a
      # playbook that deliberately re-gathers after a reboot or a package
      # install must keep seeing fresh facts, which is exactly why this
      # is opt-in rather than a silent default flip.
      targets = if @smart_gathering
                  @hosts.reject { |host| !@facts[host.name].empty? }
                else
                  @hosts
                end

      # Nothing to do: every host was gathered by an earlier play. Skip
      # the task banner entirely rather than printing an empty one.
      return if targets.empty?

      puts "TASK [Gathering Facts]".colorize(:white).bold
      puts "*" * 70

      outcomes = Hash(String, {Bool, String?}).new
      # Bounded by @forks, same as the per-task fan-out below: the `10`
      # this used to hardcode predates --forks, so `--forks 50` still
      # gathered 10 at a time and `--forks 1` (asked for precisely to get
      # strictly one-host-at-a-time behavior, e.g. to debug a flaky host)
      # still got 10-way concurrency here.
      max_parallel = Math.min(targets.size, @forks)
      max_parallel = 1 if max_parallel < 1
      gate = Channel(Nil).new(max_parallel)
      max_parallel.times { gate.send(nil) }
      done = Channel(Nil).new

      targets.each do |host|
        spawn do
          gate.receive
          outcomes[host.name] = gather_facts_for_host(host)
        ensure
          gate.send(nil)
          done.send(nil)
        end
      end

      targets.size.times { done.receive }

      targets.each do |host|
        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
        success, error_message = outcomes[host.name]

        if success
          puts "ok: [#{connection_host}]".colorize(:green)
          @results[host.name]["ok"] += 1
        else
          puts "failed: [#{connection_host}]".colorize(:red)
          puts "  Error gathering facts: #{error_message}".colorize(:red)
          @results[host.name]["failed"] += 1
        end
      end

      puts ""
    end

    # Runs the facts plugin against one host and stores whatever it
    # returns in @facts[host.name]. Returns {true, nil} on success or
    # {false, message} on failure - stats/display are handled by the
    # caller afterward, in deterministic host order, not here.
    private def gather_facts_for_host(host : Host) : {Bool, String?}
      vars_context = Hash(String, JSON::Any).new
      host.vars.each { |key, value| vars_context[key] = value }

      # If this gathers over SSH the wire payload needs
      # ansible_connection=local, so decide that up front and serialize
      # once, instead of serializing, parsing and re-serializing just to
      # inject one key afterwards.
      wire_vars = vars_context
      if PluginManager.remote_execution?("facts", host, vars_context)
        wire_vars = vars_context.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      config = {
        "host" => {
          "name" => host.name,
          "user" => host.user,
          "port" => host.port,
        },
        "params" => {} of String => String,
        "vars"   => wire_vars,
      }

      # Fact gathering never runs under become: - this config carries no
      # become:/become_user: fields at all, which is exactly what
      # resolve_become used to read back out of it as {false, nil}.
      result = PluginManager.execute_plugin("facts", config.to_json, host, vars_context, false, nil)

      if result["failed"]?.try(&.as_bool)
        return {false, result["msg"]?.try(&.as_s) || "Unknown error"}
      end

      if ansible_facts = result["ansible_facts"]?
        facts = Hash(String, JSON::Any).new
        ansible_facts.as_h.each { |key, value| facts[key] = value }
        @facts[host.name] = facts
        @facts_dict_cache.delete(host.name)
        @hv_generation += 1
      end

      {true, nil}
    rescue ex
      {false, ex.message}
    end
    
    # Show execution recap
    def show_recap
      ResultDisplay.show_recap(@hosts, @results)
    end
    
    # Execute a task on a host - dispatches to the loop, retry, or plain
    # single-execution path depending on what the task declares.
    private def execute_task(task : Task, host : Host)
      return execute_block(task, host) if task.block?
      return execute_include_tasks(task, host) if task.include_tasks?
      return execute_include_role(task, host) if task.include_role?
      if task.meta?
        # `when:` on a meta: task was previously never evaluated at all -
        # latent since meta: shipped (clear_facts/flush_handlers are
        # rarely when:-gated in practice), surfaced adding end_host/
        # end_play, whose whole point is frequently being conditional
        # per host. Verified against real ansible-playbook: a when:-false
        # meta: task prints "skipping: [host]" but - like every other
        # meta: outcome - does NOT bump the recap's skipped= counter
        # (defer_stats: true), unlike an ordinary task's when: skip.
        vars_context = build_vars_context(task, host)
        execute_meta(task, host) if when_passes?(task, vars_context, host, defer_stats: true)
        return
      end
      return execute_include_vars(task, host) if task.include_vars?
      return execute_validate_argument_spec(task, host) if task.validate_argument_spec?

      # run_once: only the first host in the play actually executes it;
      # later hosts get no output/stats at all, matching real Ansible - but
      # still pick up whatever it registered, so later tasks on those hosts
      # can reference the same variable.
      if task.run_once && host.name != @hosts.first.name
        copy_run_once_register(task, host)
        return
      end

      # An earlier group member's trigger may have already built this
      # exact context while preparing this task's own batch step
      # (execute_batch_group prepares every member up front) - reuse it
      # instead of paying for VariableContext.build + facts merge again.
      vars_context = @batch_cache[host.name]?.try(&.[task]?).try(&.[1]) ||
        build_vars_context(task, host)

      # delegate_to: run the module against a different host's connection
      # while vars/facts/register/stats stay attributed to `host` - resolved
      # here (not at parse time) since it may be templated and needs the
      # variable context to substitute against.
      # One substitutor for this (task, host), built only where it will
      # actually be used. The constructor copies the whole vars hash and
      # adds the magic variables, and nothing between here and
      # execute_task_once mutates vars_context (verified for
      # resolve_delegate_host / resolve_fileglob / resolve_loop_template),
      # so the instances this path used to build were copies of an
      # identical thing.
      #
      # Deliberately *not* built unconditionally up front: the loop and
      # until: paths below return before ever reaching execute_task_once
      # and build their own per item / per attempt, so an eager instance
      # here would be pure waste for every looped task - which measured
      # as a real regression when tried that way.
      #
      # apply_changed_failed_when still builds its own, and must: it
      # evaluates against a different context (see there).
      shared_sub = nil.as(VarSubstitutor?)
      if task.delegate_to || task.loop_fileglob
        shared_sub = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      end

      exec_host = resolve_delegate_host(task, host, vars_context, shared: shared_sub)

      # with_fileglob needs a substitutor (for {{ vars }} in the pattern) and
      # the filesystem, so it can only be resolved here, not at parse time.
      # loop_template is a loop:/with_*: keyword given as "{{ some_var }}"
      # instead of a literal list/dict - also only resolvable once the
      # variable context exists.
      loop_items = task.loop_items || resolve_first_found(task, host, vars_context) ||
        resolve_fileglob(task, host, vars_context, shared: shared_sub) ||
        resolve_loop_template(task, vars_context) ||
        resolve_loop_flattened(task, vars_context, host.name) ||
        resolve_loop_subelements(task, vars_context)

      if loop_items
        execute_looped_task(task, host, vars_context, loop_items, exec_host)
        return
      end

      if (until_condition = task.until_condition) && !@check_mode
        execute_task_with_retries(task, host, vars_context, until_condition, exec_host)
        return
      end

      # Batching: if this task is part of a batch
      # group and batching applies to this host, its result comes from
      # (triggering, if not already done, then reading from) the group's
      # single shared SSH round trip instead of its own solo one -
      # everything downstream of getting a result is identical either
      # way.
      applies, batched_result = try_batched_result(task, host, vars_context, exec_host)
      if applies
        # A when:-skipped batch member returns {true, nil}: execute_batch_group
        # deferred its print and counter (defer_display/defer_stats) so the
        # group's skips aren't all emitted at once during batch-build; report
        # this member's skip here, in proper task order, exactly as the solo
        # path does via when_passes?.
        if batched_result.nil?
          print_batched_skip(task, host, vars_context)
          return
        end
        finish_single_task(task, host, batched_result)
        return
      end

      # Reached the plain single-execution path, so it will definitely be
      # used now: when_passes? and the param substitution inside
      # execute_task_once share this one instance.
      shared_sub ||= VarSubstitutor.new(vars: vars_context, host_name: host.name)

      result = execute_task_once(task, host, vars_context, exec_host: exec_host, shared: shared_sub)
      return unless result

      fact_host = (task.delegate_facts && task.delegate_to) ? exec_host : host
      finish_single_task(task, host, result, fact_host)
    end

    # Resolve delegate_to: to the Host whose connection the module should
    # actually run against. Variables used to substitute a templated
    # delegate_to: value are still `host`'s own (real Ansible doesn't
    # delegate variables, only the connection).
    private def resolve_delegate_host(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : Host
      delegate_to = task.delegate_to
      return host unless delegate_to

      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      target_name = substitutor.substitute(delegate_to)

      if (inventory = @inventory) && (resolved = inventory.get_hosts(target_name)).any?
        return resolved.first
      end

      fallback = Host.new(target_name, ENV["USER"]? || "root", 22)
      fallback.vars["ansible_connection"] = JSON::Any.new("local") if target_name == "localhost" || target_name == "127.0.0.1"
      fallback
    end

    # run_once: on every host after the first, skip execution outright but
    # still copy over whatever the first host's run registered, so a later
    # task on this host referencing it doesn't see an undefined variable.
    private def copy_run_once_register(task : Task, host : Host)
      register_name = task.register
      return unless register_name && !register_name.empty?

      if value = @registered_vars[@hosts.first.name][register_name]?
        @registered_vars[host.name][register_name] = value
        @hv_generation += 1
      end
    end

    # Render *task*'s `name:` for the "TASK [...]" banner, lazily - only
    # builds a vars_context (the same expensive facts-merge #execute_task
    # itself pays for separately) when the name actually needs it, so a
    # literal (the overwhelming majority) task name costs nothing extra.
    #
    # Every banner print site used to print `task.name` raw, which only
    # ever reflected whatever narrow, early, per-var-source pass had
    # already substituted into it (include_tasks:'s include_vars:,
    # include_role:'s vars:) - anything sourced from a role's own
    # `vars/main.yml` (round 26/27's `__common_binary_basename`, itself a
    # templated vars-file entry) or from `ansible_facts`/registered vars
    # stayed literally `{{ ... }}` in the banner even though the task's
    # own body rendered correctly, since the body gets a full vars_context
    # at actual execution time and the banner never did. Rendering here,
    # right before print, gives the banner the same full context the body
    # itself is about to use - it's cosmetic-only (a mistake here can't
    # affect what actually runs), so best-effort: on any substitution
    # error, fall back to the raw unrendered name rather than raising.
    private def render_task_name_for_display(task : Task, host : Host) : String
      return task.name unless task.name.includes?("{{")

      vars_context = build_vars_context(task, host)
      VarSubstitutor.new(vars: vars_context, host_name: host.name).substitute(task.name)
    rescue
      task.name
    end

    # Substitutes each *notify_list* entry against *task*'s own
    # vars_context before handing it to HandlerRunner - `task.notify` is
    # set once at parse time from raw YAML strings and was never
    # substituted anywhere before this, so a templated notify: (the
    # `prometheus.prometheus` collection's own internal `_common` role
    # idiom: `notify: "{{ ansible_parent_role_names | first }} : Restart
    # {{ _common_service_name }}"`) never matched the handler it was
    # meant to trigger at all - the handler simply never ran. Lazy, same
    # pattern as #render_task_name_for_display: only builds a
    # vars_context (not otherwise available at every one of this
    # method's three call sites, which don't all already have one in
    # scope) when at least one entry actually needs it. Found live
    # investigating round 28's prometheus.prometheus.pushgateway.
    private def notify_handlers(task : Task, host : Host, notify_list : Array(String))
      return if notify_list.empty?

      unless notify_list.any?(&.includes?("{{"))
        notify_list.each { |handler_name| @handler_runner.notify(host, handler_name) }
        return
      end

      vars_context = build_vars_context(task, host)
      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      notify_list.each do |handler_name|
        rendered = handler_name.includes?("{{") ? (substitutor.substitute(handler_name) rescue handler_name) : handler_name
        @handler_runner.notify(host, rendered)
      end
    end

    # Build the base variable context (play/host/registered/task vars + facts)
    # shared by every execution path for a task.
    private def build_vars_context(task : Task, host : Host) : Hash(String, JSON::Any)
      # See the @base_context_a_cache/@base_context_b_cache ivar comments
      # above for why this is 2 caches, not 1, and exactly what real
      # precedence order each preserves. role_defaults < baseA
      # (play_vars/host.vars/registered_vars) < role_vars < task.vars <
      # baseB (included_vars/facts/host-magic) is the SAME order
      # VariableContext.build + the old included_vars/facts/magic-var
      # block always applied - only the "did we just recompute this
      # host's unchanging inputs again" cost changed, not what wins a
      # same-key collision.
      # `Hash#dup` is a bulk copy of the internal entries array - measured
      # ~3.4x faster than rebuilding the same-sized hash via an `.each`
      # insert loop (200-entry hash, 200k iterations: 599ms vs 176ms,
      # `--release`). Only usable where the destination starts EMPTY,
      # which is exactly baseA's position here - it's the first tier
      # applied, and the one tier below it (role_defaults) is small and
      # per-role, not per-host, so folding it in via `||=` after the dup
      # (rather than `[]=` before it) is cheap however it's done and
      # correctly reproduces "role_defaults only fills what baseA doesn't
      # already have" - real Ansible's own actual precedence, unchanged
      # from what `VariableContext.build`'s ordering used to guarantee
      # via unconditional overwrite-in-priority-order instead.
      vars_context = base_context_a_for(host).dup

      if defaults = task.role_defaults
        defaults.each { |key, value| vars_context[key] ||= value }
      end

      if role_vars = task.role_vars
        role_vars.each { |key, value| vars_context[key] = value }
      end

      task.vars.each { |key, value| vars_context[key] = value }

      # Magic variables belong in vars_context itself, not only in the
      # copy VarSubstitutor makes. Bare conditions - `when:`,
      # `until:`, `changed_when:`, `failed_when:`, and `assert:`'s
      # `that:` (which is evaluated inside the plugin, against the "vars"
      # this context is serialized into) - are evaluated directly against
      # vars_context and never saw them, so `when: inventory_hostname ==
      # "web1"` silently skipped every task while
      # `when: "{{ inventory_hostname }} == web1"` worked.
      #
      # Applied after facts (baseB below, which the old code built this
      # exact tier ON TOP of), with the same precedence rules
      # VarSubstitutor#add_magic_variables uses - see there for why only
      # inventory_hostname is unconditional. base_context_b_for covers
      # included_vars + facts; these 3 magic keys stay uncached and
      # applied directly here - see that method's own comment for why.
      base_context_b_for(host).each { |key, value| vars_context[key] = value }
      vars_context["inventory_hostname"] = JSON::Any.new(host.name)
      vars_context["ansible_hostname"] ||= JSON::Any.new(host.name)
      vars_context["ansible_host"] ||= JSON::Any.new(host.name)

      if role_name = task.role_name
        vars_context["ansible_role_name"] = JSON::Any.new(role_name)
      end
      if parent_names = task.role_parent_names
        vars_context["ansible_parent_role_names"] = JSON::Any.new(parent_names.map { |n| JSON::Any.new(n) })
      end
      if collection_name = task.ansible_collection_name
        vars_context["ansible_collection_name"] = JSON::Any.new(collection_name)
      end
      if role_path = task.role_path
        vars_context["role_path"] = JSON::Any.new(role_path)
      end

      # `ansible_facts` - the same facts again, under their unprefixed
      # names, as one dict. Real Ansible exposes every fact both ways
      # (`ansible_os_family` *and* `ansible_facts.os_family`), and the
      # dict form is what modern roles use: dev-sec's os_hardening
      # references `ansible_facts.os_family` 16 times and never uses the
      # flat spelling, so without this every one of its conditions
      # silently evaluated false and the role skipped almost entirely.
      #
      # Derived from the same store rather than gathered separately, so
      # the two spellings can never disagree, and memoized per host
      # (facts_dict_for) rather than rebuilt on every single task - see
      # that method's own comment for the invalidation contract.
      unless @facts[host.name].empty?
        vars_context["ansible_facts"] = JSON::Any.new(facts_dict_for(host.name))
      end

      vars_context["hostvars"] = JSON::Any.new(build_hostvars)
      vars_context["groups"] = JSON::Any.new(build_groups)

      render_task_vars(task, vars_context, host.name)

      # connection: local (or any other connection: override) on this
      # ONE task - independent of delegate_to:, which changes which
      # host's vars/facts apply rather than how the module runs. Every
      # local-vs-remote decision (PluginManager.is_local_connection?/
      # .remote_execution?, LocalExecutor vs SSHManager dispatch) reads
      # ansible_connection out of vars_context, so overriding it here
      # takes effect for this task's own dispatch without mutating the
      # host's own persistent vars. Previously entirely unparsed -
      # `connection: local` silently had no effect, running the task's
      # module against the real target over SSH instead of locally on
      # the controller. Found via robertdebock.backup's own "Create
      # backup_directory" task.
      if task_connection = task.connection
        vars_context["ansible_connection"] = JSON::Any.new(task_connection)
      end

      vars_context
    end

    # First of the 2 #build_vars_context base caches - see the
    # @base_context_a_cache ivar's own comment for why there are 2 and
    # what order this preserves. @play_vars is fixed for this
    # TaskExecutor's whole lifetime (assigned once, in #initialize -
    # `grep -n '@play_vars\s*='` finds no other write); host.vars never
    # mutates mid-play either (audited the same way for item #16 above -
    # every `host.vars[...]` site in this file is a READ); leaving
    # @registered_vars[host.name] as this cache's only real input,
    # already covered by @hv_generation's own invalidation contract.
    private def base_context_a_for(host : Host) : Hash(String, JSON::Any)
      if @base_context_a_generation[host.name]? == @hv_generation
        return @base_context_a_cache[host.name]
      end

      result = Hash(String, JSON::Any).new(initial_capacity: 128)
      @play_vars.each { |key, value| result[key] = value }
      host.vars.each { |key, value| result[key] = value }
      @registered_vars[host.name].each { |key, value| result[key] = value }

      @base_context_a_cache[host.name] = result
      @base_context_a_generation[host.name] = @hv_generation
      result
    end

    # Second of the 2 #build_vars_context base caches - included_vars +
    # facts, applied in that exact relative order so a same-key
    # collision between them resolves identically to the pre-cache code
    # (which merged them in this same sequence). Deliberately does NOT
    # also cache the 3 host-magic keys (inventory_hostname/
    # ansible_hostname/ansible_host) the old code applied right after -
    # unlike included_vars/facts, those 2 `||=`s need to see whatever
    # `host.vars` (baseA, merged into vars_context BEFORE this cache) may
    # already have set for the SAME keys (an inventory line like `web1
    # ansible_host=192.0.2.55` must win). A `||=` evaluated only against
    # THIS method's own small hash - which has no idea what baseA already
    # put in vars_context - would set them unconditionally instead,
    # clobbering the real inventory value; caught by
    # `cli_spec.cr`'s own "does not overwrite an inventory ansible_host
    # with the inventory name" spec. Cheap enough (3 conditional
    # assignments) to just apply directly against the real vars_context
    # in #build_vars_context instead of caching. All real inputs here are
    # covered by @hv_generation's existing invalidation contract -
    # @included_vars gained a bump site at #execute_include_vars (its
    # only writer) as part of this change; @facts was already covered by
    # facts_dict_for above.
    private def base_context_b_for(host : Host) : Hash(String, JSON::Any)
      if @base_context_b_generation[host.name]? == @hv_generation
        return @base_context_b_cache[host.name]
      end

      result = Hash(String, JSON::Any).new(initial_capacity: 128)
      @included_vars[host.name]?.try(&.each { |key, value| result[key] = value })
      @facts[host.name].each { |key, value| result[key] = value }

      @base_context_b_cache[host.name] = result
      @base_context_b_generation[host.name] = @hv_generation
      result
    end

    # Memoized "ansible_facts.*" dict for one host - see
    # build_vars_context's own comment for why this dict has to exist
    # separately from the flat `ansible_os_family`-style keys already in
    # @facts[host.name].
    #
    # Invalidation contract: @facts[host.name] has exactly 3 real
    # mutation sites in this file (audited directly, not assumed -
    # `grep -n '@facts\[.*\]\s*=\|@facts\[.*\]\.clear' executor.cr`) -
    # gather_facts's full replace, merge_ansible_facts's per-key write
    # (the path set_fact:/package_facts:/etc all go through), and meta:
    # clear_facts's #clear. Every one of the 3 deletes this host's cache
    # entry (`@facts_dict_cache.delete(host.name)`) in the same
    # statement that mutates @facts, so the next call here always sees a
    # cache miss and rebuilds from the fresh @facts contents - there is
    # no 4th mutation site to miss (unlike the general vars_context
    # caching in item #1 of SUGGESTED_PERFORMANCE_IMPROVEMENTS.md, which
    # this deliberately does NOT attempt: task.vars/role_vars/
    # role_defaults vary per TASK, not just per host, and that item's own
    # writeup flags exactly why a full-context cache needs a much more
    # exhaustive invalidation audit than this narrow one).
    private def facts_dict_for(host_name : String) : Hash(String, JSON::Any)
      @facts_dict_cache[host_name] ||= begin
        facts_dict = Hash(String, JSON::Any).new(initial_capacity: 128)
        @facts[host_name].each do |key, value|
          facts_dict[key.lchop("ansible_")] = value
        end
        facts_dict
      end
    end

    # Real Ansible's `groups` magic variable - a dict of every inventory
    # group name to the list of host names it contains (`groups['all']`,
    # `groups['webservers']`, ...), the standard way a task broadcasts to
    # or loops over every host in a group without hardcoding names
    # (geerlingguy.kubernetes' own "Set the kubeadm join command
    # globally.": `delegate_to: "{{ item }}", loop: "{{ groups['all'] }}"`
    # to push the join command onto every node). Previously not populated
    # at all, so ANY `groups[...]` access resolved "undefined" - a single-
    # item loop whose one item literally was the string "undefined",
    # which a templated `delegate_to: "{{ item }}"` then tried to SSH to.
    #
    # `groups['all']` is synthesized from the full inventory (not merely
    # `@inventory.groups["all"]?`, which may not even exist as an
    # explicit group) - matches real Ansible, where 'all' always means
    # every host regardless of how the inventory file grouped things.
    private def build_groups : Hash(String, JSON::Any)
      if (cache = @groups_cache) && @groups_cache_generation == @hv_generation
        return cache
      end

      result = Hash(String, JSON::Any).new
      if inventory = @inventory
        inventory.groups.each do |name, group|
          result[name] = JSON::Any.new(group.hosts.keys.map { |hostname| JSON::Any.new(hostname) })
        end
        result["all"] = JSON::Any.new(inventory.hosts.keys.map { |hostname| JSON::Any.new(hostname) })
      else
        result["all"] = JSON::Any.new(@hosts.map { |other_host| JSON::Any.new(other_host.name) })
      end
      @groups_cache = result
      @groups_cache_generation = @hv_generation
      result
    end

    # Real Ansible's `hostvars[<name>]` magic variable - a dict of every
    # host in the *whole inventory's* own vars (inventory-defined vars
    # like ansible_host, any facts already gathered for it, and any
    # vars it has registered so far), letting a task on one host look
    # up another's connection details or state
    # (`hostvars['node2'].ansible_host`) - the standard hand-written
    # task shape every real multi-node Ansible playbook uses for
    # cross-host orchestration (peer-probing a GlusterFS/etcd/Consul
    # cluster's other members, templating a load balancer config from
    # every backend's own facts, ...). Previously not populated at all,
    # so `hostvars[...]` always resolved "undefined" - found
    # benchmarking a real geerlingguy.glusterfs 3-node cluster: `gluster
    # peer probe {{ hostvars['node2'].ansible_host }}` ran as `gluster
    # peer probe undefined`, silently probing a bogus hostname instead
    # of the real peer's IP.
    #
    # Deliberately sourced from @inventory.hosts (the FULL inventory),
    # not @hosts (only this play's own `hosts:` pattern target list) -
    # real hostvars is available for any inventory host, including ones
    # a given play never targets itself (the glusterfs cluster playbook
    # above: only node1 runs the peer-probe play, but needs node2/
    # node3's hostvars too). Falls back to @hosts when there's no
    # inventory reference at all (the async-job replay path constructs
    # TaskExecutor without one) - covering only the current play's
    # hosts there is still strictly better than not populating hostvars
    # at all.
    #
    # Rebuilt fresh on every #build_vars_context call (once per task per
    # host) rather than cached - real Ansible's own hostvars reflects a
    # set_fact:/register: made by ANY host earlier in the same play, so
    # a stale snapshot would miss updates. Deliberately narrower than a
    # full recursive #build_vars_context call per other host (which
    # would also need its own "hostvars" key excluded to avoid infinite
    # recursion) - inventory vars + facts + registered vars covers every
    # real-world hostvars[...] use seen so far.
    private def build_hostvars : Hash(String, JSON::Any)
      if (cache = @hostvars_cache) && @hostvars_cache_generation == @hv_generation
        return cache
      end

      result = Hash(String, JSON::Any).new
      all_hosts = @inventory.try(&.hosts.values) || @hosts
      all_hosts.each do |other_host|
        entry = Hash(String, JSON::Any).new
        other_host.vars.each { |key, value| entry[key] = value }
        @facts[other_host.name]?.try(&.each { |key, value| entry[key] = value })
        @registered_vars[other_host.name]?.try(&.each { |key, value| entry[key] = value })
        entry["inventory_hostname"] = JSON::Any.new(other_host.name)
        entry["ansible_hostname"] ||= JSON::Any.new(other_host.name)
        entry["ansible_host"] ||= JSON::Any.new(other_host.name)
        result[other_host.name] = JSON::Any.new(entry)
      end
      @hostvars_cache = result
      @hostvars_cache_generation = @hv_generation
      result
    end

    # A task-level vars: value can itself be a template referencing other
    # vars (dev-sec os_hardening's own `vars: {mountinfo: "{{
    # ansible_facts.mounts | selectattr(...) | list | first | default(None)
    # }}"}`, computing a per-task helper from ansible_facts) -
    # VariableContext.build merges task.vars into the context as plain
    # unrendered strings (it runs before ansible_facts/magic vars even
    # exist), so without this a template-valued task var stayed literal
    # `"{{ ... }}"` text forever, and any {{ }}/when: referencing it
    # (`mountinfo.device`) resolved undefined. Rendered here, once the
    # context is fully assembled, so a task var can reference
    # ansible_facts/registered vars/other role vars - anything already in
    # scope by this point.
    # include_role:'s own vars: (unlike a block's or a plain task's vars:,
    # both handled by render_task_vars/propagate_role_context) were passed
    # to RoleLoader.load_single_role completely unrendered - a templated
    # value (linux-system-roles/logging's own `include_role: name: "{{
    # role_path }}/roles/rsyslog" vars: rsyslog_custom_config_files: "{{
    # __custom_config_files + logging_custom_config_files }}"`) landed in
    # the subrole's vars as the literal `"{{ ... }}"` text - a non-empty,
    # "defined" string instead of the empty list it should have rendered
    # to. Every task in the subrole referencing that var saw the raw
    # template text as its value; here that fed `loop: "{{
    # rsyslog_custom_config_files | flatten }}"`, turning a should-be-
    # empty (and thus skipped) loop into one bogus iteration whose `item`
    # was the whole unparsed template string, sent straight into `copy:
    # src: "{{ item }}"` and failing there instead.
    private def render_include_role_vars(vars : Hash(String, JSON::Any)?, vars_context : Hash(String, JSON::Any), host_name : String) : Hash(String, JSON::Any)
      return Hash(String, JSON::Any).new unless vars

      rendered_vars = Hash(String, JSON::Any).new
      vars.each do |key, value|
        rendered_vars[key] = render_include_role_var_value(value, vars_context, host_name)
      end
      rendered_vars
    end

    # Recurses into a vars: value so a list-of-dicts (e.g. `service_
    # list:` on robertdebock.node_red's `import_role: name: robertdebock.
    # service`, each entry with its own `{{ node_red_service }}`-style
    # fields) gets every nested String leaf rendered, not just a
    # top-level scalar. Previously only checked `value.raw.as?(String)`
    # directly, so any Array/Hash-shaped var passed through completely
    # unrendered - every `{{ }}` inside it landed on the included role
    # literally, showing up downstream as the string "undefined" once
    # VariableLookup gave up resolving it.
    private def render_include_role_var_value(value : JSON::Any, vars_context : Hash(String, JSON::Any), host_name : String) : JSON::Any
      case raw = value.raw
      when String
        return value unless raw.includes?("{{")
        if native = evaluate_bare_mustache_preserving_type(raw, vars_context)
          return native
        end
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
        rendered = substitutor.substitute(raw)
        parsed = (rendered.starts_with?('{') || rendered.starts_with?('[')) ? (JSON.parse(rendered) rescue nil) : nil
        parsed || JSON::Any.new(rendered)
      when Array
        JSON::Any.new(raw.map { |item| render_include_role_var_value(item, vars_context, host_name) })
      when Hash
        rendered_hash = Hash(String, JSON::Any).new
        raw.each { |k, v| rendered_hash[k] = render_include_role_var_value(v, vars_context, host_name) }
        JSON::Any.new(rendered_hash)
      else
        value
      end
    end

    private def render_task_vars(task : Task, vars_context : Hash(String, JSON::Any), host_name : String)
      task.vars.each_key do |key|
        raw = vars_context[key]?
        next unless raw && (raw_string = raw.raw.as?(String)) && raw_string.includes?("{{")

        if native = evaluate_bare_mustache_preserving_type(raw_string, vars_context)
          vars_context[key] = native
          next
        end

        # Task-level `vars:` are rendered here UNCONDITIONALLY, before
        # `when:` is even checked (this method runs inside
        # build_vars_context, which builds the very context `when:`
        # itself gets evaluated against) - real Ansible's own per-key
        # lazy Jinja templating means a `vars:` entry never gets touched
        # at all if the task ends up skipped by `when:` and nothing else
        # references it first. A `vars:` expression that legitimately
        # raises on this host (`| first` on a genuinely empty sequence,
        # even with `| default(None)` right after it - `first`'s own
        # raise is deliberate and correct, matching real Jinja2/Ansible,
        # see jinja_filters.cr/filter_engine.cr's own comments) used to
        # crash the WHOLE task outright regardless of whether `when:`
        # would have skipped it. Real bug found benchmarking devsec.
        # hardening.os_hardening's own mount-hardening task: `vars:
        # mountinfo: "{{ ansible_facts.mounts | selectattr(...) | list |
        # first | default(None) }}"` crashed on any host missing that
        # particular mount point, even though `when: mount.enabled |
        # bool` is `false` by the role's own default for most of its
        # mount entries and never references `mountinfo` at all.
        #
        # Fix: if evaluating THIS key raises, leave it absent from
        # vars_context - this codebase's existing, pervasive "undefined"
        # convention - instead of letting the exception propagate and
        # crash the task. Correctly harmless when nothing downstream
        # (`when:`, the task's own params) ever looks this key up, which
        # is exactly the common case a disabled/not-applicable `when:`
        # guard represents. Narrower than true per-key laziness (a
        # genuinely-needed value that's ALSO broken now resolves as
        # "undefined" rather than raising at the point of use, matching
        # every other undefined-variable case in this codebase rather
        # than real Ansible's own raise-on-actual-use) - not attempted
        # here; see KNOWN_MISSING.md for why a full lazy-evaluation
        # redesign is bigger, separately-deferred work.
        begin
          substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
          rendered = substitutor.substitute(raw_string)

          # A dict/list-valued task var (mountinfo above) renders to JSON
          # object/array text via VariableLookup#format_value - parsed back
          # to real structure so dotted/indexed access into it
          # (`mountinfo.device`) works, the same reasoning as set_fact's own
          # dict/array coercion.
          parsed = (rendered.starts_with?('{') || rendered.starts_with?('[')) ? (JSON.parse(rendered) rescue nil) : nil
          vars_context[key] = parsed || JSON::Any.new(rendered)
        rescue
          vars_context.delete(key)
        end
      end
    end

    # A raw value that's EXACTLY one bare `{{ expr }}` span (nothing else
    # around it, no second span) can be evaluated straight to its real
    # JSON::Any type (bool/int/float/array/hash) via Crinja's own
    # `evaluate_value!` instead of going through VarSubstitutor#substitute
    # (always returns a String) and then re-parsing - which only ever
    # attempted JSON.parse for a result starting with '{' or '[', silently
    # leaving a scalar bool/int/float as its Python-repr-style STRING
    # ("True"/"False", from Crinja's own str(bool) rendering) instead of a
    # real JSON::Any bool. Found via robertdebock.tomcat's own `import_role:
    # name: robertdebock.service` vars: (`enabled: "{{ instance.
    # service_enabled | default(tomcat_service_enabled) }}"` - a real bool
    # default, filter chain and all) - `item.enabled is boolean` failed the
    # included role's own assert.yml because "enabled" was landing as the
    # STRING "True", same bug class as the well-documented Python-repr-list
    # one (apt.cr/package.cr/pip.cr/find.cr), just for a scalar bool here.
    # `render_include_role_vars`/`render_task_vars` had the identical
    # narrow-heuristic gap; shared here so both get the fix in one place.
    # Falls back to nil (caller does its usual String-based rendering) for
    # anything Crinja can't evaluate this way, or that isn't a single bare
    # span to begin with.
    private def evaluate_bare_mustache_preserving_type(raw : String, vars_context : Hash(String, JSON::Any)) : JSON::Any?
      stripped = raw.strip
      return nil unless stripped.starts_with?("{{") && stripped.ends_with?("}}")

      inner = stripped[2..-3]
      return nil if inner.includes?("{{") || inner.includes?("}}")

      VariableSubstitutor::CrinjaRenderer.new(vars_context).evaluate_value!(inner.strip)
    rescue
      nil
    end

    # Merge a task result's `ansible_facts` (if any) into the host's fact
    # store, the same generic mechanism gather_facts_for_all_hosts already
    # uses for the "facts" plugin's result - set_fact (and anything else
    # that returns ansible_facts) rides this without any special-casing.
    # build_vars_context applies @facts after every other tier, matching
    # real Ansible's own high precedence for set_fact.
    private def merge_ansible_facts(host : Host, result : JSON::Any)
      return unless ansible_facts = result["ansible_facts"]?
      return unless facts_hash = ansible_facts.as_h?

      facts_hash.each do |key, value|
        @facts[host.name][key] = value
      end
      @facts_dict_cache.delete(host.name)
      @hv_generation += 1
    end

    # with_first_found: yields exactly one item - the first candidate path
    # that exists on the *controller* - or none at all when nothing
    # matched. Candidates are templated, so they can only be resolved
    # here, not at parse time.
    private def resolve_first_found(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      candidates = task.loop_first_found
      return nil unless candidates

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

      candidates.each do |raw|
        candidate = substitutor.substitute(raw).strip
        next if candidate.empty?
        # A leftover {{ }} means the fact it depends on is missing;
        # treating that as a filename would only produce a confusing
        # "no such file", so skip the candidate instead.
        next if candidate.includes?("{{")

        if found = resolve_first_found_path(task, candidate)
          return [JSON::Any.new(found)]
        end
      end

      # No candidate matched. `skip: true` makes that a skipped task;
      # without it real Ansible errors, which this engine approximates by
      # skipping too rather than inventing a second failure path.
      [] of JSON::Any
    end

    # with_first_found: and include_vars: resolve relative paths against
    # *different* directories, verified against ansible-core 2.19.4 rather
    # than assumed - conflating them would silently load files real
    # Ansible would not:
    #
    # - the first_found lookup searches the role's `files/` (a probe role
    #   with the same filename in both vars/ and files/ resolved to the
    #   files/ copy, and a name present only in vars/ was skipped);
    # - include_vars: itself searches the role's `vars/`, which is the
    #   whole point of that directory.
    #
    # Also searches the ROLE ROOT itself (`task.role_path`), not just
    # its files/templates/vars subdirs directly - geerlingguy.mysql's
    # own "Include OS-specific variables." bakes the `vars/` prefix into
    # each candidate itself (`with_first_found: files:
    # ["vars/{{ansible_facts.os_family}}.yml"]`), unlike dev-sec
    # os_hardening's bare-filename style above. Without the role root as
    # a search root, "vars/Debian.yml" only ever got joined against
    # role_vars_dir (producing a nonexistent doubled "vars/vars/
    # Debian.yml"), so this always silently resolved to zero candidates
    # (`skip: true` on the with_first_found meant it skipped rather than
    # failed) and every var the role expected from that file - including
    # mysql_daemon - stayed undefined for the rest of the run.
    private def resolve_first_found_path(task : Task, candidate : String) : String?
      return File.exists?(candidate) ? candidate : nil if candidate.starts_with?("/")

      roots = [] of String
      task.role_files_dir.try { |dir| roots << dir }
      task.role_templates_dir.try { |dir| roots << dir }
      # with_first_found is commonly used with include_vars: to pick an
      # OS-specific vars file - dev-sec os_hardening's "Fetch OS dependent
      # variables" does exactly this against Ubuntu.yml/Debian.yml in the
      # role's vars/ dir. Include vars/ in the search roots so those resolve
      # the same way resolve_include_vars_path already looks there.
      task.role_vars_dir.try { |dir| roots << dir }
      task.role_path.try { |dir| roots << dir }
      task.include_file_dir.try { |dir| roots << dir }
      roots << Dir.current

      first_existing(roots, candidate)
    end

    private def resolve_include_vars_path(task : Task, candidate : String) : String?
      return File.exists?(candidate) ? candidate : nil if candidate.starts_with?("/")

      roots = [] of String
      if vars_dir = task.role_vars_dir
        roots << vars_dir
        roots << File.join(File.dirname(vars_dir), "defaults")
      end
      task.include_file_dir.try { |dir| roots << dir }
      roots << Dir.current

      first_existing(roots, candidate)
    end

    private def first_existing(roots : Array(String), candidate : String) : String?
      roots.each do |root|
        path = File.join(root, candidate)
        return path if File.exists?(path)
      end
      nil
    end

    # include_vars: reads a YAML file from the CONTROLLER and merges it
    # into this host's variable context - nothing runs on the target, so
    # it is a pseudo-module here rather than a plugin binary (same shape
    # as meta:).
    #
    # With `name:`, the whole file is loaded as a single dict under that
    # name (`os_vars`), which is how roles stage OS-specific values before
    # applying them selectively; without it the file's keys are merged
    # individually.
    private def execute_include_vars(task : Task, host : Host)
      vars_context = build_vars_context(task, host)
      return unless when_passes?(task, vars_context, host)

      # The file may be chosen by with_first_found (exposed as `item`) or
      # given directly; either way it is templated.
      if items = resolve_first_found(task, host, vars_context)
        if items.empty?
          puts "skipping: [#{host.name}]".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end
        vars_context["item"] = items.first
      end

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      candidate = substitutor.substitute(task.include_vars_file || "").strip
      path = resolve_include_vars_path(task, candidate)

      unless path
        finish_include_vars_failure(task, host, "include_vars: file not found: #{candidate}")
        return
      end

      loaded = begin
        RoleLoader.load_vars_file(path)
      rescue ex
        finish_include_vars_failure(task, host, "include_vars: could not parse #{path}: #{ex.message}")
        return
      end

      store = (@included_vars[host.name] ||= Hash(String, JSON::Any).new)
      if name = task.include_vars_name
        store[name] = JSON::Any.new(loaded)
      else
        loaded.each { |key, value| store[key] = value }
      end
      @hv_generation += 1

      puts "ok: [#{host.name}]".colorize(:green)
      @results[host.name]["ok"] += 1
    end

    private def finish_include_vars_failure(task : Task, host : Host, message : String)
      puts "failed: [#{host.name}]".colorize(:red)
      puts "  Message: #{message}".colorize(:red)
      @results[host.name]["failed"] += 1
      @halted_hosts.add(host.name) unless task.ignore_errors
    end

    # RoleLoader's auto-synthesized "Validating arguments against arg
    # spec" task (see there) - checks the role's effective vars (already
    # in vars_context via role_defaults/role_vars, same as any other role
    # task) against each declared option's `required:`/`type:`, matching
    # real ansible-core's own role argument validation.
    private def execute_validate_argument_spec(task : Task, host : Host)
      vars_context = build_vars_context(task, host)
      options = task.validate_argument_spec_options || Hash(String, JSON::Any).new

      errors = [] of String
      options.each do |option_name, spec|
        value = vars_context[option_name]?

        if value.nil?
          errors << "missing required argument: #{option_name}" if spec["required"]?.try(&.as_bool?) == true
          next
        end

        if declared_type = spec["type"]?.try(&.as_s?)
          unless argument_type_matches?(value, declared_type)
            errors << "argument '#{option_name}' is of type #{json_type_name(value)} and we were unable to convert to #{declared_type}"
          end
        end
      end

      if errors.empty?
        puts "ok: [#{host.name}]".colorize(:green)
        @results[host.name]["ok"] += 1
      else
        puts "failed: [#{host.name}]".colorize(:red)
        puts "  Message: Validation of arguments failed:\n    #{errors.join("\n    ")}".colorize(:red)
        @results[host.name]["failed"] += 1
        @halted_hosts.add(host.name) unless task.ignore_errors
      end
    end

    # Whether *value* is compatible with a declared argument_specs.yml
    # `type:`. Lenient by design (matching ansible-core's own AnsibleModule
    # type coercion, which accepts a numeric string for `int`, a single
    # scalar promoted to a one-element list for `list`, etc.) - this only
    # flags a value that's unambiguously the wrong shape (a Hash/Array
    # where a scalar was declared, or vice versa), not every case real
    # Ansible's coercion would technically also accept.
    private def argument_type_matches?(value : JSON::Any, declared_type : String) : Bool
      case declared_type
      when "list"
        true # a bare scalar is promoted to a one-element list; always compatible
      when "dict"
        value.raw.is_a?(Hash)
      when "bool"
        !value.raw.is_a?(Hash) && !value.raw.is_a?(Array)
      when "int", "float"
        case value.raw
        when Int64, Int32, Float64 then true
        when String                then value.as_s.to_f64? != nil
        # Python's bool is a subclass of int (isinstance(True, int) is
        # True) - real ansible-core's own argument-spec validator
        # accepts a bool value for a declared int/float param on that
        # basis. dev-sec mysql_hardening's own argument_specs.yml
        # declares mysql_hardening_skip_show_database as `type: int,
        # default: 1` while defaults/main.yml sets it to the literal
        # boolean `true` - a real (if sloppy) mismatch in the role
        # itself that real ansible-playbook tolerates via this exact
        # coercion; rejecting it here failed the role's own argument-
        # spec validation task before any hardening logic ever ran.
        when Bool                  then true
        else                             false
        end
      when "path", "str", "raw"
        true # ansible-core stringifies almost anything for these
      else
        true # an unrecognized declared type (jsonarg, etc.) - don't guess
      end
    end

    private def json_type_name(value : JSON::Any) : String
      case value.raw
      when Hash    then "dict"
      when Array   then "list"
      when Bool    then "bool"
      when Int64, Int32 then "int"
      when Float64 then "float"
      else              "str"
      end
    end

    # Resolve with_fileglob patterns (if any) against the control host's
    # filesystem, after substituting any {{ vars }} in the pattern.
    private def resolve_fileglob(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : Array(JSON::Any)?
      patterns = task.loop_fileglob
      return nil unless patterns

      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      matches = [] of String

      patterns.each do |pattern|
        substituted = substitutor.substitute(pattern)

        # `with_fileglob: "{{ some_list_var }}"` (a single templated
        # value that evaluates to a LIST of patterns, real Ansible's own
        # idiom for e.g. cloudalchemy.prometheus's own
        # `prometheus_alert_rules_files: [prometheus/rules/*.rules]`) -
        # #substitute has no notion of the underlying value being a real
        # array, so it rendered the whole thing as the JSON-array TEXT
        # (`["prometheus/rules/*.rules"]`, literal brackets and quotes
        # included) and handed that straight to Dir.glob as one pattern -
        # its own bracket syntax means "character class", so an
        # unbalanced/malformed one (as this always was) raised
        # Regex::Error ("unterminated character set") instead of
        # matching real files. A real single-file glob pattern never
        # starts with "[" this way (that would mean "match one char from
        # this set" as the pattern's very first token, not a realistic
        # glob), so parsing it back as JSON here is safe.
        if substituted.starts_with?('[')
          parsed = (JSON.parse(substituted).as_a? rescue nil)
          if parsed
            parsed.each { |item| matches.concat(Dir.glob(item.to_s)) }
            next
          end
        end

        matches.concat(Dir.glob(substituted))
      end

      matches.sort!
      matches.map { |path| JSON::Any.new(path) }
    end

    # Resolve a loop:/with_items:/with_dict:/with_nested:/with_indexed_items:
    # given as "{{ some_var }}" against the runtime variable context, then
    # feed it through the same conversion each keyword uses for a literal
    # value at parse time (see PlaybookParser#parse_task).
    private def resolve_loop_template(task : Task, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      kind = task.loop_template_kind
      template = task.loop_template
      return nil unless kind && template

      value = resolve_template_value(template, vars_context)

      # A complex template - `with_items: "{{ some_list | default([]) |
      # map(attribute='path') | difference(another | list) }}"` (used by
      # dev-sec os_hardening's yum gpg-check tasks) - isn't a plain variable
      # reference, so resolve_template_value returns nil. Evaluate it as a
      # filter chain via ExpressionEvaluator instead, then parse the
      # resulting (possibly empty) list into loop items. Without this the
      # loop resolved to nil, the task ran once, and `item` was the literal
      # `{{ ... }}` template string.
      unless value
        # Strip any {{ }} wrapper around the template expression, then
        # hand the bare expression to the filter-chain evaluator.
        bare = template.strip
        if bare.starts_with?("{{") && bare.ends_with?("}}")
          bare = bare[2..-3].strip
        end
        result = expression_evaluator_for(vars_context).evaluate(bare)

        if kind == "with_dict"
          # A with_dict: filter chain (dev-sec os_hardening's sysctl
          # tasks: `sysctl_config | combine(...) | combine(...)`) renders
          # to JSON object text via VariableLookup#format_value, not an
          # array - parse_list_result's as_a? would reject it outright
          # (a plain filter-chain gap here used to make the whole loop
          # resolve to nil, running the task once with `item` undefined).
          hash_result = (JSON.parse(result).as_h? rescue nil)
          return hash_result ? LoopResolver.with_dict(hash_result.transform_keys(&.to_s)) : nil
        end

        parsed = parse_list_result(result, vars_context)
        return parsed unless parsed.nil?
        return nil
      end

      case kind
      when "loop", "with_items"
        # A single-element array holding one bare `{{ var }}` span
        # (`with_items: ["{{ scalar_var }}"]`/`loop: ["{{ scalar_var
        # }}"]`) is what routed this whole task here in the first place
        # (see find_loop_template's own "flatten one level" comment) -
        # but that parse-time heuristic can't know whether `var` will
        # turn out to be a list or a scalar; only this runtime
        # resolution can. `value.as_a?` alone returns nil for a scalar,
        # which fell through every other resolver too and left the task
        # with NO loop items at all - not skipped, not looped, just run
        # once with `item` whatever (usually nothing) happened to
        # already be in scope, silently "undefined" instead of the
        # real value. Verified against real ansible-playbook directly:
        # both `loop:` and `with_items:` treat a resolved-to-scalar
        # single-element list as exactly one iteration with that scalar
        # as `item`, identically - not just with_items:'s own
        # documented legacy flatten behavior.
        value.as_a? || [value]
      when "with_dict"
        hash = value.as_h?
        return nil unless hash
        LoopResolver.with_dict(hash.transform_keys(&.to_s))
      when "with_nested"
        list = value.as_a?
        return nil unless list
        lists = list.map { |entry| entry.as_a? || [entry] }
        LoopResolver.with_nested(lists)
      when "with_indexed_items"
        list = value.as_a?
        return nil unless list
        LoopResolver.with_indexed_items(list)
      end
    end

    # A shared ExpressionEvaluator for a given vars context (used to resolve
    # a loop template that carries a filter chain).
    private def expression_evaluator_for(vars_context : Hash(String, JSON::Any))
      VariableSubstitutor::ExpressionEvaluator.new(vars_context)
    end

    # Parse *result* (the string output of evaluating a loop template) into a
    # list of JSON items. The evaluator stringifies, so an already-JSON
    # encoded list comes back as JSON text and is parsed back here; any other
    # emissions are treated as unresolvable (nil), matching a nil lookup.
    private def parse_list_result(result : String, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      return nil if result.empty?
      text = result.strip
      parsed = JSON.parse(text) rescue nil
      return nil unless parsed
      parsed.as_a?
    end

    # with_subelements(list, key): resolve the *list* template (usually a
    # registered `{{ var.results }}`) to a list of dicts, then yield
    # [parent_dict, subelement] pairs for each element of each dict's `key`
    # sub-list. Returns nil when the task has no with_subelements source.
    private def resolve_loop_subelements(task : Task, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      key = task.loop_subelements_key
      list_template = task.loop_subelements_list
      return nil unless key && list_template

      value = resolve_template_value(list_template, vars_context)
      return nil unless value
      list = value.as_a? || [] of JSON::Any

      LoopResolver.with_subelements(list, key)
    end

    # with_community.general.flattened: resolve each raw source string
    # (normally `{{ some_list_var }}`) against the variable context, collect
    # the resulting lists, and flatten them into one loop-item list in
    # source order. A source that resolves to a non-list (e.g. an undefined
    # var) yields no items, matching the collection's tolerance for optional
    # source lists. Returns the flattened items, or nil when the task has no
    # flattened source at all.
    private def resolve_loop_flattened(task : Task, vars_context : Hash(String, JSON::Any), host_name : String = "localhost") : Array(JSON::Any)?
      sources = task.loop_flattened
      return nil unless sources

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
      result = [] of JSON::Any
      sources.each do |raw|
        value = resolve_template_value(raw, vars_context)

        # A complex template - `"{{ sys_accs_cond | default([]) |
        # difference(os_ignore_users) | list }}"` (dev-sec os_hardening's
        # own "change system accounts" task) - isn't a plain variable
        # reference, so #resolve_template_value returns nil.
        # #resolve_template_value only understands a bare `{{ var }}`/
        # `{{ var.dotted }}` shape; mirror #resolve_loop_template's own
        # ExpressionEvaluator fallback for anything `{{ }}`-wrapped but
        # more complex than that, before ever falling through to
        # "treat the whole source as one literal string item" below -
        # otherwise the filter chain rendered to ONE JSON-array-shaped
        # STRING ("[\"daemon\",\"bin\",...]") pushed as a single item,
        # instead of being evaluated and flattened into real per-item
        # loop iterations (`user: name={{ item }}` then tried to
        # useradd a literal string containing commas and brackets as
        # one username).
        stripped = raw.strip
        if !value && stripped.starts_with?("{{") && stripped.ends_with?("}}")
          bare = stripped[2..-3].strip
          rendered = expression_evaluator_for(vars_context).evaluate(bare)
          # Real bug found benchmarking devsec.hardening.mysql_hardening
          # (round 24 role 2): the source `{{ mysql_users_wo_passwords
          # .query_result }}` (no `| default(...)` filter - this source's
          # `when:` clause skipped its task on modern MariaDB so the
          # register was never set) renders through the bare-variable
          # path to the literal string `"undefined"`. parse_list_result
          # correctly returns nil on "undefined" (it isn't valid JSON),
          # but then the code falls through to the literal-source branch
          # below and pushes the substituted raw template as ONE loop
          # item, producing a single `item=undefined` iteration that
          # then crashes downstream as `DROP USER undefined@%`. Real
          # Ansible's with_community.general.flattened correctly yields
          # zero items for a missing-var source (skipping the whole
          # task when all sources are empty). The "undefined" sentinel
          # is the project's own (well-established) convention for
          # "no value", and the same with_community.general.flattened
          # code path already does the analogous skip for the `{{ var |
          # default([]) }}` shape - this just makes the no-filter
          # bare-`{{ var }}` shape match the same skip behavior. The
          # check is `rendered.strip not in no-value sentinels` rather
          # than a more general "parse as JSON" because the whole
          # point is that the strings "undefined", "", "[]", and "{}"
          # are the project's own no-value sentinels (a bare
          # `{{ missing_var }}` reference renders to "undefined"; a
          # `{{ missing_var | default([]) }}` filter chain where the
          # whole `missing_var` is undefined renders to ""; a
          # `{{ existing_var.list | default([]) }}` chain where the
          # var IS set but the underlying value is itself an empty
          # list renders to "[]"; same for "{}" on an empty dict). A
          # filter chain that legitimately produced a non-empty list,
          # a non-empty dict, a string, or any other value would never
          # render to any of these four strings through this
          # evaluator.
          if rendered.strip != "undefined" && rendered.strip != "" && rendered.strip != "[]" && rendered.strip != "{}" && (parsed = parse_list_result(rendered, vars_context))
            value = JSON::Any.new(parsed)
          end
        end

        if value
          if value.raw.is_a?(Array)
            value.as_a.each do |item|
              # Flatten one level of board nesting, matching the
              # collection's flattened semantics for a list-of-lists source.
              if item.raw.is_a?(Array)
                item.as_a.each { |leaf| result << leaf }
              else
                result << item
              end
            end
          else
            result << value
          end
        else
          # A literal source (not a bare `{{ var }}` reference or a
          # `{{ }}`-wrapped filter-chain expression at all) - dev-sec
          # os_hardening's own with_flattened sources are mostly plain
          # literal paths ('/usr/local/sbin', '/usr/local/bin', ...)
          # mixed with exactly one templated (often-empty-by-default)
          # list source. Previously `next unless value` dropped every
          # literal source outright, so a loop mixing literal paths with
          # one templated source produced ZERO items instead of the
          # literal paths themselves - found via os-hardening's own
          # "find files with write-permissions for group" task (6
          # literal paths + `{{ os_env_extra_user_paths }}`, default
          # `[]`), which skipped outright instead of running find
          # against any of the 6 real directories. Still substituted
          # (not just pushed raw) in case a literal source has `{{ }}`
          # embedded alongside other text, not only as the whole string.
          #
          # A `{{ }}`-wrapped source whose only variable is missing
          # also lands here (the complex-template fallback at the
          # top of this loop ALSO returns nil for it now - see the
          # `rendered.strip != "undefined"` guard there). The same
          # skip-for-missing-var policy applies: a substituted result
          # that is one of the project's own no-value sentinels - the
          # literal string "undefined" (a bare `{{ missing_var }}`
          # reference), the empty string "" (a `{{ missing_var |
          # default([]) }}` filter chain where the filter's
          # undefined?-check on a fully-missing variable doesn't
          # trigger the default - verified by test_eval9.cr: `q.r |
          # default([])` with `q` missing returns ""), OR the string
          # "[]" (a `{{ existing_var.query_result | default([]) }}`
          # chain where the var IS set but the underlying value is
          # itself an empty list, so the finalization renders it as
          # the JSON-string "[]") - is "no value", not "one item with
          # that value". Real Ansible's with_community.general.
          # flattened yields zero items for any of these no-value
          # sentinels. Pushing the bogus value would cascade into
          # downstream `{{ item.X }}` rendering as "undefined" again
          # (or as nothing for ""), which then crashes for any tool
          # that tries to use the bogus value (devsec.mysql_hardening's
          # DROP USER undefined@% is the live example that surfaced
          # this). A legitimate literal source that wants the bare
          # string "[]" pushed as one item is implausible - roles
          # iterate lists, not the string representation of a list.
          substituted = substitutor.substitute(raw).strip
          case substituted
          when "undefined", "", "[]", "{}"
            # no items from this source - all four are "the engine
            # has no value to give this loop" sentinels
          else
            result << JSON::Any.new(substituted)
          end
        end
      end
      result
    end

    # Resolve a bare "{{ expr }}" template (optionally with leading/trailing
    # whitespace) to the underlying JSON value from the variable context,
    # preserving arrays/hashes rather than flattening to a string the way
    # VarSubstitutor#substitute does. Supports simple and dotted variable
    # references (e.g. "some_var" or "some_dict.key"); anything more complex
    # (filters, expressions) isn't a variable reference and returns nil.
    private def resolve_template_value(template : String, vars_context : Hash(String, JSON::Any)) : JSON::Any?
      match = template.strip.match(/\A\{\{\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\}\}\z/)
      return nil unless match

      parts = match[1].split(".")
      current = vars_context[parts[0]]?
      parts[1..].each do |part|
        break unless current
        current = current.as_h?.try(&.[part]?)
      end

      # Audit pass (2026-08-11), a 10th copy of the recursive-re-
      # templating gap found alongside deep_render_item's own fix: a
      # loop: source itself (`loop: "{{ templated_default }}"`) whose
      # raw value is itself unrendered Jinja (a role default computed
      # from another default) was returned as-is - the caller's own
      # `value.as_a?`/`value.as_h?` checks then always failed against
      # the literal "{{ ... }}" text, so the loop silently resolved to
      # no items at all.
      if current && (raw = current.raw).is_a?(String) && raw.includes?("{{")
        inner = raw.strip
        inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
        rendered = VariableSubstitutor::ExpressionEvaluator.new(vars_context).evaluate(inner)
        current = (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
      end

      current
    end

    # Evaluates task.when_condition (if any) against vars_context, printing
    # "skipping: [...]" and bumping the skipped counter when it's false -
    # shared by execute_task_once and the batch-group trigger path
    # (execute_batch_group) so both interpret when: identically.
    #
    # `defer_stats`: when true (a loop item), the skipped counter is NOT
    # bumped here. Real Ansible counts a looped task once in the recap, not
    # once per skipped item - loop-aggregation happens once in
    # finish_looped_task, so a loop that ends up with zero executed items is
    # recorded as a single "skipped". Deferring avoids per-item skipped
    # inflation (a 5-item all-skipped loop must be skipped=1, not skipped=5).
    private def when_passes?(task : Task, vars_context : Hash(String, JSON::Any), host : Host, item_label : String? = nil, shared : VarSubstitutor? = nil, defer_stats : Bool = false, defer_display : Bool = false) : Bool
      return true unless when_condition = task.when_condition

      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      substituted_condition = substitutor.substitute(when_condition)

      return true if ConditionalEvaluator.evaluate(substituted_condition, vars_context)

      # defer_stats: loop items and batch members pass this to only skip
      # the *counter* bump (aggregation happens once at the task level).
      # It does NOT suppress the print: loop items must still print their
      # per-item `skipping: [host] => (item=x)` line.
      unless defer_stats
        @results[host.name]["skipped"] += 1
      end

      # defer_display: additionally suppress the print, used by batch
      # members. execute_batch_group evaluates every member's when: while
      # building the group's single SSH round trip - printing each "skipping:"
      # there would emit all the group's skips at once, under the first
      # member's banner, instead of each under its own. The member's skip
      # print is deferred and emitted by execute_task when it consumes the
      # nil (skipped) result from the batch cache, in proper task order.
      unless defer_display
        suffix = item_label ? " => (item=#{item_label})" : ""
        puts "skipping: [#{host.connection_host}]#{suffix}".colorize(:cyan)
      end
      register_skip_result(task, host)
      false
    end

    # A skipped task's own register: still gets set (to a `changed:
    # false, skipped: true` result, matching real Ansible) rather than
    # left holding whatever a previous task/loop iteration happened to
    # register under the same name. Without this, dev-sec os_hardening's
    # `register: mountpoint` / `when: mountpoint.changed` pair (each
    # include_tasks loop iteration reusing the same register name) leaks
    # a *prior* iteration's real "changed" result into a later iteration
    # whose own task was skipped, wrongly running the dependent task.
    private def register_skip_result(task : Task, host : Host)
      register_name = task.register
      return if register_name.nil? || register_name.empty?

      register_result(host, register_name, JSON.parse({
        "changed"     => false,
        "skipped"     => true,
        "skip_reason" => "Conditional result was False",
      }.to_json))
    end

    # Reports a when:-skipped batch member: the print and skipped counter
    # were deferred by execute_batch_group (defer_display/defer_stats) so
    # the group's skips don't all appear during batch-build; this emits
    # them here, as execute_task consumes each member in task order. Mirrors
    # what when_passes? does for the solo path.
    private def print_batched_skip(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Nil
      puts "skipping: [#{host.connection_host}]".colorize(:cyan)
      @results[host.name]["skipped"] += 1
    end

    # Populates @task_group for *tasks* (a flat task list - a play's own
    # top-level tasks, or one block's/rescue's/always's nested list) the
    # first time it's seen, via TaskBatcher.plan. No-op if batching is
    # disabled or this exact list has already been planned.
    private def ensure_grouped(tasks : Array(Task))
      return unless @batching_enabled

      key = tasks.object_id
      return if @grouped_lists.includes?(key)
      @grouped_lists << key

      TaskBatcher.plan(tasks).each do |group|
        next if group.size < 2
        group.each { |member| @task_group[member] = group }
      end
    end

    # Entry point called from execute_task for the plain (non-looped,
    # non-until:, non-async:) execution path. Returns {false, nil} if
    # batching doesn't apply to this task/host at all (not part of a
    # group, a delegate_to: divergence, or a local connection) - the
    # caller falls through to the normal execute_task_once path in that
    # case, completely unaffected. Returns {true, result} if it does -
    # result is nil only when this specific task's own when: was false
    # (already fully handled: printed, counted, cached), exactly matching
    # what execute_task_once returns for a skipped task.
    private def try_batched_result(task : Task, host : Host, vars_context : Hash(String, JSON::Any), exec_host : Host) : {Bool, JSON::Any?}
      return {false, nil} unless @batching_enabled
      return {false, nil} unless exec_host == host
      return {false, nil} if PluginManager.is_local_connection?(exec_host, vars_context)

      group = @task_group[task]?
      return {false, nil} unless group

      cache = (@batch_cache[host.name] ||= Hash(Task, {JSON::Any?, Hash(String, JSON::Any)}).new)

      # "Has this group already run on this host?" is tracked separately
      # from the cache's *contents*, precisely so consumed entries can be
      # evicted below. Keying the trigger check off `cache.has_key?
      # (group.first)` (as it used to) would make evicting group.first
      # cause the next member of the same group to re-run the entire
      # remote script - re-executing real side effects.
      group_key = {host.name, group.object_id}
      unless @batch_groups_run.includes?(group_key)
        @batch_groups_run << group_key
        # `task` is the group's trigger - its vars_context was already
        # built by the caller (execute_task), so hand it over instead of
        # having execute_batch_group build an identical one again.
        execute_batch_group(group, host, task, vars_context)
      end

      # Consumed exactly once per (task, host), so the entry is removed as
      # it is read. Each entry retains a full copy of that task's variable
      # context (~3.9 kB in a realistic run); nothing used to remove them,
      # so a play held N_tasks x N_hosts contexts alive until the whole
      # TaskExecutor was dropped - tens of MB for a large play under the
      # very --forks fan-out that makes big inventories attractive.
      #
      # Safe against the other reader: execute_task reads this same
      # entry's vars_context (index 1) *before* it calls into here, so by
      # the time the result (index 0) is read the context is no longer
      # needed. A member with no entry at all (the script halted before
      # reaching it) still yields nil, exactly as `cache[task]?` did.
      {true, cache.delete(task).try(&.[0])}
    end

    # Builds and runs the single SSH round trip for *group* against
    # *host*, populating @batch_cache[host.name] for every member that
    # either got a real result or was when:-skipped. A member that never
    # ran at all (the script halted at an earlier member, or an earlier
    # member's own action-plugin - e.g. template: - failed before any
    # remote call was even needed) gets NO cache entry; that's fine
    # because the failing member's own result (which DOES get a real
    # entry) sets @halted_hosts once the task-major loop processes it via
    # finish_single_task, and the loop's existing `next if
    # @halted_hosts.includes?(...)` guard then naturally skips ever
    # looking the later members up at all.
    #
    # Deliberately does none of the "did this task succeed/fail" side
    # effects itself (no register:/notify:/stats/display/halt) - those
    # all still happen exactly once, lazily, when the task-major loop
    # reaches each member and consumes it from the cache via
    # finish_single_task, in the same order it always has. This method's
    # only job is to fill the cache.
    private def execute_batch_group(
      group : Array(Task),
      host : Host,
      trigger_task : Task? = nil,
      trigger_vars_context : Hash(String, JSON::Any)? = nil,
    )
      cache = (@batch_cache[host.name] ||= Hash(Task, {JSON::Any?, Hash(String, JSON::Any)}).new)

      steps = [] of BatchScript::Step
      step_tasks = [] of Task
      step_vars = [] of Hash(String, JSON::Any)
      halted = false

      group.each do |task|
        break if halted

        vars_context = if task == trigger_task && (reused = trigger_vars_context)
                         reused
                       else
                         build_vars_context(task, host)
                       end

        # Same sharing as the solo path: when: and the step preparation
        # both read this member's identical vars_context.
        member_substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

        # defer_stats + defer_display: a when:-skipped batch member has its
        # skipped counter AND its "skipping:" print both deferred - the
        # counter aggregates at the task level, and the print is emitted by
        # execute_task when it consumes this nil from the cache, so each
        # group member's skip prints under its own banner rather than all
        # at once here during batch-build.
        unless when_passes?(task, vars_context, host, shared: member_substitutor, defer_stats: true, defer_display: true)
          cache[task] = {nil, vars_context}
          next
        end

        case outcome = prepare_batch_step(task, host, vars_context, shared: member_substitutor)
        when JSON::Any
          cache[task] = {outcome, vars_context}
          failed = outcome["failed"]?.try(&.as_bool) || false
          halted = true if failed && !task.ignore_errors
        when BatchScript::Step
          steps << outcome
          step_tasks << task
          step_vars << vars_context
        end
      end

      return if steps.empty?

      connection_host = PluginManager.get_connection_host(host, step_vars.first)
      step_results = run_batch_script(host, connection_host, steps)

      steps.each_index do |idx|
        next unless r = step_results[idx]?

        task = step_tasks[idx]
        vars_context = step_vars[idx]
        interpreted = PluginManager.interpret_remote_result(r.exit_code, r.stdout, r.stderr)
        cache[task] = {apply_changed_failed_when(task, interpreted, vars_context, host), vars_context}
      end
    end

    # Shared "run this batch script in one SSH round trip and parse the
    # results back" middle, used by both execute_batch_group (mixed
    # tasks) and execute_looped_task's batched path (iterations of one
    # task) - the two callers differ only in how they produce *steps*.
    private def run_batch_script(host : Host, connection_host : String, steps : Array(BatchScript::Step)) : Hash(Int32, BatchScript::StepResult)
      batch_id = Random::Secure.hex(8)
      script = BatchScript.build(batch_id, steps)
      raw = SSHManager.exec_script(connection_host, host.user || "root", script, host.port, identity_file: host.vars["ansible_ssh_private_key_file"]?.try(&.as_s?))
      BatchScript.parse(raw[:stdout])
    end

    # Prepares one batch-group member up to (but not including) the
    # actual remote call - when: has already been checked by the caller.
    # Mirrors execute_task_once's own param-substitution/action-plugin/
    # config-building steps exactly, so a batched task's config is
    # byte-for-byte what a solo execution would have sent.
    #
    # Returns a JSON::Any if the task already has a final result without
    # ever needing a remote call (only possible today via an action
    # plugin - e.g. template: - failing to render, or an invalid
    # become_user:), or a BatchScript::Step ready to send otherwise.
    # Resolves a task's real become: value, re-rendering task.become_expr
    # against live vars if the YAML source was a templated expression
    # (`become: "{{ vault_privileged_install }}"`) rather than a literal
    # boolean. Parse time has no host/role vars context to render this
    # against, so the parser stashes the raw expression text and this is
    # where it actually gets evaluated - falls back to task.become (the
    # parser's best-effort literal guess) if there's no expr, or if
    # rendering it produces something ConditionalEvaluator can't use.
    private def resolve_task_become(task : Task, substitutor : VarSubstitutor) : Bool
      expr = task.become_expr
      return task.become unless expr

      rendered = substitutor.substitute(expr)
      ConditionalEvaluator.evaluate(rendered, {} of String => JSON::Any) rescue task.become
    end

    private def prepare_batch_step(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : JSON::Any | BatchScript::Step
      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      substituted_params = substitute_task_params(task.params, substitutor)
      substituted_params = resolve_role_relative_src(task, substituted_params)
      substituted_params = inline_copy_source_content(task, substituted_params, host, vars_context)
      substituted_params = stage_unarchive_remote_src(task, substituted_params, host, vars_context)
      substituted_params = stage_script_src(task, substituted_params, host, vars_context)
      substituted_params = stage_assemble_dir(task, substituted_params, host, vars_context)
      substituted_become_user = task.become_user.try { |raw_user| substitutor.substitute(raw_user) }

      if ActionPluginManager.has_action_plugin?(task.module_name)
        action_result = ActionPluginManager.execute_action(task.module_name, substituted_params, vars_context, host)

        unless action_result.success
          failed = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }.to_json)
          return apply_changed_failed_when(task, failed, vars_context, host)
        end

        # debug:/assert:/fail:/set_fact:/pause: - the action plugin
        # already computed the whole task result on the controller (see
        # ActionResult#final_result's own comment). No module upload/
        # dispatch of any kind, batched or not.
        if final = action_result.final_result
          return apply_changed_failed_when(task, final, vars_context, host)
        end

        substituted_params = action_result.modified_params || substituted_params
      end

      become = resolve_task_become(task, substitutor)
      become_user = nil

      if become
        candidate = substituted_become_user
        become_user = (candidate.nil? || candidate.empty?) ? "root" : candidate

        unless PluginManager.valid_become_user?(become_user)
          failed = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "become_user #{become_user.inspect} is not a valid username",
          }.to_json)
          return apply_changed_failed_when(task, failed, vars_context, host)
        end
      end

      # Same override execute_remote_plugin applies to the wire payload
      # only (never to vars_context itself, which stays the controller's
      # own view for when:/changed_when:/failed_when: evaluation) - once
      # a plugin is actually running on the remote, its own internal
      # local-vs-remote logic needs to see itself as local.
      remote_vars_context = vars_context.dup
      remote_vars_context["ansible_connection"] = JSON::Any.new("local")

      config_json = build_plugin_config(task, host, substituted_params, remote_vars_context, substituted_become_user)

      # The batch script runs the plugin binary directly, so it must be on
      # the target before the script is built - pre-upload cannot see
      # modules that only appear inside a runtime include_tasks:.
      PluginManager.ensure_uploaded(host, task.module_name, vars_context)
      plugin_target = PluginManager.remote_plugin_target(task.module_name, become, become_user)

      BatchScript::Step.new(plugin_target, config_json, task.ignore_errors)
    end

    # Run one attempt of a task (when: check + param substitution + action
    # plugin + module execution). Returns nil if the when: condition skipped
    # it (the skipped counter is already updated in that case).
    private def execute_task_once(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      item_label : String? = nil,
      exec_host : Host = host,
      shared : VarSubstitutor? = nil,
      defer_loop_stats : Bool = false
    ) : JSON::Any?
      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)

      return nil unless when_passes?(task, vars_context, host, item_label, shared: substitutor, defer_stats: defer_loop_stats)

      begin
        substituted_params = substitute_task_params(task.params, substitutor)
      rescue ex
        # A raised exception during param substitution (e.g. lookup('url',
        # ...) hitting a real HTTP error - see ExpressionEvaluator#
        # fetch_url_lines's own comment) means real Ansible's own
        # "finalization of task args failed" hard stop: it fails the
        # ENCLOSING TASK cleanly (one recap entry, playbook continues to
        # whatever's next per normal when:/rescue: semantics), not the
        # whole run. Before this rescue existed, nothing in the call
        # chain up through crystal-play.cr's own top-level `run` caught
        # such an exception at all, so it crashed the entire process
        # with an unhandled-exception stack trace instead - found
        # benchmarking buluma.victoriametrics's own `set_fact: _checksums:
        # "{{ lookup('url', ...) }}"` against a 404'd release checksums
        # file (a broken-upstream default, but real Ansible still
        # degrades to one clean failed task, not a crash).
        result = JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => ex.message || "Failed to resolve task arguments",
        }.to_json)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      if task.module_name == "ansible.builtin.reboot"
        result = execute_reboot(substituted_params, exec_host, vars_context)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      if task.module_name == "ansible.builtin.group_by"
        result = execute_group_by(substituted_params, host)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      if task.module_name == "ansible.builtin.set_stats"
        result = execute_set_stats(substituted_params, host, vars_context)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      substituted_params = resolve_role_relative_src(task, substituted_params)
      substituted_params = inline_copy_source_content(task, substituted_params, exec_host, vars_context)
      substituted_params = stage_unarchive_remote_src(task, substituted_params, exec_host, vars_context)
      substituted_params = stage_script_src(task, substituted_params, exec_host, vars_context)
      substituted_params = stage_assemble_dir(task, substituted_params, exec_host, vars_context)
      # become_user: goes through the same {{ }} substitution as any
      # params: value (e.g. become_user: "{{ service_user }}", a common
      # real-playbook pattern) - task.become_user itself is never mutated
      # here, since Task is shared/reused across hosts and loop iterations.
      substituted_become_user = task.become_user.try { |raw_user| substitutor.substitute(raw_user) }

      if ActionPluginManager.has_action_plugin?(task.module_name)
        action_result = ActionPluginManager.execute_action(
          task.module_name,
          substituted_params,
          vars_context,
          exec_host
        )

        unless action_result.success
          result = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }.to_json)
          return apply_changed_failed_when(task, result, vars_context, host)
        end

        if final = action_result.final_result
          return apply_changed_failed_when(task, final, vars_context, host)
        end

        if modified_params = action_result.modified_params
          substituted_params = modified_params
        end
      end

      # Same override execute_remote_plugin used to apply to the wire
      # payload only (never to vars_context itself, which stays the
      # controller's own view for when:/changed_when:/failed_when:
      # evaluation) - once a plugin is actually running on the remote,
      # its own internal local-vs-remote logic needs to see itself as
      # local. Deciding it *before* serializing is what lets the config
      # be built exactly once here, the way prepare_batch_step already
      # builds it once for the batch path; this used to serialize, parse,
      # then dup and re-serialize the entire variable context.
      wire_vars = vars_context
      if PluginManager.remote_execution?(task.module_name, exec_host, vars_context)
        wire_vars = vars_context.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      config = build_plugin_config(task, exec_host, substituted_params, wire_vars, substituted_become_user)

      if task.async_seconds && !@check_mode
        # async: writes this config verbatim to a job file; the detached
        # __async_run process resolves become:/become_user: back out of
        # it via the JSON::Any entry point, exactly as before.
        return apply_changed_failed_when(task, execute_async(task, exec_host, config), vars_context, host)
      end

      # The same become resolution and validation resolve_become used to
      # perform from inside PluginManager, hoisted to the call site so
      # the config String can be handed straight through without being
      # parsed again. Identical defaults (become_user "root" when become:
      # is set but become_user: isn't) and identical error message -
      # and identical to what prepare_batch_step does for the batch path.
      become = resolve_task_become(task, substitutor)
      become_user = nil

      if become
        candidate = substituted_become_user
        become_user = (candidate.nil? || candidate.empty?) ? "root" : candidate

        unless PluginManager.valid_become_user?(become_user)
          failed = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "become_user #{become_user.inspect} is not a valid username",
          }.to_json)
          return apply_changed_failed_when(task, failed, vars_context, host)
        end
      end

      result = PluginManager.execute_plugin(
        task.module_name,
        config,
        exec_host,
        vars_context,
        become,
        become_user
      )

      apply_changed_failed_when(task, result, vars_context, host)
    end

    # async:/poll: - runs the module as a detached background OS process
    # (spawned via a hidden `__async_run` re-invocation of this same
    # binary, not a Fiber, so the job survives even if the poll loop or
    # the whole playbook run finishes first - closer to how real Ansible's
    # background job outlives the control connection). Local connections
    # only: genuine remote async needs a process that survives the SSH
    # session ending, which this codebase's plain exec-over-SSH connection
    # model doesn't support - a documented scope cut, not an oversight.
    private def execute_async(task : Task, exec_host : Host, config_json : String) : JSON::Any
      is_local = exec_host.vars["ansible_connection"]?.try(&.as_s?) == "local" || exec_host.name == "localhost" || exec_host.name == "127.0.0.1"
      unless is_local
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "async: is only supported for local connections in crystal-ansible",
        }.to_json)
      end

      jid = AsyncJobs.generate_jid
      AsyncJobs.write_status(jid, JSON.parse({
        "started"        => 1,
        "finished"       => 0,
        "ansible_job_id" => jid,
      }.to_json))
      File.write(AsyncJobs.config_path(jid), config_json)

      executable = Process.executable_path || File.join(Dir.current, "crystal-ansible")
      Process.new(
        executable,
        ["__async_run", task.module_name, AsyncJobs.config_path(jid), AsyncJobs.status_path(jid)],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )

      poll = task.poll_seconds || 10
      if poll <= 0
        return JSON.parse({
          "changed"        => true,
          "started"        => 1,
          "finished"       => 0,
          "ansible_job_id" => jid,
          "msg"            => "Job started: #{jid}",
        }.to_json)
      end

      deadline = Time.instant + task.async_seconds.not_nil!.seconds
      loop do
        sleep poll.seconds
        if status = AsyncJobs.read_status(jid)
          return status if AsyncJobs.finished?(status)
        end
        break if Time.instant >= deadline
      end

      JSON.parse({
        "changed"        => false,
        "failed"         => true,
        "msg"            => "async task did not complete within #{task.async_seconds} seconds",
        "ansible_job_id" => jid,
      }.to_json)
    end

    # ansible.builtin.reboot - entirely unimplemented before (silently
    # dropped at parse time, "Plugin not available"). Architecturally
    # can't be a normal plugin binary the way every other module here
    # works: those get uploaded to and run ON the target host, but a
    # reboot module's own process would die the instant the machine it's
    # running on actually reboots, before it could ever report back.
    # Real Ansible's own reboot module is a controller-side ACTION
    # plugin for exactly this reason - it issues the reboot command,
    # then polls the CONNECTION (not the remote process) until the host
    # goes away and comes back. Handled entirely here instead: issues
    # reboot_command over one SSH call (tolerating the connection dying
    # mid-command, which is the expected/successful outcome), waits
    # post_reboot_delay, then polls a trivial remote command (test_command
    # if given, else a bare `whoami`) until it succeeds or reboot_timeout
    # is exceeded. Found via robertdebock.common's own "Reboot" handler
    # (notified by "Set hostname"/"Fill /etc/hosts", `common_reboot:
    # true` by default) and robertdebock.update's own reboot-on-upgrade
    # handler - both very common real-world idioms, not narrow ones.
    #
    # local connection is intentionally left alone (returns changed:
    # false, failed: true) - rebooting the controller process's own
    # machine out from under itself has no safe/sane implementation here
    # and real Ansible's own module warns heavily against it too.
    # group_by: - like reboot:, has no uploaded plugin binary at all
    # (listed in AVAILABLE_PLUGINS purely so the task isn't dropped at
    # parse time as "Plugin not available"). Real Ansible implements it
    # as an action plugin that mutates the live inventory rather than
    # running anything on the target - mirrored here by mutating the
    # shared Inventory instance crystal-play.cr passes to every play's
    # TaskExecutor (the SAME object across the whole per-play loop, not
    # a copy - a later play's `hosts:` pattern lookup sees whatever
    # group membership an earlier play's group_by: task added). `key:`
    # may itself be comma-separated (a rarely-used real Ansible feature:
    # one task adding the host to several groups at once); `parents:` is
    # accepted and recorded via HostGroup#add_child for completeness,
    # though this codebase's own Inventory#get_hosts never actually
    # walks group hierarchy (only exact group-name matches), so it's
    # inert beyond documentation today - same limitation static
    # inventory group parent/child nesting already has here.
    private def execute_group_by(params : Hash(String, String), host : Host) : JSON::Any
      key = params["key"]?
      if key.nil? || key.empty?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "missing required argument: key"}.to_json)
      end

      inventory = @inventory
      unless inventory
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "group_by: no inventory available in this context"}.to_json)
      end

      group_names = key.split(",").map(&.strip).reject(&.empty?)
      parent_names = params["parents"]?.try(&.split(",").map(&.strip).reject(&.empty?)) || [] of String

      changed = false
      group_names.each do |group_name|
        group = inventory.get_or_create_group(group_name)
        unless group.hosts.has_key?(host.name)
          group.add_host(host)
          changed = true
        end
        parent_names.each { |parent_name| inventory.get_or_create_group(parent_name).add_child(group_name) }
      end

      JSON.parse({"changed" => changed, "failed" => false, "msg" => "", "groups" => group_names}.to_json)
    end

    # set_stats: - same "no uploaded plugin binary" category as
    # group_by:/reboot: above. Writes into CustomStats (a process-wide
    # accumulator, not scoped to this TaskExecutor instance - real
    # Ansible's own custom-stats block covers the WHOLE run, and
    # crystal-play.cr constructs a fresh TaskExecutor per play).
    private def execute_set_stats(params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : JSON::Any
      data_json = params["data"]?
      if data_json.nil? || data_json.empty?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "missing required argument: data"}.to_json)
      end

      data = JSON.parse(data_json) rescue nil
      unless data && data.as_h?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "data must be a dictionary of stat name -> value"}.to_json)
      end

      aggregate = !["false", "no", "0", "off"].includes?(params["aggregate"]?.try(&.downcase))
      per_host = ["true", "yes", "1", "on"].includes?(params["per_host"]?.try(&.downcase))

      data.as_h.each do |key, value|
        CustomStats.set(key, value, aggregate, host.name, per_host)
      end

      JSON.parse({"changed" => false, "failed" => false, "msg" => ""}.to_json)
    end

    private def execute_reboot(params : Hash(String, String), exec_host : Host, vars_context : Hash(String, JSON::Any)) : JSON::Any
      return JSON.parse({"changed" => true, "failed" => false, "msg" => "Would have rebooted"}.to_json) if @check_mode

      if PluginManager.is_local_connection?(exec_host, vars_context)
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "ansible.builtin.reboot is not supported over a local connection (would reboot the controller itself)",
        }.to_json)
      end

      reboot_timeout = params["reboot_timeout"]?.try(&.to_i?) || 600
      connect_timeout = params["connect_timeout"]?.try(&.to_i?) || 5
      pre_reboot_delay = params["pre_reboot_delay"]?.try(&.to_i?) || 2
      post_reboot_delay = params["post_reboot_delay"]?.try(&.to_i?) || 0
      test_command = params["test_command"]?.try { |v| v.empty? ? nil : v } || "whoami"
      reboot_command = params["reboot_command"]?.try { |v| v.empty? ? nil : v } || "systemctl reboot"

      connection_host = PluginManager.get_connection_host(exec_host, vars_context)
      user = exec_host.user || "root"
      identity_file = vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)

      sleep pre_reboot_delay.seconds if pre_reboot_delay > 0

      # A reboot command genuinely killing its own SSH session mid-
      # response (rc 255, broken pipe, etc.) is the EXPECTED successful
      # outcome here, not an error - only a clean non-zero exit from the
      # remote shell itself (the command was rejected outright, e.g.
      # permission denied) is worth surfacing.
      issue_result = SSHManager.exec(connection_host, user, "(sleep 1; #{reboot_command}) &", exec_host.port, timeout: 15, identity_file: identity_file) rescue nil
      if issue_result && issue_result[:exit_code] != 0 && issue_result[:exit_code] != 255 && !issue_result[:stderr].empty?
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Failed to issue reboot command: #{issue_result[:stderr]}",
        }.to_json)
      end

      # Give the box a moment to actually start going down before
      # polling for it to come back - polling immediately risks a false
      # "success" against the OLD, not-yet-dead SSH session/ControlMaster.
      sleep 5.seconds

      deadline = Time.instant + reboot_timeout.seconds
      reconnected = false
      until Time.instant >= deadline
        result = SSHManager.exec(connection_host, user, test_command, exec_host.port, timeout: connect_timeout, identity_file: identity_file) rescue nil
        if result && result[:exit_code] == 0
          reconnected = true
          break
        end
        sleep Math.min(connect_timeout, 5).seconds
      end

      unless reconnected
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Timed out waiting for #{connection_host} to come back after reboot (#{reboot_timeout}s)",
        }.to_json)
      end

      sleep post_reboot_delay.seconds if post_reboot_delay > 0

      JSON.parse({
        "changed"  => true,
        "failed"   => false,
        "rebooted" => true,
        "msg"      => "Reboot complete",
      }.to_json)
    end

    # Override a task's own changed/failed verdict with changed_when:/
    # failed_when:, evaluated against vars_context plus the task's own result
    # (made available under its own register: name, mirroring real Ansible -
    # a bare literal like "false" needs no register: at all; referencing a
    # result field like "result.rc" does). Same substitute-then-evaluate
    # pipeline as when_condition/until_condition.
    private def apply_changed_failed_when(task : Task, result : JSON::Any, vars_context : Hash(String, JSON::Any), host : Host) : JSON::Any
      changed_when = task.changed_when
      failed_when = task.failed_when
      return result unless changed_when || failed_when

      eval_context = vars_context
      if (register_name = task.register) && !register_name.empty?
        eval_context = vars_context.dup
        eval_context[register_name] = result
      end

      hash = result.as_h.dup

      # changed_when/failed_when share one substitutor: VarSubstitutor is
      # stateless with respect to a given vars hash (its only mutator,
      # set_variable, is never called from here), so building it twice
      # for the identical eval_context was pure waste.
      if changed_when || failed_when
        substitutor = VarSubstitutor.new(vars: eval_context, host_name: host.name)

        if changed_when
          hash["changed"] = JSON::Any.new(ConditionalEvaluator.evaluate(substitutor.substitute(changed_when), eval_context))
        end

        if failed_when
          hash["failed"] = JSON::Any.new(ConditionalEvaluator.evaluate(substitutor.substitute(failed_when), eval_context))
        end
      end

      JSON::Any.new(hash)
    end

    # Register / notify / display / update stats for a (non-looped) task result.
    # fact_host is where a set_fact:/fact-gathering module's ansible_facts
    # attach - normally `host` itself, but the delegate_to:/delegate_facts:
    # combination redirects it to the delegate target instead (real
    # Ansible's own documented meaning); register:/display/stats always
    # stay attributed to `host` regardless.
    private def finish_single_task(task : Task, host : Host, result : JSON::Any, fact_host : Host = host)
      merge_ansible_facts(fact_host, result)

      if register_name = task.register
        register_result(host, register_name, result) unless register_name.empty?
      end

      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        notify_handlers(task, host, notify_list)
      end

      if @adhoc
        ResultDisplay.display_adhoc_result(host, result)
      else
        ResultDisplay.display_result(host, result, @diff_mode)
      end
      ResultDisplay.update_stats(@results[host.name], result, task.ignore_errors)
      halt_if_failed(task, host, failed)
    end

    # Marks `host` as halted (no further tasks in this play run for it)
    # when `failed` and the task didn't opt out via ignore_errors:.
    private def halt_if_failed(task : Task, host : Host, failed : Bool)
      @halted_hosts.add(host.name) if failed && !task.ignore_errors
    end

    # Execute a task once per loop item, aggregating the per-item results
    # into a single registered variable (`{"changed": .., "results": [...]}`),
    # matching Ansible's shape for looped, registered tasks.
    private def execute_looped_task(
      task : Task,
      host : Host,
      base_vars_context : Hash(String, JSON::Any),
      loop_items : Array(JSON::Any),
      exec_host : Host = host
    )
      # Render each item *before* it's ever bound to "item" or checked
      # against when: - a literal loop: entry can itself be a template
      # string (dev-sec mysql_hardening's own "Ensure permissions on
      # mysql-datadir are correct": `loop: ["{{ mysql_settings.settings.
      # datadir }}", '{{ mysql_datadir | default("") }}']`, gated by
      # `when: item != ""`). Previously bound the raw unrendered text
      # (e.g. the literal string '{{ mysql_datadir | default("") }}') as
      # "item" - a later re-templating pass happening to fix up the
      # *param* substitution masked this for a task's own params, but
      # when:'s own item comparison saw the raw text directly: a
      # non-empty string regardless of what it would have rendered to,
      # so `item != ""` was always true and a should-have-been-skipped
      # item ran for real, on a bogus literal path.
      rendered_items = loop_items.map { |item| deep_render_item(item, base_vars_context, host.name) }

      # Per-item fact target, for delegate_to:/delegate_facts: - only ever
      # diverges from `host` in the non-batched branch below (batching is
      # excluded outright for a delegate_to: task by loop_batch_eligible?).
      fact_hosts = Array(Host).new(rendered_items.size, host)

      item_results = if loop_batch_eligible?(task, host, exec_host, base_vars_context)
                       execute_looped_task_batched(task, host, base_vars_context, rendered_items)
                     else
                       # A running (not re-dup'd-from-base) vars_context
                       # carries each iteration's ansible_facts forward
                       # into the next - real Ansible does the same for
                       # set_fact:, and dev-sec os_hardening's own account-
                       # list building depends on it: `set_fact:
                       # system_users: "{{ system_users | default([]) +
                       # [item] }}"` inside a loop needs iteration N to see
                       # iteration N-1's accumulated list, not the loop's
                       # starting value every time.
                       running_vars_context = base_vars_context.dup
                       loop_var = task.loop_var
                       index_var = task.index_var
                       rendered_items.map_with_index do |item, idx|
                         vars_context = running_vars_context.dup
                         vars_context["item"] = item
                         vars_context[loop_var] = item if loop_var
                         vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var

                         # A task-level vars: that references `item`
                         # (linux-system-roles/kernel_settings' own
                         # `vars: {new_item: "{{ {item.name: new_value}
                         # }}"}` on a looped set_fact:) was only ever
                         # rendered *once*, by build_vars_context, before
                         # this loop even started - when `item` was still
                         # unbound. Every iteration then reused that same
                         # first (wrong) rendered value instead of
                         # recomputing it against its own item. Restoring
                         # task.vars' original unrendered text before each
                         # iteration's render_task_vars call fixes this;
                         # cheap enough even for a task whose vars: don't
                         # reference item at all (identical result either
                         # way), so no need to detect which case this is.
                         #
                         # `task.vars` also carries an inherited "item"/
                         # loop_var binding when this task lives inside an
                         # include_tasks: file whose OWN include statement
                         # was itself looped (execute_include_tasks
                         # propagates the outer iteration's item into
                         # every included task's `vars` so a non-looped
                         # included task can still see it - see the
                         # comment there). When the included task ALSO has
                         # its own `loop:`, blindly re-applying every
                         # `task.vars` key here clobbered the fresh,
                         # correct inner-loop "item"/loop_var binding set
                         # two lines above with that stale OUTER value,
                         # right before this same key would otherwise have
                         # been used to render/execute the task - `{{ item
                         # }}` (or a custom loop_var) inside the included
                         # task's own loop resolved to the outer include's
                         # item on every inner iteration instead of the
                         # inner loop's real one. Found via robertdebock.
                         # diskspace's own `mount.yml`, `include_tasks:`d
                         # in a loop with `loop_var: mount`, whose own
                         # `mount | Check space available` task loops
                         # `ansible_facts['mounts']` under the default
                         # `item` - the disk-space assertion never once
                         # matched a real mount entry, so the whole role's
                         # actual purpose (failing on low disk space)
                         # silently never fired. The loop's own binding
                         # must always win over an inherited one for the
                         # same key.
                         task.vars.each do |key, raw_value|
                           next if key == "item" || key == loop_var || key == index_var
                           vars_context[key] = raw_value
                         end
                         render_task_vars(task, vars_context, host.name)

                         # delegate_to: templated against the loop variable
                         # itself (geerlingguy.kubernetes' own "Set the
                         # kubeadm join command globally.": `delegate_to:
                         # "{{ item }}"`, `with_items: "{{ groups['all'] }}"`)
                         # must be re-resolved per iteration, against THIS
                         # item's own vars_context - the outer `exec_host`
                         # passed into this method was resolved once, before
                         # the loop ever bound "item", so a templated
                         # delegate_to always saw it as undefined and
                         # resolved to a host literally named "undefined"
                         # (crashing the SSH connection outright, not just
                         # producing a wrong result).
                         item_exec_host = task.delegate_to ? resolve_delegate_host(task, host, vars_context) : exec_host
                         fact_hosts[idx] = item_exec_host if task.delegate_facts && task.delegate_to

                         result = execute_task_once(task, host, vars_context, item_label: item_display(item), exec_host: item_exec_host, defer_loop_stats: true)
                         if result && (facts = result["ansible_facts"]?) && (facts_hash = facts.as_h?)
                           facts_hash.each { |key, value| running_vars_context[key] = value }
                         end
                         result
                       end
                     end

      finish_looped_task(task, host, rendered_items, item_results, fact_hosts)
    end

    # Whether execute_looped_task can send every surviving item through
    # one shared SSH round trip instead of one per item. Loop iterations
    # of a single task can never reference each other's *remote* results
    # (Ansible has no such semantic for a command's stdout/rc), unlike
    # mixed-task batching's references_register? check - but set_fact:
    # is purely controller-side and each iteration's result (its
    # ansible_facts) genuinely does need to carry into the next (see the
    # running_vars_context comment above) - a single upfront batch script
    # can't do that, so it's excluded here rather than silently losing
    # the accumulation.
    #
    # changed_when:/failed_when: do NOT need excluding here (they used
    # to be, copied over from task_batcher.cr's retroactive_verdict?
    # category for *mixed*-task batching, where the real concern is a
    # later task's changed_when referencing an earlier task's *not-yet-
    # applied* register: result) - execute_looped_task_batched already
    # calls apply_changed_failed_when per item, after the batch script
    # returns, using that item's own result. There's no cross-item
    # reference to get wrong the way mixed-task batching has. Excluding
    # it here bought nothing and cost a lot: konstruktoid-hardening's
    # "Find possible suid binaries" loops `command -v` over 411 items
    # with `changed_when: false, failed_when: false` (an extremely
    # common idiom for "this is read-only, never report changed") -
    # falling back to one real SSH round trip *per item* turned a task
    # that should take a couple of seconds into many minutes, consistent
    # with two separate real-host runs both dying of a `timeout 2400`
    # wrapper at the exact same point (identical line counts) rather
    # than any actual host/network failure.
    private def loop_batch_eligible?(task : Task, host : Host, exec_host : Host, vars_context : Hash(String, JSON::Any)) : Bool
      return false unless @batching_enabled
      return false unless exec_host == host
      return false if task.module_name.ends_with?("set_fact")
      return false if task.delegate_to
      return false if PluginManager.is_local_connection?(exec_host, vars_context)
      true
    end

    # Runs *loop_items* through one shared SSH round trip. When: is
    # evaluated per item up front (safe: an item's when: depends only on
    # `item` + the base context, both known before any remote call) and
    # skips are recorded exactly as the one-at-a-time path does via
    # when_passes? itself. Returns one result per item (nil = skipped or
    # never reached), consumed afterward by finish_looped_task exactly
    # like the one-at-a-time path's own results.
    private def execute_looped_task_batched(
      task : Task,
      host : Host,
      base_vars_context : Hash(String, JSON::Any),
      loop_items : Array(JSON::Any),
    ) : Array(JSON::Any?)
      item_results = Array(JSON::Any?).new(loop_items.size, nil)
      item_contexts = Hash(Int32, Hash(String, JSON::Any)).new
      steps = [] of BatchScript::Step
      step_indices = [] of Int32
      loop_var = task.loop_var
      index_var = task.index_var

      loop_items.each_with_index do |item, idx|
        vars_context = base_vars_context.dup
        vars_context["item"] = item
        vars_context[loop_var] = item if loop_var
        vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var
        item_contexts[idx] = vars_context

        # Per item, not per call: each iteration builds its own context
        # (base.dup + "item"), but when: and the step preparation both
        # read that same one.
        item_substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

        next unless when_passes?(task, vars_context, host, item_label: item_display(item), shared: item_substitutor, defer_stats: true)

        case outcome = prepare_batch_step(task, host, vars_context, shared: item_substitutor)
        when JSON::Any
          item_results[idx] = outcome
        when BatchScript::Step
          # ignore_errors: is per-*task*, but forced true here regardless
          # of the task's own value: today's loop always attempts every
          # item even after an earlier one fails, and the script's fail-
          # fast (built for the mixed-task batch case, where a failure
          # really should stop the remaining tasks) would otherwise halt
          # the script on the first failing item without ignore_errors:,
          # silently changing that continue-after-failure behavior as a
          # side effect of batching it.
          steps << BatchScript::Step.new(outcome.plugin_target, outcome.config_json, true)
          step_indices << idx
        end
      end

      return item_results if steps.empty?

      connection_host = PluginManager.get_connection_host(host, item_contexts[step_indices.first])
      step_results = run_batch_script(host, connection_host, steps)

      steps.each_index do |i|
        next unless r = step_results[i]?

        idx = step_indices[i]
        vars_context = item_contexts[idx]
        interpreted = PluginManager.interpret_remote_result(r.exit_code, r.stdout, r.stderr)
        item_results[idx] = apply_changed_failed_when(task, interpreted, vars_context, host)
      end

      item_results
    end

    # Shared aggregation for a completed loop's per-item results (used by
    # both the batched and one-at-a-time paths) so register:/notify:/
    # stats/halt bookkeeping stays byte-identical regardless of which
    # transport produced the results.
    private def finish_looped_task(task : Task, host : Host, loop_items : Array(JSON::Any), item_results : Array(JSON::Any?), fact_hosts : Array(Host)? = nil)
      results = [] of JSON::Any
      any_changed = false
      any_failed = false

      executed_count = 0
      loop_items.each_with_index do |item, idx|
        result = item_results[idx]
        next unless result

        executed_count += 1
        merge_ansible_facts(fact_hosts.try(&.[idx]) || host, result)

        changed = result["changed"]?.try(&.as_bool) || false
        failed = result["failed"]?.try(&.as_bool) || false
        any_changed ||= changed
        any_failed ||= failed

        ResultDisplay.display_result(host, result, @diff_mode, item_label: item_display(item))

        result_hash = result.as_h.dup
        result_hash["item"] = item
        results << JSON::Any.new(result_hash)
      end

      # Aggregate the whole loop into ONE recap entry, matching real
      # Ansible: a looped task counts once, not once per item.
      #   - 0 items executed (all skipped, or an empty loop) -> skipped=1
      #   - >=1 item executed -> ok=1 (plus changed=1 if any item changed),
      #     or failed=1 if any item failed (honoring ignore_errors).
      # The per-item `skipping:`/`changed:`/`ok:` lines above are display
      # only; Ansible prints those but sums the task once in the recap.
      if executed_count == 0
        # A genuinely empty loop source (0 items total, not "every item's
        # own when: was false" - those already printed their own
        # per-item `skipping: [host] => (item=x)` lines above) never
        # printed anything at all otherwise - real Ansible still emits
        # one bare `skipping: [host]` line for it (dev-sec os_hardening's
        # with_subelements:/with_community.general.flattened: tasks hit
        # this whenever nothing matched, e.g. no world-writable files
        # found to fix).
        if loop_items.empty?
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          puts "skipping: [#{connection_host}]".colorize(:cyan)
        end
        @results[host.name]["skipped"] += 1
      else
        aggregate_result = JSON.parse({
          "changed" => JSON::Any.new(any_changed),
          "failed"  => JSON::Any.new(any_failed),
        }.to_json)
        ResultDisplay.update_stats(@results[host.name], aggregate_result, task.ignore_errors)
      end

      if any_changed && (notify_list = task.notify)
        notify_handlers(task, host, notify_list)
      end

      if register_name = task.register
        unless register_name.empty?
          aggregate = {
            "changed" => JSON::Any.new(any_changed),
            "failed"  => JSON::Any.new(any_failed),
            "results" => JSON::Any.new(results),
          }
          @registered_vars[host.name][register_name] = JSON::Any.new(aggregate)
          @hv_generation += 1
        end
      end

      halt_if_failed(task, host, any_failed)
    end

    # Render a loop item for display purposes (Ansible shows `(item=...)`).
    private def item_display(item : JSON::Any) : String
      item.raw.is_a?(String) ? item.as_s : item.to_json
    end

    # Run a task repeatedly (up to task.retries times, sleeping task.delay
    # seconds between attempts) until task.until_condition evaluates true
    # against the registered result, matching Ansible's until:/retries:/delay:.
    # Skipped entirely in check mode: most modules refuse to act in check
    # mode anyway, which would otherwise turn every retry loop into a slow,
    # guaranteed-to-fail wait for no reason.
    private def execute_task_with_retries(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      until_condition : String,
      exec_host : Host = host
    )
      register_name = task.register
      attempts = task.retries.clamp(1..)
      result = nil

      attempts.times do |attempt|
        result = execute_task_once(task, host, vars_context, exec_host: exec_host)
        break unless result

        if register_name && !register_name.empty?
          register_result(host, register_name, result)
          vars_context[register_name] = @registered_vars[host.name][register_name]
        end

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(until_condition)
        break if ConditionalEvaluator.evaluate(substituted_condition, vars_context)

        sleep(task.delay.seconds) if attempt < attempts - 1
      end

      return unless result

      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        notify_handlers(task, host, notify_list)
      end

      if @adhoc
        ResultDisplay.display_adhoc_result(host, result)
      else
        ResultDisplay.display_result(host, result, @diff_mode)
      end
      ResultDisplay.update_stats(@results[host.name], result, task.ignore_errors)
      halt_if_failed(task, host, failed)
    end

    # Prints and counts each of *tasks* as individually skipped - used
    # when a block:'s own when: is false, since real Ansible expands a
    # block into its member tasks rather than reporting one aggregate
    # skip for the block itself. Recurses into a nested block so its own
    # members are reported individually too, matching how a nested
    # block's when: (false or not) would otherwise be evaluated.
    private def print_skipped_tasks(tasks : Array(Task), host : Host)
      tasks.each do |nested_task|
        # A nested block is transparent - like real Ansible, it gets no
        # "TASK [...]" banner of its own, only its members do.
        if nested_task.block?
          print_skipped_tasks(nested_task.block_tasks || [] of Task, host)
          print_skipped_tasks(nested_task.always_tasks || [] of Task, host)
          next
        end

        puts "TASK [#{render_task_name_for_display(nested_task, host)}]".colorize(:white).bold
        puts "*" * 70
        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
        puts "skipping: [#{connection_host}]".colorize(:cyan)
        @results[host.name]["skipped"] += 1
        register_skip_result(nested_task, host)
        puts ""
      end
    end

    # Runs a block: task - the nested block_tasks, then rescue_tasks if the
    # block failed (recovering it if rescue succeeds), then always_tasks
    # unconditionally, re-applying the halt afterward if the block ultimately
    # failed (unrescued, or rescue itself failed, or always: introduced a new
    # failure) unless the block itself has ignore_errors:.
    private def execute_block(task : Task, host : Host)
      if when_condition = task.when_condition
        vars_context = build_vars_context(task, host)
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(when_condition)

        unless ConditionalEvaluator.evaluate(substituted_condition, vars_context)
          # A block's when: is inherited by every task inside block: and
          # always: (verified against real ansible-playbook: each gets
          # its own "skipping: [host]" line and recap count, not one
          # aggregate line for the block) - rescue: is left alone since
          # it only ever runs if the block itself actually failed, which
          # can't happen when it never ran at all.
          print_skipped_tasks(task.block_tasks || [] of Task, host)
          print_skipped_tasks(task.always_tasks || [] of Task, host)
          return
        end
      end

      failed_before = @results[host.name]["failed"]
      # A block:'s own notify: (as opposed to notify: on one of its
      # nested tasks) fires once if ANY task inside the block/rescue/
      # always actually changed - real Ansible's own block-level notify
      # semantics. Previously entirely unhandled: only a regular task's
      # own notify: was ever forwarded to HandlerRunner. Found via
      # robertdebock.swap's own "Manage swap files." block (wraps
      # "Make a swap file"/"Make swap file system"/"Mount swap", none
      # of which have their own notify:) - "Run swapon" never fired.
      changed_before = @results[host.name]["changed"]
      propagate_role_context(task, task.block_tasks || [] of Task)
      run_task_list(task.block_tasks || [] of Task, host)
      block_failed = @halted_hosts.includes?(host.name)

      if block_failed && (rescue_tasks = task.rescue_tasks)
        @halted_hosts.delete(host.name)
        propagate_role_context(task, rescue_tasks)
        run_task_list(rescue_tasks, host)
        block_failed = @halted_hosts.includes?(host.name)

        # rescue: succeeded - the block-body failures it recovered from
        # don't count as play failures. Move them into "rescued" instead,
        # matching Ansible's recap (failed=0 ... rescued=1).
        unless block_failed
          recovered = @results[host.name]["failed"] - failed_before
          if recovered > 0
            @results[host.name]["failed"] -= recovered
            @results[host.name]["rescued"] += recovered
          end
        end
      end

      if always_tasks = task.always_tasks
        @halted_hosts.delete(host.name)
        propagate_role_context(task, always_tasks)
        run_task_list(always_tasks, host)
        block_failed ||= @halted_hosts.includes?(host.name)
      end

      notify_hosts_if_changed(task, [host], {host.name => changed_before})

      @halted_hosts.delete(host.name)
      halt_if_failed(task, host, block_failed)
    end

    # Copy the *enclosing* task's role context (defaults/vars/dirs) into each
    # nested task. Used for block:/rescue:/always: nested lists and, via the
    # include_tasks path, for the tasks of an included file - in both cases
    # `nested_task` is a Task parsed independently of the enclosing one, so it
    # wouldn't otherwise know it belongs to a role. Without this, a
    # `template:`/`copy:` with a role-relative `src:` (e.g. os_hardening's
    # `src: etc/systemd/coredump.conf.d/coredumps.conf.j2`) fails to resolve
    # against the role's templates/, and role-default `when:` gates evaluate
    # undefined. Only fills gaps: defaults/vars already on the nested task win.
    private def propagate_role_context(enclosing : Task, nested_tasks : Array(Task)) : Nil
      nested_tasks.each do |nested_task|
        if (defaults = enclosing.role_defaults) && !defaults.empty?
          nested_task.role_defaults = defaults
        end
        if (role_vars = enclosing.role_vars) && !role_vars.empty?
          nested_task.role_vars = role_vars
        end
        nested_task.role_files_dir = enclosing.role_files_dir
        nested_task.role_templates_dir = enclosing.role_templates_dir
        nested_task.role_vars_dir = enclosing.role_vars_dir
        nested_task.role_path = enclosing.role_path
        nested_task.role_name = enclosing.role_name
        # Same reasoning as role_loader.cr's own include_role_dir fix -
        # a nested include_role: reached via this include_tasks: must
        # still search from the playbook root, not this included file's
        # own directory (already wrongly baked into nested_task.
        # include_role_dir by the initial parse_task call).
        if include_role_dir = enclosing.include_role_dir
          nested_task.include_role_dir = include_role_dir
        end
        # ansible_parent_role_names - an include_tasks: inside a role
        # doesn't itself change the parent-role chain (only include_role:
        # pushes a new entry, in execute_include_role); a task reached
        # via include_tasks still belongs to the SAME role as its
        # enclosing task, so it inherits that role's own parent chain
        # unchanged. Without this, prometheus.prometheus's own
        # node_exporter role (whose own "Preflight" step is an
        # include_tasks:, not include_role:) lost its role_name/
        # role_parent_names for every task inside preflight.yml -
        # including the include_role: call to `_common` nested one level
        # further in, which then had no enclosing role context at all to
        # extend, so `_common`'s own direct-invocation guard assert
        # failed regardless of the real (indirect, via node_exporter)
        # invocation path.
        nested_task.role_parent_names = enclosing.role_parent_names
        nested_task.role_parent_paths = enclosing.role_parent_paths
        nested_task.ansible_collection_name = enclosing.ansible_collection_name

        # A block's own `vars:` is inherited by every task nested inside it
        # (real Ansible scoping) - found via linux-system-roles/logging's
        # `Check logging inputs` block, which computes `__logging_input_names:
        # "{{ logging_inputs | map(attribute='name') | list }}"` at the block
        # level and references it from a nested looped task's `when:`.
        # Without this, build_vars_context (which only ever reads a task's
        # *own* task.vars) never saw the block's vars at all, so
        # __logging_input_names resolved undefined - `intersect(undefined)`
        # returned empty, tripping the "includes undefined logging_inputs
        # item" fail: unconditionally. Merged so the nested task's own vars:
        # (if any) still win over the same key inherited from the block.
        unless enclosing.vars.empty?
          merged = enclosing.vars.dup
          nested_task.vars.each { |key, value| merged[key] = value }
          nested_task.vars = merged
        end
      end
    end

    # Runs a nested task list (block:/rescue:/always:), printing its own
    # TASK header per task since these live inside a block rather than the
    # play's top-level task list, so `run` never prints one for them. Stops
    # early once the host halts (a task failed without ignore_errors).
    private def run_task_list(tasks : Array(Task), host : Host)
      ensure_grouped(tasks)

      tasks.each do |nested_task|
        break if @halted_hosts.includes?(host.name)

        # A nested block: is transparent - like real Ansible, a named
        # block gets no "TASK [...]" banner of its own, only its members
        # do (execute_task already dispatches straight to execute_block,
        # which prints its own children's banners via this same
        # run_task_list). include_tasks: is NOT transparent - real
        # Ansible (and execute_include_tasks below) still shows a banner
        # for the include statement itself, so it keeps the banner here.
        # Found benchmarking prometheus.prometheus.alertmanager round
        # 134: a block-with-a-name nested inside another block (`_common`'s
        # "Download binary {{ }}"/"Verify checksum of {{ }}") printed a
        # spurious empty banner before its real children ran - this path
        # lacked the same block? dispatch run_task_batch (the multi-host
        # counterpart) already had.
        if nested_task.block?
          execute_task(nested_task, host)
          next
        end

        puts "TASK [#{render_task_name_for_display(nested_task, host)}]".colorize(:white).bold
        puts "*" * 70
        execute_task(nested_task, host)
        puts ""
      end
    end

    # Runs an include_tasks: task. Unlike import_tasks (spliced into the
    # task list at parse time), this is resolved now: the file path may be
    # templated, and when:/loop: apply to the include statement itself
    # (gating/repeating the whole included set) rather than to each
    # included task individually.
    private def execute_include_tasks(task : Task, host : Host)
      base_vars_context = build_vars_context(task, host)
      # Must mirror the general task path's fallback chain (see the
      # equivalent block above execute_looped_task) - a bare `loop: "{{
      # var }}"` scalar-template loop on an include_tasks: (robertdebock.
      # users' own "Loop over users_groups"/"Loop over users") only ever
      # populated task.loop_items when the loop was written as a literal
      # YAML list. The template form fell through to the single-run
      # `else` branch below with no item bound at all, so a custom
      # loop_var like `group`/`user` resolved as "undefined" instead of
      # looping once per list entry.
      loop_items = task.loop_items || resolve_first_found(task, host, base_vars_context) ||
        resolve_loop_template(task, base_vars_context) ||
        resolve_loop_flattened(task, base_vars_context, host.name) ||
        resolve_loop_subelements(task, base_vars_context)

      if loop_items
        # with_first_found:'s own no-candidate-matched, skip: true case -
        # resolve_first_found returns an empty (not nil) array for it,
        # matching execute_include_vars's identical handling of the same
        # situation.
        if loop_items.empty?
          puts "skipping: [#{host.name}]".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end

        # The item is exposed as `item` (Ansible's default) and, when
        # loop_control.loop_var is set, under that custom name too (e.g.
        # `mount` in dev-sec os_hardening's per-mountpoint include loop).
        loop_var = task.loop_var
        index_var = task.index_var
        loop_items.each_with_index do |item, idx|
          vars_context = base_vars_context.dup
          # Render any string field of the item that is itself a template
          # (e.g. dev-sec os_hardening's mount-list entries: `enabled:
          # "{{ os_mnt_tmp_enabled }}"`) before binding it into scope -
          # otherwise a bare `when: mount.enabled | bool` (no outer
          # `{{ }}` for ConditionalEvaluator to render through) sees the
          # literal unrendered "{{ os_mnt_tmp_enabled }}" text, which the
          # `bool` filter treats as truthy regardless of the real value.
          rendered_item = deep_render_item(item, vars_context, host.name)
          vars_context["item"] = rendered_item
          vars_context[loop_var] = rendered_item if loop_var
          vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var
          # Each include_tasks loop iteration counts as one `ok` in the
          # recap, matching real Ansible (which tallies the include plus
          # every included task per iteration) - but only once the
          # include's own when: (checked inside run_include_tasks_once,
          # since it may reference this iteration's `item`) actually
          # passes. The increment used to happen unconditionally here,
          # before that check ran - a when:-gated include_tasks: that
          # ultimately skipped still got counted as `ok` AND `skipped`
          # for the same task. See the non-looped branch's comment below
          # for how this was found.
          run_include_tasks_once(task, host, vars_context, item_display(item))
        end
      else
        # Non-looped include_tasks: itself counts as one `ok` in the
        # recap too, matching real Ansible - the looped branch above
        # already credits this per iteration, but a plain (unlooped)
        # include_tasks: never did, undercounting the recap's `ok=`
        # tally by exactly 1 versus real Ansible for every such task.
        # Found benchmarking robertdebock.openvpn's own "Setup openvpn
        # server or client" (a single, non-looped include_tasks:) -
        # functionally harmless (the included tasks all still ran
        # correctly) but a real, easily reproduced recap-count
        # divergence.
        #
        # The increment itself moved into run_include_tasks_once (after
        # its own when: check passes) rather than staying here
        # unconditionally - robertdebock.openssl's own looped `include_
        # tasks: create.yml` (loop: "{{ openssl_items }}", gated by
        # `when: openssl_items is defined`) falls into THIS branch when
        # openssl_items is undefined (the loop can't resolve, so
        # loop_items above is nil) and was being counted as both `ok`
        # and `skipped` for the same single skipped include - crediting
        # `ok` here unconditionally, then run_include_tasks_once's own
        # when:-false path adding `skipped` on top, with no when: check
        # in between.
        run_include_tasks_once(task, host, base_vars_context, nil)
      end
    end

    private def run_include_tasks_once(task : Task, host : Host, vars_context : Hash(String, JSON::Any), item_label : String?)
      if when_condition = task.when_condition
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(when_condition)

        unless ConditionalEvaluator.evaluate(substituted_condition, vars_context)
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          suffix = item_label ? " => (item=#{item_label})" : ""
          puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end
      end

      # The include itself counts as one `ok` (see the two call sites'
      # own comments) - only reached once the when: check above has
      # actually passed.
      @results[host.name]["ok"] += 1

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      file_rel = substitutor.substitute(task.include_file.as(String))
      resolved_path = PlaybookParser.resolve_include_path(file_rel, task.include_file_dir.as(String))

      unless File.exists?(resolved_path)
        fail_include(task, host, "Included tasks file not found: #{resolved_path}")
        return
      end

      yaml = YAML.parse(Vault.maybe_decrypt(File.read(resolved_path)))
      unless yaml.as_a?
        fail_include(task, host, "Included tasks file must be a YAML list: #{resolved_path}")
        return
      end

      inherited = Play.new("", "")
      inherited.become = task.become
      inherited.become_user = task.become_user
      included_tasks = PlaybookParser.parse_tasks(yaml.as_a, inherited, "task in included #{resolved_path}", File.dirname(resolved_path))

      # Propagate this iteration's loop `item` and the include statement's
      # own vars: into each included task's own scope: run_task_list ->
      # execute_task rebuilds a fresh vars_context per task from scratch
      # (play/host/registered/task vars), which wouldn't otherwise see
      # either of these.
      if include_vars = task.include_vars
        included_tasks.each do |included_task|
          include_vars.each { |key, value| included_task.vars[key] = value }
        end
      end

      # Thread this iteration's item into each included task's own scope as
      # `item` and, when loop_control.loop_var is set, under that custom name
      # too (so `mount.path` in a name/param/when: resolves). Also render the
      # task NAME against the loop vars, matching how python names each
      # iteration's banner (`render for mount /boot` instead of a literal
      # `{{ mount.path }}`) - needs the item in scope first.
      if item = vars_context["item"]?
        included_tasks.each do |included_task|
          included_task.vars["item"] = item
          if loop_var = task.loop_var
            included_task.vars[loop_var] = item
          end
        end
      end
      name_substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      included_tasks.each do |included_task|
        included_task.name = name_substitutor.substitute(included_task.name)
      end

      # Propagate the *role* context (defaults/vars/dirs) into each included
      # task. Included files - especially a role's task files like
      # dev-sec os_hardening's hardening.yml - gate their own imports on
      # role-default variables (e.g. `when: os_auditd_enabled | bool`).
      # Without this, an include_tasks: inside a role produced tasks with no
      # role_defaults, so every one of those gates resolved as undefined
      # (false) and the whole role silently skipped. Mirror the way `vars:`
      # and `item` are threaded through above. role_defaults/role_vars here
      # carry the *role's* own scope (not the include statement's inline
      # vars:, which is handled above), matching real Ansible where an
      # included file shares the enclosing role's defaults/vars.
      propagate_role_context(task, included_tasks)

      run_task_list(included_tasks, host)
    rescue ex
      fail_include(task, host, "Failed to load included tasks: #{ex.message}")
    end

    private def fail_include(task : Task, host : Host, message : String)
      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
      puts "failed: [#{connection_host}]".colorize(:red)
      puts "  #{message}".colorize(:red)
      @results[host.name]["failed"] += 1
      halt_if_failed(task, host, true)
    end

    # Runs an include_role: task - the dynamic counterpart to a roles:
    # list entry. Task-level keywords (when:/tags:/loop:) apply to the
    # include_role statement itself, same as include_tasks.
    # meta: clear_facts - drops this host's gathered facts. Under
    # --gathering smart that's the escape hatch: @facts is the shared
    # run-scoped store, so emptying this host's entry makes the *next*
    # play's gather_facts_for_all_hosts see it as ungathered and query it
    # again. Under the default implicit mode every play re-gathers
    # anyway, so this just clears facts for the remainder of this play.
    #
    # Matches real ansible-playbook, verified against ansible-core 2.19.4:
    # under gathering=smart, a `meta: clear_facts` in play 2 causes play 3
    # to re-run Gathering Facts.
    # Produces no per-host output line and does not count toward the
    # recap, matching ansible-core 2.19.4: its `TASK [clear]` banner
    # prints with no `ok:` beneath it, and the meta task is absent from
    # the play recap's ok= total.
    private def execute_meta(task : Task, host : Host)
      case task.meta_action
      when "flush_handlers"
        # Called once per host by the outer per-task host loop in #run,
        # but @tasks.each is sequential across tasks - every active host
        # has already finished every task BEFORE this one by the time any
        # of them reaches it, so running the full (cross-host)
        # HandlerRunner#run here is correct regardless of which host
        # triggers it first. Subsequent per-host calls for this same
        # meta task are harmless no-ops: HandlerRunner#run clears each
        # host's notified set after running, so any_notified? is false
        # for the 2nd..Nth host and #run returns immediately without
        # re-printing anything.
        run_handlers
      when "end_host"
        # Per-host - verified against real ansible-playbook: a 2nd host
        # whose own `when:` makes it skip this exact task entirely keeps
        # running normally afterward, unlike end_play below. Reuses
        # halted_hosts (already excludes this host from every remaining
        # task in this play, including nested block:/rescue:/always:,
        # and - also verified live - suppresses its own pending notified
        # handlers at the end-of-play flush, exactly like a real
        # failure) but tracked separately in ended_hosts so it's NOT
        # treated as a failure for the exit code or carried forward into
        # later plays.
        @halted_hosts.add(host.name)
        @ended_hosts.add(host.name)
      when "end_play"
        # Global, NOT per-host - verified against real ansible-playbook:
        # even a host whose own `when:` skips this exact task entirely
        # (never itself executes this branch) still gets halted for the
        # rest of the play the moment ANY other host does. So this halts
        # every currently-active host in the whole play, not just
        # `host` - @hosts is the play's own full host list, available on
        # the executor regardless of which single host's fiber is
        # running this code.
        @hosts.each do |other|
          next if @halted_hosts.includes?(other.name)
          @halted_hosts.add(other.name)
          @ended_hosts.add(other.name)
        end
      when "clear_host_errors"
        # Global, NOT scoped to `host` - same shape as end_play above,
        # and for the same reason: real Ansible's own doc wording
        # ("clears the failed state from hosts specified in the PLAY'S
        # LIST OF HOSTS") and live verification both show it acts on
        # every failed host in the play, not just whichever host(s)
        # happen to still be active enough to individually execute this
        # meta task - a host that already failed earlier in this play is
        # EXCLUDED from this task too (same halted_hosts gate as any
        # other), so if clearing were scoped to `host` alone, the failed
        # host itself could never reach this code to clear its own
        # error, making the feature unusable exactly the way the
        # community.general docs' own example uses it (a failing task
        # immediately followed by clear_host_errors in the same task
        # list). Also confirmed live: clears the failure for SUBSEQUENT
        # plays (the failed host is back for play 2) but leaves
        # halted_hosts itself untouched, so the current play still does
        # not resume for that host - matching "does NOT continue
        # execution in the current play" exactly.
        @hosts.each do |other|
          @cleared_error_hosts.add(other.name) if @halted_hosts.includes?(other.name)
        end
      when "noop"
        # Real Ansible's own doc: "this literally does 'nothing'."
      when "refresh_inventory"
        # Real Ansible's own doc, verified live: refreshing does NOT add
        # hosts to (or remove them from) the CURRENT play's own host
        # loop - only a LATER play's own `hosts:` pattern match sees the
        # new data, since that's computed fresh from the shared
        # Inventory object each time (crystal-play.cr's own per-play
        # `matched_hosts = inventory.get_hosts(...)`). Re-parsing and
        # reload_from!-ing in place (rather than just swapping in a new
        # Inventory reference) is what makes that "shared object" premise
        # true without any callback plumbing back up to crystal-play.cr -
        # see Inventory#reload_from!'s own comment. A no-op (not an
        # error) when no inventory_path was given - the `ansible` ad-hoc
        # CLI's own TaskExecutor never passes one, and a single synthetic
        # ad-hoc task has no later play to ever observe a refresh anyway.
        if (path = @inventory_path) && (inv = @inventory)
          inv.reload_from!(InventoryParser.parse(path))
          @hv_generation += 1
        end
      else
        # Only clear_facts/flush_handlers/end_host/end_play/
        # clear_host_errors/noop/refresh_inventory parse (see
        # PlaybookParser.parse_meta_task), so clear_facts is the only
        # other action to dispatch on here.
        @facts[host.name].clear
        @facts_dict_cache.delete(host.name)
        @hv_generation += 1
      end
    end

    private def execute_include_role(task : Task, host : Host)
      base_vars_context = build_vars_context(task, host)
      # Same scalar-template loop gap as execute_include_tasks above.
      loop_items = task.loop_items ||
        resolve_loop_template(task, base_vars_context) ||
        resolve_loop_flattened(task, base_vars_context, host.name) ||
        resolve_loop_subelements(task, base_vars_context)

      if loop_items
        loop_var = task.loop_var
        index_var = task.index_var
        loop_items.each_with_index do |item, idx|
          vars_context = base_vars_context.dup
          vars_context["item"] = item
          vars_context[loop_var] = item if loop_var
          vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var
          run_include_role_once(task, host, vars_context, item_display(item))
        end
      else
        run_include_role_once(task, host, base_vars_context, nil)
      end
    end

    private def run_include_role_once(task : Task, host : Host, vars_context : Hash(String, JSON::Any), item_label : String?)
      if when_condition = task.when_condition
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(when_condition)

        unless ConditionalEvaluator.evaluate(substituted_condition, vars_context)
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          suffix = item_label ? " => (item=#{item_label})" : ""
          puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end
      end

      # The include_role: task itself counts as one `ok` in the recap,
      # matching real Ansible (verified against ansible-core 2.19.4's
      # own strategy/__init__.py: an IncludeRole result still hits the
      # same `self._tqm._stats.increment('ok', ...)` as a plain task) -
      # same fix already applied to execute_include_tasks's
      # run_include_tasks_once (see its own comment) but never mirrored
      # here. Placed after the when: check, like that one, so a
      # when:-gated include_role: that skips isn't double-counted as
      # both `ok` and `skipped`. Found benchmarking andrewrothstein.
      # terraform (round 154 v3): real Ansible's cold-run recap was
      # `ok=12`, crystal's was `ok=10` - both `include_role:` calls in
      # the role (andrewrothstein.hashi, andrewrothstein.unarchivedeps)
      # were silently undercounted despite running correctly.
      @results[host.name]["ok"] += 1

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      role_name = substitutor.substitute(task.include_role_name.as(String))

      inherited = Play.new("", "")
      inherited.become = task.become
      inherited.become_user = task.become_user

      # ansible_parent_role_names: the ancestor role-name chain leading to
      # THIS include_role: call - if this include_role task itself
      # belongs to another role's tasks (task.role_name set), the loaded
      # role's own parent chain is that enclosing role's own parent
      # chain plus the enclosing role's own name.
      child_parent_names = (task.role_parent_names || [] of String) + (task.role_name ? [task.role_name.as(String)] : [] of String)
      child_parent_paths = (task.role_parent_paths || [] of String) + (task.role_path ? [task.role_path.as(String)] : [] of String)
      # task.role_defaults already represents the FULL accumulated
      # ancestor-chain default set (RoleLoader#load_role merges
      # parent_defaults into it before assigning), not just this role's
      # own defaults/main.yml - so simply forwarding it here propagates
      # the whole chain, same accumulate-not-replace approach as
      # child_parent_names/child_parent_paths above. See RoleLoader#
      # load_role's own comment on why this needs to happen at all.
      child_parent_defaults = task.role_defaults || Hash(String, JSON::Any).new

      rendered_include_vars = render_include_role_vars(task.include_role_vars, vars_context, host.name)

      begin
        included_tasks, included_handlers = RoleLoader.load_single_role(
          role_name,
          rendered_include_vars,
          task.tags,
          inherited,
          task.include_role_dir.as(String),
          task.include_role_tasks_from,
          child_parent_names,
          child_parent_paths,
          child_parent_defaults
        )
      rescue ex
        fail_include(task, host, "Failed to load role '#{role_name}': #{ex.message}")
        return
      end

      # Round 26 originally had an eager re-render of each loaded task's
      # `name:` here (against just the include_role: `vars:` passed in) to
      # fix a role's tasks/main.yml `name: "Create group {{ _child_group
      # }}"` staying literal in the "TASK [...]" banner - found via
      # prometheus.prometheus.alertmanager's own `_common` role include
      # (`_common_system_group: "{{ alertmanager_system_group }}"` passed
      # as include_role vars:). That eager pass is now not just redundant
      # but actively harmful: `render_task_name_for_display` (0.9.353)
      # already re-renders every task name lazily, right before print,
      # against the task's own FULL vars_context (role defaults/vars +
      # magic vars + include_role vars - everything, not just what this
      # one include_role: call happened to pass). This eager pass's own
      # context was always a strict subset of that (missing the newly-
      # loaded role's own vars/main.yml entries and its
      # ansible_parent_role_names/ansible_collection_name magic vars,
      # neither available until the task actually executes) - fine for a
      # name referencing ONLY an explicitly-passed include_role var (round
      # 26's case), but for a name referencing anything else (round 28's
      # `_common_service_name`, computed internally by _common's own
      # vars/main.yml from `ansible_parent_role_names`/
      # `ansible_collection_name` - never passed as an include_role var at
      # all) the substitution failed to "undefined" and PERMANENTLY BAKED
      # THAT WRONG VALUE into `t.name`, since `render_task_name_for_display`
      # only re-renders a name that still contains `{{` - "undefined" has
      # none, so the later, correct, full-context render never got a
      # chance to run. Found live via prometheus.prometheus.pushgateway's
      # own "Create systemd service unit {{ _common_service_name }}" task
      # (round 28) - reproduced by inserting a probe task right before it:
      # the probe's own BODY correctly resolved `_common_service_name` to
      # "pushgateway" via the exact same vars_context machinery, proving
      # the value was never actually unavailable - only this eager,
      # narrower pre-render had gotten there first and gotten it wrong.

      if item = vars_context["item"]?
        (included_tasks + included_handlers).each do |included_task|
          included_task.vars["item"] = item
          if (loop_var = task.loop_var) && (bound = vars_context[loop_var]?)
            included_task.vars[loop_var] = bound
          end
        end
      end

      @handler_runner.handlers.concat(included_handlers) unless included_handlers.empty?

      run_task_list(included_tasks, host)
    end

    # Recursively renders every string field of a loop item that is
    # itself a template (Hash/Array values are walked; a String
    # containing "{{" is substituted through *vars_context*, everything
    # else is returned unchanged) - see execute_include_tasks for why
    # this matters for bare (non-`{{ }}`) when: conditions.
    private def deep_render_item(item : JSON::Any, vars_context : Hash(String, JSON::Any), host_name : String) : JSON::Any
      case raw = item.raw
      when Hash
        rendered = raw.each_with_object({} of String => JSON::Any) do |(key, value), acc|
          acc[key] = deep_render_item(value, vars_context, host_name)
        end
        JSON::Any.new(rendered)
      when Array
        JSON::Any.new(raw.map { |value| deep_render_item(value, vars_context, host_name) })
      when String
        return item unless raw.includes?("{{")

        # A raw value that's *exactly* one bare `{{ variable }}` span (no
        # surrounding text, no filter chain) resolves to the variable's
        # own native JSON type - matching real Ansible's own templating,
        # which preserves the referenced value's type when the whole
        # input is a single expression, only falling back to string
        # concatenation for partial/mixed text. The general `substitute`
        # path below always stringifies (it has to - the general case
        # can mix literal text with an expression), which previously
        # silently turned every such role default into a string:
        # geerlingguy.php's own `pool_pm_max_requests: "{{
        # php_fpm_pm_max_requests }}"` (php_fpm_pm_max_requests: 0, a
        # real int meant to disable the request-count limit) rendered as
        # the STRING "0" - not falsy to Crinja's `default(500, true)`
        # filter the way the real int 0 is, so pm.max_requests stayed 0
        # instead of the role's own intended fallback of 500.
        stripped = raw.strip
        if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
          native = VariableSubstitutor::VariableLookup.new(vars_context).resolve(stripped[2..-3].strip)
          # Audit pass (2026-08-11, following the ansible-vault/
          # prometheus/grafana rounds finding 5 independent copies of
          # this exact bug): a variable whose own raw value is itself
          # still unrendered Jinja (a role default computed from
          # another default) must NOT be returned directly here - that
          # would hand back the literal, unparsed "{{ ... }}" text as
          # the loop item's "native" value instead of falling through
          # to the #substitute path below, which actually renders it
          # (at the cost of losing native typing, same tradeoff every
          # other fallback in this codebase makes for this case).
          if native && !((raw2 = native.raw).is_a?(String) && raw2.includes?("{{"))
            return native
          end
        end

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
        JSON::Any.new(substitutor.substitute(raw))
      else
        item
      end
    end

    # Substitute variables in task parameters
    private def substitute_task_params(
      params : Hash(String, String),
      substitutor : VarSubstitutor
    ) : Hash(String, String)
      result = Hash(String, String).new

      params.each do |key, value|
        # Dynamic variable names - `set_fact: "{{ item.key }}": "{{ item.value }}"`
        # - carry a template in the *key*, not just the value. Real Ansible
        # (and dev-sec os_hardening's "Set OS dependent variables", which
        # builds os_* vars exactly this way) substitutes the key too, so a
        # role can name facts from a loop item's fields. Substituting only
        # the value used to register the fact under the literal key
        # `{{ item.key }}`, making `{{ auditd_package }}` resolve undefined
        # in the next task.
        substituted_value = substitutor.substitute(value)

        # `mode:` piped through a variable (`mode: "{{ redis_conf_dir_mode
        # }}"`, geerlingguy.redis's own style) loses its octal-ness the
        # same way a *direct* unquoted `mode: 0770` literal does (see
        # playbook_parser.cr's own #parse_task_params octal-mode comment)
        # - Crystal's YAML parser already decimal-converted the variable's
        # defining `redis_conf_dir_mode: 02770` at vars-file parse time,
        # so #substitute above just stringifies that decimal (Int64 1528)
        # as "1528" verbatim. Real Ansible's own file module hits the
        # exact same decimal-rendered string internally, but recovers the
        # original octal digits because its `mode:` argspec is `type:
        # raw` - a *bare* single `{{ }}` template preserves the
        # variable's native Python int type instead of stringifying, and
        # the module's own `set_fs_attributes_if_different` explicitly
        # reformats an int mode via `'%04o' % mode` before ever comparing
        # or applying it. Re-derive the same octal digit text here,
        # narrowly scoped to key == "mode" (matching the parse-time fix's
        # own scope) rather than generally preserving native types for
        # every param, since only mode: has this real-Ansible-specific
        # int -> octal-string reinterpretation.
        if key == "mode"
          stripped = value.strip
          if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
            native = VariableSubstitutor::VariableLookup.new(substitutor.vars).resolve(stripped[2..-3].strip)
            if native && (raw = native.raw).is_a?(Int64)
              # Only reformat via to_s(8) when the int's own PLAIN
              # decimal digits do NOT already look like a valid octal
              # mode (`\A[0-7]{3,4}\z`, matching `parse_numeric_mode`'s
              # own regex in plugins/file.cr). Real bug found live-
              # verifying CRINJA.md step 5 against dev-sec os_hardening:
              # this reformatting assumes every Int64-typed mode value
              # came from Crystal's YAML parser octal-converting an
              # UNQUOTED literal (`redis_conf_dir_mode: 02770` -> decimal
              # 1528, whose own digit string "1528" contains an '8' and
              # so never looks octal-valid itself - reformatting recovers
              # "02770") - but os_hardening's own dynamic `set_fact: "{{
              # item.key }}": "{{ item.value }}"` produces an Int64 a
              # COMPLETELY different way: plugins/set_fact.cr's `coerce`
              # decimal-parses an already-octal-style STRING like "1777"
              # into the int 1777 directly (no YAML octal parsing
              # involved at all) - and for THAT kind of int, reformatting
              # via to_s(8) treats 1777's decimal VALUE as needing
              # re-expression in octal, giving "3361" instead of the
              # original "1777", silently corrupting real chmod calls
              # (found via corrupted directory permissions on a live
              # host: /dev/shm, /tmp, /var/tmp all ended up mode 3361
              # instead of 1777). Since a genuine octal-YAML-derived int's
              # own decimal digits essentially never coincidentally look
              # like a valid octal mode already (verified against both
              # real cases above), checking that first disambiguates
              # correctly without needing to track how the int
              # originated.
              plain = raw.to_s
              substituted_value = if plain.matches?(/\A[0-7]{3,4}\z/)
                                     plain
                                   else
                                     "0" + raw.to_s(8)
                                   end
            end
          end
        end

        # `{{ ... | default(omit) }}` (real Ansible's magic variable for
        # dropping a parameter entirely rather than giving it any real
        # value - see OMIT_SENTINEL) - skip the key altogether instead of
        # sending the plugin a literal sentinel string as the param value.
        next if substituted_value == OMIT_SENTINEL

        result[substitutor.substitute(key)] = substituted_value
      end

      result
    end

    # For copy:/template: tasks that came from a role, a relative src:
    # resolves against the role's files/ or templates/ directory - the
    # plugin subprocess itself has no concept of roles, so this has to
    # happen here, before the config is handed off. An absolute src: (or a
    # task not from a role) is left untouched.
    private def resolve_role_relative_src(task : Task, params : Hash(String, String)) : Hash(String, String)
      src = params["src"]?
      return params if src.nil? || src.starts_with?('/')

      subdir = case task.module_name
               when "ansible.builtin.copy"     then "files"
               when "ansible.builtin.template" then "templates"
               else                                  nil
               end
      return params unless subdir

      role_dir = case task.module_name
                 when "ansible.builtin.copy"     then task.role_files_dir
                 when "ansible.builtin.template"  then task.role_templates_dir
                 else                                  nil
                 end
      return params unless role_dir

      # Real Ansible searches a role task's ENTIRE parent-role chain for
      # a relative src:, not just the currently-executing role's own
      # files:/templates: dir - a shared/generic role commonly relies on
      # this to let each CALLING role supply its own asset under the
      # same relative name (prometheus.prometheus's own `_common` role,
      # invoked by every exporter role: `src: "{{ _common_service_name
      # }}.service.j2"` resolves to `node_exporter/templates/node_
      # exporter.service.j2` when invoked FROM node_exporter, not to
      # any file inside _common's own templates/ dir at all). Checked
      # nearest-parent-first (role_parent_paths is root-first, so
      # reversed here), falling back to the current role's own dir
      # unchanged (even if the file doesn't exist there either) so the
      # existing "not found" error still names the expected location.
      candidate = File.join(role_dir, src)
      unless File.exists?(candidate)
        if parent_paths = task.role_parent_paths
          parent_paths.reverse_each do |parent_path|
            parent_candidate = File.join(parent_path, subdir, src)
            if File.exists?(parent_candidate)
              candidate = parent_candidate
              break
            end
          end
        end
      end

      # Must be absolute: #inline_copy_source_content's own "is this a
      # real controller-side path that needs staging to a remote host"
      # gate is `src.starts_with?('/')` - a relative candidate (which
      # this always was whenever crystal-ansible is invoked with a
      # relative playbook path, the common case) silently skipped that
      # gate entirely, leaving `src:` as an unresolved relative string
      # in the params sent to copy.cr's plugin binary - which runs ON
      # THE REMOTE HOST, where that relative path never existed. Found
      # via robertdebock.dns's "Place override.conf" (a role-relative
      # copy: src: reached over a real SSH connection, previously
      # untested - every prior copy:-with-role-relative-src: round used
      # either remote_src: true or a local connection).
      resolved = params.dup
      resolved["src"] = File.expand_path(candidate)
      resolved
    end

    # copy.cr runs on the *target* host (uploaded there like every other
    # plugin, unlike template: - an action plugin that runs on the
    # controller and already handles this correctly by reading its own
    # src: file locally before dispatch). A copy: task's `src:` names a
    # file on the *controller*, so copy.cr's own `File.exists?(src)`
    # check - a plain local filesystem check, from the perspective of
    # wherever it's actually running - can never find it once the play
    # targets a genuinely remote host: the file was never transferred
    # there. Found via konstruktoid-hardening's "Add cracklib password
    # list" (its only `copy:` task with a real src: file, previously
    # entirely untested territory) - failed with "Source file not found"
    # citing the exact real (and really-existing-on-the-controller) path.
    #
    # Read here, on the controller, and forwarded as `content:` instead -
    # copy.cr already has a fully-working content-write path (used by
    # any `copy: {content: ..., dest: ...}` task), so this reuses it
    # rather than needing a separate upload mechanism. Left alone for
    # `remote_src: true` (real Ansible's own remote-to-remote copy,
    # where src: already refers to a path on the target, not the
    # controller - reading it here would be wrong) and for a local
    # connection (copy.cr already runs on the same filesystem as the
    # controller in that case, so src: already resolves correctly as-is -
    # converting it anyway would only change check-mode's message
    # ("Would copy SRC to DEST" -> a generic content message) for no
    # actual correctness gain).
    # Above this size, embedding the file as a `content` param string
    # would make the JSON config too large to safely round-trip through
    # #execute_remote_plugin's own base64 encoding of the *whole config*
    # (see the comment on that call): a real bug found benchmarking
    # ansible-community.ansible-vault's own "Install Vault" task, which
    # `copy:`s a ~530MB downloaded Vault release binary - Crystal
    # stdlib's `Base64.encode_size` computes `str_size * 4` as native
    # Int32 arithmetic before the final `.to_i`, and a base64'd-then-
    # JSON-escaped-then-base64'd-again 530MB payload comfortably clears
    # 2^31, crashing the whole engine with an unhandled OverflowError
    # partway through a run - not a graceful per-task failure.
    INLINE_COPY_MAX_BYTES = 8 * 1024 * 1024

    private def inline_copy_source_content(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.copy"
      return params if ["true", "yes", "1", "on"].includes?(params["remote_src"]?.try(&.downcase))
      return params if PluginManager.is_local_connection?(host, vars_context)

      src = params["src"]?
      return params unless src && src.starts_with?('/')

      return stage_directory_copy_source(params, src, host, vars_context) if Dir.exists?(src)

      size = File.size(src) rescue nil
      return params unless size

      if size > INLINE_COPY_MAX_BYTES
        return stage_large_copy_source(params, src, host, vars_context)
      end

      begin
        content = File.read(src)
      rescue
        return params
      end

      resolved = params.dup
      resolved.delete("src")
      resolved["content"] = content
      resolved
    end

    # Large-file counterpart to the inline `content` path above: SCPs
    # *src* straight to a remote scratch path (no content embedded in
    # the JSON config at all - just a path string, same size regardless
    # of how big the underlying file is) and points the module at that
    # instead. `copy.cr`'s own handle_file_copy already reads `src` from
    # whatever filesystem the plugin process is actually running on, so
    # once the file is really present on the target, no other change is
    # needed there beyond deleting the scratch copy afterward (via the
    # `__cleanup_after_copy` marker param).
    private def stage_large_copy_source(params : Hash(String, String), src : String, host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      connection_host = PluginManager.get_connection_host(host, vars_context)

      if match = precomputed_copy_match(params, src, host, vars_context)
        return match
      end

      remote_tmp = "/tmp/.crystal-ansible-copy-#{Random::Secure.hex(8)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src,
          remote_tmp,
          host.port,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["src"] = remote_tmp
      resolved["__cleanup_after_copy"] = "true"
      # copy.cr's own "dest is an existing directory" handling appends
      # File.basename(src) to dest - without this, that would append the
      # random scratch filename (".crystal-ansible-copy-<hex>") instead
      # of the real source's name, installing e.g. Vault's binary as
      # "/usr/local/bin/.crystal-ansible-copy-<hex>" rather than
      # "/usr/local/bin/vault". Real bug found immediately after adding
      # the staging path above, benchmarking the same ansible-vault role.
      resolved["__original_src_basename"] = File.basename(src)
      resolved
    end

    # Checksum-first skip for a large controller->remote `copy:` upload,
    # matching real Ansible's own `copy:` behavior (it computes the
    # source checksum locally and stats the destination remotely before
    # ever transferring content, skipping the transfer entirely on a
    # match). Previously #stage_large_copy_source unconditionally SCP'd
    # *src* to a remote scratch path on every single run regardless of
    # whether the destination already held identical content - fine for
    # a one-time install, wasteful for a large binary (tens of MB) on
    # every warm rerun of a role like prometheus.prometheus's own
    # binary-propagation task (round 25/26/27's alertmanager/
    # blackbox_exporter benchmark rounds all hit this).
    #
    # One remote round trip (not two): resolves the real destination
    # path (appending the source's basename if `dest` is already an
    # existing directory - copy.cr's own `handle_file_copy` does the
    # same resolution once it actually runs, so this must match it
    # exactly or a mismatch would silently skip a needed copy) and
    # md5sums it in the same script, only if it exists.
    #
    # Returns the resolved params for the caller to use as-is (with
    # `src` left pointing at the untouched local file - the plugin body
    # never reads it in the match case) when the checksums match, or
    # `nil` when they don't (or the match couldn't be determined),
    # telling the caller to fall through to its normal unconditional
    # upload path unchanged.
    private def precomputed_copy_match(params : Hash(String, String), src : String, host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)?
      # force: false's own "dest exists at all -> unchanged, no
      # checksum involved" short-circuit lives entirely in copy.cr and
      # doesn't need src staged either way - simplest to just leave that
      # case to the normal (always-safe) unconditional-upload path
      # rather than teach this checksum-first optimization about it too.
      return nil if ["false", "no", "0", "off"].includes?(params["force"]?.try(&.downcase))

      dest = params["dest"]?
      return nil unless dest

      local_md5 = begin
        Digest::MD5.new.file(src).hexfinal
      rescue
        return nil
      end

      basename = File.basename(src)
      script = <<-SCRIPT
        p=#{shell_single_quote(dest)}
        [ -d "$p" ] && p="$p/#{basename.gsub("'", "'\\''")}"
        if [ -f "$p" ]; then md5sum "$p" | cut -d' ' -f1; else echo NOFILE; fi
        SCRIPT

      connection_host = PluginManager.get_connection_host(host, vars_context)
      result = SSHManager.exec_script(
        connection_host,
        host.user || "root",
        script,
        host.port,
        identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
      )
      return nil unless result[:exit_code] == 0 && result[:stdout].strip == local_md5

      resolved = params.dup
      resolved["__precomputed_match"] = "true"
      resolved["__precomputed_checksum"] = local_md5
      resolved["__original_src_basename"] = basename
      resolved
    rescue
      nil
    end

    # Single-quotes *str* for shell embedding, escaping any embedded
    # single quote - same convention as BasePlugin/BatchScript/
    # PluginManager's own copies of this helper (each kept separate
    # rather than shared across unrelated classes).
    private def shell_single_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end

    # Directory counterpart to #stage_large_copy_source: SCPs the whole
    # source directory tree to a remote scratch path (`scp -r`) instead
    # of leaving `src` pointing at a path that only exists on the
    # controller - `copy.cr`'s own directory-copy logic already reads
    # `src` from wherever the plugin process is actually running, so
    # once the directory is really present on the target, no other
    # change is needed there beyond deleting the scratch copy afterward.
    private def stage_directory_copy_source(params : Hash(String, String), src : String, host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.crystal-ansible-copy-dir-#{Random::Secure.hex(8)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src.rstrip('/'),
          remote_tmp,
          host.port,
          mode: nil,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?),
          recursive: true
        )
      rescue
        return params
      end

      resolved = params.dup
      # `scp -r src remote_tmp` (remote_tmp not previously existing)
      # makes remote_tmp itself an exact copy of src's contents - the
      # trailing "/" on the ORIGINAL src: value still has to be
      # preserved here, since copy.cr's own directory-copy dispatch uses
      # it (real Ansible's own convention) to decide whether src's
      # contents land directly in dest or as a dest/<basename> subdir.
      resolved["src"] = src.ends_with?('/') ? "#{remote_tmp}/" : remote_tmp
      resolved["__cleanup_after_copy_dir"] = "true"
      resolved
    end

    # unarchive:'s own real Ansible default (remote_src: false, not
    # documented as such in this codebase before) means `src:` names a
    # file on the CONTROLLER, not the target - same category of gap
    # inline_copy_source_content/stage_large_copy_source already solve
    # for copy:, mirrored here via the same SCP-staging approach (an
    # archive is arbitrary binary data, so the "embed as content:"
    # shortcut copy: uses for small files doesn't apply; always stages
    # via SCP regardless of size, matching stage_large_copy_source's own
    # unconditional approach for a directory/big-file copy).
    #
    # unarchive.cr itself always runs its tar/unzip commands against
    # whatever filesystem it's actually executing on (the remote target,
    # once uploaded and run there like every other plugin) - previously
    # had no notion at all that `src:` might still be sitting on the
    # controller, so `remote_file_exists?(src)` always failed once a
    # play used a genuinely remote host and a controller-side src: path.
    # Found via prometheus.prometheus.node_exporter's own "Unpack binary
    # archive" task: the binary was downloaded to a `delegate_to:
    # localhost` cache dir (a real, common pattern for a role that
    # downloads once and extracts per-target), and the following
    # unarchive: task (no delegate_to, running on the real target) never
    # had that file transferred to it at all - "Source ... failed to
    # transfer" regardless of the file genuinely existing, just on the
    # wrong host.
    private def stage_unarchive_remote_src(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.unarchive"
      return params if ["true", "yes", "1", "on"].includes?(params["remote_src"]?.try(&.downcase))
      return params if PluginManager.is_local_connection?(host, vars_context)

      src = params["src"]?
      return params unless src && src.starts_with?('/') && File.exists?(src)

      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.crystal-ansible-unarchive-src-#{Random::Secure.hex(8)}-#{File.basename(src)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src,
          remote_tmp,
          host.port,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["src"] = remote_tmp
      resolved["remote_src"] = "true"
      resolved["__cleanup_after_unarchive"] = "true"
      resolved
    end

    # script:'s free-form `cmd` (or bare-string `_raw_params`, resolved to
    # `cmd` by RAW_COMMAND_MODULES parsing either way) is "<local path>
    # [args...]" - the path always names a file on the CONTROLLER, same
    # category of gap as unarchive:'s src: (see
    # #stage_unarchive_remote_src). Resolves the path against the
    # currently-executing role's own files/ dir first (real Ansible's own
    # script: action plugin searches there, same convention copy:/
    # template: use), then falls back to whatever's resolvable relative to
    # the controller's own cwd. A local connection needs the path resolved
    # (a role-relative name isn't meaningful relative to the plugin
    # process's own cwd otherwise) but never staged - the plugin process
    # already runs directly on the controller's filesystem in that case.
    private def stage_script_src(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.script"

      cmd = params["cmd"]? || params["_raw_params"]?
      return params unless cmd

      parts = cmd.strip.split(/\s+/, 2)
      local_path = parts[0]?
      return params if local_path.nil? || local_path.empty?
      rest = parts[1]?

      resolved_local = resolve_script_path(local_path, task)
      return params unless resolved_local

      if PluginManager.is_local_connection?(host, vars_context)
        resolved = params.dup
        resolved["cmd"] = rest ? "#{resolved_local} #{rest}" : resolved_local
        return resolved
      end

      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.crystal-ansible-script-#{Random::Secure.hex(8)}-#{File.basename(resolved_local)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          resolved_local,
          remote_tmp,
          host.port,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["cmd"] = rest ? "#{remote_tmp} #{rest}" : remote_tmp
      resolved["__cleanup_after_script"] = "true"
      resolved
    end

    # Resolves script:'s leading path token against (in order) the
    # currently-executing role's own files/ dir, then the controller's own
    # cwd (an absolute path, or a relative one for a playbook invoked from
    # its own directory - the common case). nil if it can't be found
    # anywhere, in which case the caller leaves params untouched and the
    # normal "file not found on target" failure surfaces from script.cr
    # itself once uploaded/executed.
    private def resolve_script_path(local_path : String, task : Task) : String?
      if role_dir = task.role_files_dir
        candidate = File.join(role_dir, local_path)
        return File.expand_path(candidate) if File.exists?(candidate)
      end
      return File.expand_path(local_path) if File.exists?(local_path)
      nil
    end

    # assemble:'s `src` defaults to `remote_src: true` (unlike copy:/
    # template:/unarchive:) - the common real-world shape is fragments
    # already deployed on the target by earlier copy:/template: tasks, so
    # no staging happens by default. Only `remote_src: false` (src names a
    # controller-side directory instead) needs the directory SCP'd up
    # first, same approach as copy:'s stage_directory_copy_source.
    private def stage_assemble_dir(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.assemble"
      return params if ["true", "yes", "1", "on"].includes?(params["remote_src"]?.try(&.downcase)) || params["remote_src"]?.nil?
      return params if PluginManager.is_local_connection?(host, vars_context)

      src = params["src"]?
      return params unless src && Dir.exists?(src)

      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.crystal-ansible-assemble-#{Random::Secure.hex(8)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src.rstrip('/'),
          remote_tmp,
          host.port,
          mode: nil,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?),
          recursive: true
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["src"] = remote_tmp
      resolved["__cleanup_after_assemble"] = "true"
      resolved
    end

    # Build plugin configuration
    private def build_plugin_config(
      task : Task,
      host : Host,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any),
      become_user : String? = task.become_user
    ) : String
      # Add check_mode and diff_mode to params
      final_params = params.dup
      final_params["check_mode"] = @check_mode.to_s
      final_params["diff_mode"] = @diff_mode.to_s

      # environment: - substituted here (once, with the same vars_context
      # every other param already uses) and forwarded as a single JSON
      # blob under a reserved param key; BasePlugin#remote_exec/#local_exec
      # read it back out and prefix whatever command the plugin shells out
      # with the equivalent `export K=V; ...` - applies uniformly to every
      # plugin that shells out (command/shell/apt/systemctl/...) rather
      # than needing separate wiring per plugin.
      if task_env = task.environment
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_env = task_env.transform_values { |v| substitutor.substitute(v) }
        final_params["_environment"] = substituted_env.to_json
      end

      # Only debug:/assert: actually read the vars context inside the
      # plugin process (BasePlugin itself only ever pulls 3 connection
      # keys out of it - see PluginManager::NEEDS_FULL_VARS). Everyone
      # else gets just those 3 keys instead of the full context, which
      # for a typical templating-heavy task is tens to hundreds of KB of
      # JSON (up to ~570 KB seen after a package_facts: task) that would
      # otherwise be base64'd over SSH and immediately discarded by the
      # plugin that receives it.
      wire_vars = if PluginManager.needs_full_vars?(task.module_name)
                    vars_context
                  else
                    pruned = Hash(String, JSON::Any).new
                    {"ansible_connection", "ansible_host", "ansible_ssh_private_key_file"}.each do |key|
                      if v = vars_context[key]?
                        pruned[key] = v
                      end
                    end
                    pruned
                  end

      config = {
        "host" => {
          "name" => host.name,
          "user" => host.user,
          "port" => host.port
        },
        "params" => final_params,
        "vars" => wire_vars,
        # Read by PluginManager, not by the plugin binary itself - become:
        # wraps the *whole* plugin process (local spawn or the remote SSH
        # command) in `sudo -n -u <user> --`, rather than being something
        # each plugin has to know about individually. Carried as plain
        # top-level config fields (not nested under "params") so this
        # round-trips through async:'s job file (written verbatim from this
        # same config) without __async_run needing any extra plumbing.
        "become" => task.become.to_s,
        "become_user" => become_user
      }

      config.to_json
    end
    
    # Matches real Ansible's `stdout_lines`/`stderr_lines` (built from
    # Python's `str.splitlines()`), not Crystal's plain `String#split("\n")`.
    # The two differ on exactly the cases that matter for real command
    # output: empty input - Python's splitlines() gives `[]`, Crystal's
    # split gives `[""]` (one empty element) - and any trailing newline,
    # which split() turns into a spurious final empty element that
    # splitlines() never produces. Found via konstruktoid-hardening's
    # "Delete unmanaged UFW rules" task: its `ufw_not_managed` command's
    # `grep -v` legitimately matches nothing (every rule this role adds is
    # tagged "ansible managed" and filtered out), producing empty stdout;
    # `ufw_not_managed.stdout_lines | length > 0` should then gate the
    # whole loop off, but the spurious `[""]` made it loop once with an
    # empty item, running `ufw delete ` with no rule spec at all - which
    # real `ufw` rejects with "ERROR: Invalid syntax".
    private def ansible_splitlines(text : String) : Array(String)
      return [] of String if text.empty?

      lines = text.split("\n")
      lines.pop if lines.last?.try(&.empty?)
      lines
    end

    # Register task result as a variable
    private def register_result(host : Host, register_name : String, result : JSON::Any)
      # Create a mutable copy of the result to add stdout_lines/stderr_lines
      result_hash = result.as_h.dup
      
      # Add stdout_lines by splitting stdout on newlines (Ansible behavior)
      if stdout = result_hash["stdout"]?.try(&.as_s)
        stdout_lines = ansible_splitlines(stdout).map { |line| JSON::Any.new(line) }
        result_hash["stdout_lines"] = JSON::Any.new(stdout_lines)
      end

      # Add stderr_lines by splitting stderr on newlines (Ansible behavior)
      if stderr = result_hash["stderr"]?.try(&.as_s)
        stderr_lines = ansible_splitlines(stderr).map { |line| JSON::Any.new(line) }
        result_hash["stderr_lines"] = JSON::Any.new(stderr_lines)
      end
      
      # Store the enhanced result
      @registered_vars[host.name][register_name] = JSON::Any.new(result_hash)
      @hv_generation += 1
    end
    
    # Run all notified handlers
    private def run_handlers
      # Create callback for handler execution
      # This allows HandlerRunner to execute handlers without duplicating logic
      execute_callback = ->(handler : Task, host : Host) : JSON::Any {
        execute_handler_internal(handler, host)
      }
      name_resolver = ->(handler : Task, host : Host) : String {
        render_task_name_for_display(handler, host)
      }

      @handler_runner.run(execute_callback, @results, @diff_mode, name_resolver, @halted_hosts)
    end
    
    # Execute a handler (internal - called via callback)
    private def execute_handler_internal(handler : Task, host : Host) : JSON::Any
      # Build variable context
      vars_context = VariableContext.build(
        @play_vars,
        host,
        handler,
        @registered_vars[host.name]
      )

      # Vars loaded at runtime via include_vars: (mirroring
      # #build_vars_context, used for regular tasks) - dev-sec apache_
      # hardening's own role loads its whole vars/Debian.yml (apache_
      # daemon, apache_conf_file, ...) this way (`include_vars: "{{
      # ansible_os_family }}.yml"`, not a static role vars/ file loaded
      # at parse time), and its "restart apache" handler references
      # apache_daemon exclusively. Without this, that var - along with
      # every other dynamically include_vars:'d one - was invisible to
      # every handler, resolving to the evaluator's undefined fallback
      # text (literally the word "undefined") rather than "apache2":
      # the handler tried to restart a service unit literally named
      # "undefined.service".
      @included_vars[host.name]?.try(&.each { |key, value| vars_context[key] = value })

      # ansible_parent_role_names/ansible_collection_name/ansible_role_name
      # (mirroring #build_vars_context, used for regular tasks) - a
      # role-loaded handler's OWN name:/module params can reference these
      # exactly like a regular task's can (`prometheus.prometheus`'s own
      # `_common` role: `name: "Restart {{ _common_service_name }}"`,
      # where `_common_service_name` derives from
      # `ansible_parent_role_names | first`). Without this, any handler
      # whose own vars ultimately depend on these magic vars resolved
      # them as "undefined" - the handler could still be correctly
      # MATCHED and triggered (a separate fix, notify_handlers/
      # should_run_handler?'s role-qualified match), but its own body
      # then acted on the wrong (undefined) value.
      if role_name = handler.role_name
        vars_context["ansible_role_name"] = JSON::Any.new(role_name)
      end
      if parent_names = handler.role_parent_names
        vars_context["ansible_parent_role_names"] = JSON::Any.new(parent_names.map { |n| JSON::Any.new(n) })
      end
      if collection_name = handler.ansible_collection_name
        vars_context["ansible_collection_name"] = JSON::Any.new(collection_name)
      end

      # Add facts to context, both under their flat `ansible_xxx` spelling
      # and as one `ansible_facts` dict (mirroring #build_vars_context,
      # used for regular tasks) - dev-sec os_hardening's own handlers gate
      # on `ansible_facts.os_family == 'RedHat'` exclusively, never the
      # flat spelling. Without the dict form, every dotted `ansible_facts.
      # *` reference in a handler's `when:` resolved to undefined and the
      # handler silently skipped regardless of the real fact value - e.g.
      # "Restart auditd via service" skipped on every host, including
      # RedHat-family ones it's meant to run on, even though a plain task
      # in the same play correctly saw `ansible_facts.os_family` as
      # "RedHat".
      unless @facts[host.name].empty?
        @facts[host.name].each do |key, value|
          vars_context[key] = value
        end
        vars_context["ansible_facts"] = JSON::Any.new(facts_dict_for(host.name))
      end

      vars_context["hostvars"] = JSON::Any.new(build_hostvars)
      vars_context["groups"] = JSON::Any.new(build_groups)

      # Evaluate the handler's own when: - real Ansible skips a notified
      # handler whose condition is false (e.g. os_hardening's "Restart
      # auditd via service" handler is gated on os_family == 'RedHat', so
      # it never runs on Debian/Ubuntu). Previously a notified handler ran
      # unconditionally, which both did the wrong work and, when that work
      # failed (service not present on the family), could halt the play.
      # A skipped handler is not shown as changed/failed and isn't counted
      # in the recap, matching real Ansible, which prints `skipping:` and
      # moves on.
      if when_condition = handler.when_condition
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(when_condition)

        unless ConditionalEvaluator.evaluate(substituted_condition, vars_context)
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          puts "skipping: [#{connection_host}]".colorize(:cyan)
          return JSON.parse({
            "changed" => false,
            "failed"  => false,
            "skipped" => true,
          }.to_json)
        end
      end

      # loop:/with_*: on a handler (e.g. linux-system-roles' journald
      # role: `loop: "{{ __journald_services }}"`, restarting each
      # service in a role-vars list) - previously entirely unhandled
      # here, so a looped handler ran its module exactly once with
      # `item` undefined instead of once per item ("Failed to restart
      # undefined.service: Unit undefined.service not found."). Mirrors
      # the essential semantics of the regular-task loop path
      # (execute_looped_task/finish_looped_task) without reusing it
      # directly - that path is wired into @results/@registered_vars/
      # display bookkeeping specific to the TASK recap, whereas a
      # handler's own accounting already happens in HandlerRunner#run
      # around this method's single return value. Resolves the same
      # loop sources a regular task's own resolution chain does, minus
      # with_fileglob/with_first_found (need a delegate host + shared
      # substitutor a handler has no equivalent concept of, and are
      # vanishingly rare on a handler in practice).
      loop_items = handler.loop_items ||
        resolve_loop_template(handler, vars_context) ||
        resolve_loop_flattened(handler, vars_context, host.name) ||
        resolve_loop_subelements(handler, vars_context)

      result = loop_items ? execute_handler_loop(handler, host, vars_context, loop_items) : execute_handler_plugin_once(handler, host, vars_context)

      # A handler can itself notify: further handlers (robertdebock.
      # auditd's own "Run augenrules" -> notify: "Load rules" -> real
      # Ansible runs "Load rules" within the SAME flush_handlers pass,
      # since HandlerRunner#run's @handlers.each iterates in definition
      # order and "Load rules" is defined after "Run augenrules" - by
      # the time the loop reaches it, this notify call has already
      # landed in @notified_handlers and should_run_handler? picks it
      # up naturally, no restructuring of #run needed. Previously
      # entirely unhandled - only a regular TASK's own notify: was ever
      # forwarded to HandlerRunner, so a handler-to-handler notify
      # silently dropped the second handler ("Load rules" never ran,
      # `augenrules --load` never re-applied the just-regenerated
      # rules).
      changed = result["changed"]?.try(&.as_bool) == true
      if changed && (notify_list = handler.notify)
        notify_handlers(handler, host, notify_list)
      end

      # A failed handler halts the rest of the play for this host, same
      # as a failed regular task (real Ansible: an unrescued handler
      # failure aborts the host's play run) - every other execution path
      # in this file (execute_looped_task, execute_include_tasks, the
      # plain-task path, etc.) calls halt_if_failed, but this one never
      # did. robertdebock.unbound's own `./configure --enable-systemd`
      # handler genuinely fails on stock Ubuntu 22.04 (libsystemd-dev
      # not installed - a real external role/environment gap, reproduces
      # on real ansible-playbook too, which correctly stops right there)
      # - crystal-ansible instead kept running every task after the
      # `meta: flush_handlers` that triggered it, diverging from real
      # Ansible's own recap (extra ok:/changed:/failed: entries for
      # tasks real Ansible never even attempted).
      halt_if_failed(handler, host, result["failed"]?.try(&.as_bool) == true) unless handler.ignore_errors

      result
    end

    # Runs *handler*'s module once per *loop_items* entry (item/loop_var
    # bound in a per-iteration copy of *vars_context*, matching a regular
    # task's own loop binding), printing each item's own result line and
    # returning one aggregate result (changed: true if any item changed,
    # failed: true if any item failed) - HandlerRunner#run's own
    # display/stats step is then a no-op on the boolean summary alone,
    # not a second full display pass, via the `already_displayed` marker.
    private def execute_handler_loop(
      handler : Task,
      host : Host,
      base_vars_context : Hash(String, JSON::Any),
      loop_items : Array(JSON::Any)
    ) : JSON::Any
      loop_var = handler.loop_var
      index_var = handler.index_var
      any_changed = false
      any_failed = false

      loop_items.each_with_index do |item, idx|
        vars_context = base_vars_context.dup
        vars_context["item"] = item
        vars_context[loop_var] = item if loop_var
        vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var

        result = execute_handler_plugin_once(handler, host, vars_context)
        next if result["skipped"]?.try(&.as_bool)

        any_changed ||= result["changed"]?.try(&.as_bool) || false
        any_failed ||= result["failed"]?.try(&.as_bool) || false
        ResultDisplay.display_result(host, result, @diff_mode, item_label: item_display(item))
      end

      JSON.parse({
        "changed"            => JSON::Any.new(any_changed),
        "failed"             => JSON::Any.new(any_failed),
        "already_displayed"  => JSON::Any.new(true),
      }.to_json)
    end

    # The actual single-execution body every handler run (looped or not)
    # goes through - unchanged from before loop: support was added, just
    # extracted so execute_handler_loop can call it once per item.
    private def execute_handler_plugin_once(handler : Task, host : Host, vars_context : Hash(String, JSON::Any)) : JSON::Any
      substitutor = VarSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )

      # Substitute variables in handler parameters
      substituted_params = substitute_task_params(handler.params, substitutor)

      if handler.module_name == "ansible.builtin.reboot"
        result = execute_reboot(substituted_params, host, vars_context)
        result = apply_changed_failed_when(handler, result, vars_context, host)
        if register_name = handler.register
          register_result(host, register_name, result) unless register_name.empty?
        end
        return result
      end

      # Same role-relative src: resolution + remote staging a regular
      # task's #execute_task_once/#prepare_batch_step already do -
      # previously missing here entirely, so a handler using copy:/
      # template: with a role-relative src: (not just an action-plugin
      # module, see #execute_handler_internal's own doc comment above)
      # would fail identically to the resolve_role_relative_src bug just
      # fixed for regular tasks. Found while auditing that fix, not yet
      # hit by a real role in this round.
      substituted_params = resolve_role_relative_src(handler, substituted_params)
      substituted_params = inline_copy_source_content(handler, substituted_params, host, vars_context)
      substituted_params = stage_unarchive_remote_src(handler, substituted_params, host, vars_context)
      substituted_params = stage_script_src(handler, substituted_params, host, vars_context)
      substituted_params = stage_assemble_dir(handler, substituted_params, host, vars_context)
      substituted_become_user = handler.become_user.try { |raw_user| substitutor.substitute(raw_user) }

      # Real bug found benchmarking geerlingguy.jenkins: its own
      # "configure default users" handler is a template: task
      # (`handlers/main.yml`, not `tasks/`) - unlike #execute_task_once/
      # #prepare_batch_step above, this method never ran a handler's
      # module through ActionPluginManager at all, so template:'s own
      # controller-side render step (reading/rendering the .j2 file
      # locally, then injecting the result as a `content:` param before
      # dispatch) never happened for ANY handler, only regular tasks:.
      # The plugin then ran on the remote host with no `content:` param
      # at all and failed outright - not a silent divergence, every
      # template:/copy:-with-role-src:/etc. handler in a real playbook
      # would hit this identically.
      if ActionPluginManager.has_action_plugin?(handler.module_name)
        action_result = ActionPluginManager.execute_action(
          handler.module_name,
          substituted_params,
          vars_context,
          host
        )

        unless action_result.success
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }.to_json)
        end

        if final = action_result.final_result
          result = apply_changed_failed_when(handler, final, vars_context, host)
          if register_name = handler.register
            register_result(host, register_name, result) unless register_name.empty?
          end
          return result
        end

        if modified_params = action_result.modified_params
          substituted_params = modified_params
        end
      end

      # Build config for plugin - serialized once, with
      # ansible_connection=local already in the wire payload when this
      # handler runs over SSH (same treatment as execute_task_once).
      wire_vars = vars_context
      if PluginManager.remote_execution?(handler.module_name, host, vars_context)
        wire_vars = vars_context.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      config = build_plugin_config(handler, host, substituted_params, wire_vars, substituted_become_user)

      become = resolve_task_become(handler, substitutor)
      become_user = nil

      if become
        candidate = substituted_become_user
        become_user = (candidate.nil? || candidate.empty?) ? "root" : candidate

        unless PluginManager.valid_become_user?(become_user)
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "become_user #{become_user.inspect} is not a valid username",
          }.to_json)
        end
      end

      result = PluginManager.execute_plugin(
        handler.module_name,
        config,
        host,
        vars_context,
        become,
        become_user
      )

      # A handler's own changed_when:/failed_when:/register: were
      # entirely unapplied - this method just returned the raw plugin
      # result. Same "separate dispatch path from regular tasks, missing
      # a step the regular path already has" pattern already found for
      # handlers using an action-plugin module and handler loops (see
      # this method's own doc comment above, and execute_handler_loop's)
      # - found via geerlingguy.gitlab's own "restart gitlab" handler
      # (`command: gitlab-ctl reconfigure`, `failed_when:
      # gitlab_restart_handler_failed_when | bool`, `register:
      # gitlab_restart`): a real, expected-to-sometimes-fail reconfigure
      # (a known upstream GitLab/role-version incompatibility, not a
      # crystal-ansible bug - confirmed identically failing when run
      # directly on both hosts) always propagated as a genuine task
      # failure, since failed_when could never suppress it here, while
      # real ansible-playbook's own run of the identical role reports
      # this handler as "changed", not failed.
      result = apply_changed_failed_when(handler, result, vars_context, host)

      if register_name = handler.register
        register_result(host, register_name, result) unless register_name.empty?
      end

      result
    end
  end
end
