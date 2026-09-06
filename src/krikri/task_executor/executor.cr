require "json"
require "colorize"
require "digest/md5"
require "../playbook_parser"
require "../variable_substitutor"
require "../plugin_manager"
require "../conditional_evaluator"
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
require "../timing_profile"
require "../fact_cache"
require "random/secure"

require "../cli_options"

require "../task_debugger"

module Krikri
  # `ansible_version` - a real Ansible magic var (`{full, major, minor,
  # revision, string}`) giving the CONTROLLER's ansible-core version, used
  # by real roles for feature-detection (`ansible_version.string is
  # version_compare(min_version, '>=')`). Entirely unimplemented before -
  # any reference to it (even the common `ansible_version.string is
  # version_compare(...)` idiom, a BARE dotted lookup) resolved to this
  # engine's own "undefined" sentinel and either silently mis-evaluated
  # the comparison or (since 0.9.517's strict module-arg templating) hard
  # failed the task outright. Found live re-benchmarking xanmanning.k3s
  # (round 163 regression check) - its own `pre_checks.yml` gates on
  # exactly this pattern before doing anything else, so the WHOLE role
  # failed at task 1 on every rerun. Reports a real ansible-core version
  # (not this project's own "0.9.x" version number) deliberately: this
  # engine's whole design goal is behavioral parity with real Ansible, and
  # every version-gated role feature in the wild was written expecting a
  # 2.x-shaped comparison target, not a sub-1.0 one - reporting crystal's
  # own version here would make EVERY such min-version check fail
  # unconditionally, a worse outcome than picking one fixed real version.
  # 2.19.4 matches the exact ansible-core release this project's own
  # benchmark rounds compare against (see CLAUDE.md/ROLES_TESTED.md).
  ANSIBLE_VERSION_MAGIC_VAR = JSON.parse(%({
    "full": "2.19.4", "major": 2, "minor": 19, "revision": 4, "string": "2.19.4"
  }))

  # TaskExecutor - Executes tasks on hosts
  # Orchestrates task execution, variable substitution, and handler management
  class TaskExecutor
    property hosts : Array(Host)
    property tasks : Array(Task)
    property handlers : Array(Task)
    property? check_mode : Bool
    property? diff_mode : Bool
    # Real ansible-playbook's -v/-vv/-vvv/... count, exposed to task
    # templating as the ansible_verbosity magic var. See
    # #build_vars_context's own assignment for the full rationale.
    property verbosity : Int32
    property play_vars : Hash(String, JSON::Any)
    property? gather_facts : Bool

    # Track results for recap
    getter results : Hash(String, Hash(String, Int32))
    # Modules referenced by a task whose own when: (independent of the
    # forced-skip #when_passes? always takes for an unavailable module)
    # would have evaluated true for at least one host - i.e. genuinely
    # REACHED, not merely present somewhere in the playbook text. Real
    # Ansible only ever attempts module resolution for a task it's about
    # to run, so a module referenced only inside a branch that's
    # unreached on every host (`when: ansible_os_family == "Suse"` on an
    # Ubuntu run) never contributes to its exit code - the previous
    # whole-playbook static scan (PlaybookParser.unavailable_modules)
    # flagged ANY unresolvable module name found anywhere in the file
    # regardless of reachability, producing a false-positive exit 4
    # divergence from real Ansible's own (often 0 or 2) exit code on
    # every such role. Found via buluma.jenkins's own zypper_repository
    # task (round 180), gated behind an OS-family branch that's false on
    # every host this project benchmarks against (Ubuntu/RHEL-family).
    getter reachable_unavailable_modules = Set(String).new
    # Track registered variables per host
    @registered_vars : Hash(String, Hash(String, JSON::Any))
    # Handler runner
    @handler_runner : HandlerRunner
    # Facts per host
    @facts : Hash(String, Hash(String, JSON::Any))
    # The subset of @facts[host.name] that came from `set_fact`/
    # `register`-style high-precedence writes rather than an ordinary
    # fact-gathering module (setup/package_facts/service_facts/etc).
    # Real Ansible ranks these very differently - "host facts" (#11 in
    # the documented precedence order) sit BELOW play vars (#12), while
    # "set_facts / registered vars" (#19) sit near the very top, above
    # task vars. merge_ansible_facts writes every key into @facts
    # unconditionally (so `ansible_facts.*` always reflects the latest
    # real value regardless of precedence), but only ALSO writes here
    # when the producing task is set_fact - build_vars_context/
    # base_context_b_for use this to apply just the set_fact subset at
    # the high tier, while base_context_a_for fills the rest of @facts
    # in at the low tier. Found live testing itigoag.packages: a plain
    # `package_facts:` task's `ansible_facts.packages` was clobbering a
    # play-level `vars: packages: {...}` of the same bare name, which
    # real ansible-playbook never does (a play var always wins over
    # ordinary gathered facts).
    @set_facts : Hash(String, Hash(String, JSON::Any))
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
    # krikri-playbook.cr's cross-play carry-forward (permanently_failed_
    # hosts) or count toward the run's overall failed/exit-code status.
    getter ended_hosts : Set(String)
    # Hosts a real failure halted in this play whose error state was
    # since cleared via meta: clear_host_errors. Real Ansible's own
    # documented semantics: "makes them available for targeting in
    # subsequent plays, but not continue execution in the current
    # play" - so, unlike ended_hosts, these stay in halted_hosts (the
    # current play still stops for them) but are excluded from
    # krikri-playbook.cr's cross-play carry-forward the same way.
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
    # True for the `ansible` ad-hoc CLI (as opposed to `krikri-playbook`
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
    # reaps them. Safe here because krikri-playbook is a CLI tool (one
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
      # Carries the FINISHED host's name, not just a tick: the caller
      # prints each host's buffer as its name arrives, which is what
      # gives real Ansible's completion-order output.
      getter done_signal : Channel(String)
      getter gate : Channel(Nil)

      def initialize(@task : Task, @host : Host, @results : Hash(String, IO::Memory), @done_signal : Channel(String), @gate : Channel(Nil))
      end
    end

    def initialize(
      @hosts,
      @tasks,
      @handlers = [] of Task,
      @check_mode = false,
      @diff_mode = false,
      @verbosity = 0,
      @play_vars = {} of String => JSON::Any,
      # Play#all_role_defaults / #all_role_vars - every static role's own
      # defaults/vars, visible to EVERY role in the play including ones
      # that ran earlier (real Ansible loads them all at play setup).
      # See #build_vars_context for exactly where they rank.
      @all_role_defaults = {} of String => JSON::Any,
      @all_role_vars = {} of String => JSON::Any,
      @gather_facts = true,
      @inventory = nil,
      @inventory_path = nil,
      @batching_enabled = true,
      @forks = 5,
      @smart_gathering = false,
      fact_store : Hash(String, Hash(String, JSON::Any))? = nil,
      @adhoc = false,
      # -e/--extra-vars. Real Ansible's HIGHEST-precedence scope: they
      # beat play vars, role vars, task vars, inventory and facts, and
      # (verified against ansible-core 2.19.4) a later `set_fact` cannot
      # override one either - which is why these are applied at the very
      # END of build_vars_context rather than as a base layer.
      @extra_vars = {} of String => JSON::Any,
      # --force-handlers / the `force_handlers: true` play keyword: run
      # notified handlers even for a host a task already failed on.
      @force_handlers = false,
      # `vars_files:` - candidate path lists, resolved per host because a
      # path may be templated against that host's own facts.
      @vars_files = [] of Array(String),
      @vars_files_dir = ".",
      # The playbook's own directory, absolute - real Ansible's
      # `playbook_dir` magic var (see #apply_path_magic_vars). Defaults
      # to the working directory, which is also what real Ansible
      # reports for an ad-hoc run with no playbook at all.
      @playbook_dir = ".",
      # See Play#any_errors_fatal / Play#max_fail_percentage.
      @any_errors_fatal = false,
      @max_fail_percentage : Float64? = nil,
      # Hosts the pre-upload pass already found unreachable. Rather than
      # dropping them from the play, each task on such a host yields an
      # unreachable result - which is what makes per-task
      # `ignore_unreachable:` possible at all.
      @unreachable_hosts = Set(String).new,
      # `strategy:` - see Play#strategy. Only "free" changes anything
      # here; linear is this engine's existing behavior, and
      # host_pinned is treated as free (its only difference is worker
      # affinity, which this engine has no equivalent of).
      @strategy : String? = nil,
      # See Play#gather_subset - forwarded to the facts plugin, which
      # does the actual family filtering.
      @gather_subset = [] of String,
      # See Play#remote_user.
      @remote_user : String? = nil,
      # See Play#debugger.
      @debugger : String? = nil,
    )
      @results = Hash(String, Hash(String, Int32)).new
      @registered_vars = Hash(String, Hash(String, JSON::Any)).new
      # Under --gathering smart the caller owns a single run-scoped store
      # and hands the same one to every play's executor, so facts gathered
      # in play 1 are still there in play 4. With no store passed (the
      # default), this is per-play exactly as before.
      @facts = fact_store || Hash(String, Hash(String, JSON::Any)).new
      @set_facts = Hash(String, Hash(String, JSON::Any)).new
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
          "ok"          => 0,
          "changed"     => 0,
          "unreachable" => 0,
          "failed"      => 0,
          "skipped"     => 0,
          "rescued"     => 0,
          "ignored"     => 0,
        }
        @registered_vars[host.name] = {} of String => JSON::Any
        # ||=, not =: a shared run-scoped store may already hold this
        # host's facts from an earlier play, and pre-seeding must not
        # wipe them. Registered vars deliberately stay per-play.
        @facts[host.name] ||= {} of String => JSON::Any
        @set_facts[host.name] = {} of String => JSON::Any
      end

      # See flatten_handler_blocks's own comment: a block:-wrapped
      # handler (handlers/main.yml entries using block:/rescue: purely
      # to add rescue-time diagnostics around the real handler) must be
      # expanded into its nested block_tasks BEFORE HandlerRunner ever
      # sees @handlers - every downstream handler lookup/dispatch path
      # only ever understands a flat Array(Task).
      @handlers = flatten_handler_blocks(@handlers)

      # Initialize handler runner
      @handler_runner = HandlerRunner.new(@handlers, @hosts)
    end

    # Main execution loop
    def run : Nil
      # Gather facts if enabled
      if @gather_facts
        gather_facts_for_all_hosts
      end

      if free_strategy?
        run_free
      else
        run_task_batch(@tasks, @hosts)
      end

      # Run handlers at the end of all tasks (Ansible behavior)
      run_handlers
    end

    # One host's whole task list, flushing output after EACH task rather
    # than at the end. Real Ansible emits a host's banner and its result
    # together - under `free` you see "TASK [x] / changed: [h2]" as a
    # pair, then h2's next pair, while h1 is still working - so buffering
    # per host (rather than per task) would group all of a host's output
    # into one block and lose exactly the interleaving the strategy is
    # for.
  end
end
