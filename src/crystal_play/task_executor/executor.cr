require "json"
require "colorize"
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
    # Hosts that hit a failed task without ignore_errors: further tasks in
    # the play are skipped for them (Ansible's default "a failure aborts
    # the rest of the play for that host" behavior). Public - crystal-
    # play.cr reads this after #run to carry a failed host forward and
    # exclude it from every *remaining* play in the whole run too, not
    # just the rest of this one (real Ansible's actual behavior; see
    # ROADMAP.md's `0.9.61`-found, `0.9.64`-fixed cross-cutting engine
    # gap entry).
    getter halted_hosts : Set(String)
    # Full inventory, used to resolve delegate_to: targets that aren't
    # necessarily in this play's own host list (e.g. "localhost" when the
    # play targets a remote group). Optional - a caller that doesn't pass
    # one (or a delegate_to: target it can't find) falls back to a bare
    # Host constructed from the target name, same as Inventory#get_hosts's
    # own implicit-localhost behavior.
    @inventory : Inventory?
    # Batches consecutive independent tasks bound for the same remote
    # host into a single SSH round trip instead of one round trip per
    # task - default on since 0.9.63; --no-batching opts out. See
    # TaskBatcher for the batchability predicate and ROADMAP.md's
    # `0.9.61`/`0.9.62`/`0.9.63` entries for the design, hardening pass,
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
    # include_tasks:/include_role: always run one host at a time
    # regardless of this value. See `run_task_for_hosts_in_parallel`.
    @forks : Int32

    def initialize(
      @hosts,
      @tasks,
      @handlers = [] of Task,
      @check_mode = false,
      @diff_mode = false,
      @play_vars = {} of String => JSON::Any,
      @gather_facts = true,
      @inventory = nil,
      @batching_enabled = true,
      @forks = 5,
      @smart_gathering = false,
      fact_store : Hash(String, Hash(String, JSON::Any))? = nil
    )
      @results = Hash(String, Hash(String, Int32)).new
      @registered_vars = Hash(String, Hash(String, JSON::Any)).new
      # Under --gathering smart the caller owns a single run-scoped store
      # and hands the same one to every play's executor, so facts gathered
      # in play 1 are still there in play 4. With no store passed (the
      # default), this is per-play exactly as before.
      @facts = fact_store || Hash(String, Hash(String, JSON::Any)).new
      @halted_hosts = Set(String).new
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

      ensure_grouped(@tasks)

      @tasks.each do |task|
        puts "TASK [#{task.name}]".colorize(:white).bold
        puts "*" * 70

        active_hosts = @hosts.reject { |host| @halted_hosts.includes?(host.name) }

        if @forks > 1 && task_forkable?(task) && active_hosts.size > 1
          run_task_for_hosts_in_parallel(task, active_hosts)
        else
          active_hosts.each { |host| execute_task(task, host) }
        end

        puts ""
      end

      # Run handlers at the end of all tasks (Ansible behavior)
      run_handlers
    end

    # Whether *task* can safely fan out across hosts via --forks. Excluded:
    # run_once: (needs @hosts.first to have actually finished before other
    # hosts can copy its register via copy_run_once_register - a real
    # ordering dependency, not just a data-race concern) and the
    # structural/dynamic task kinds (block?/include_tasks?/include_role?),
    # which recurse into their own nested task lists and ensure_grouped
    # calls - kept serial to sidestep any question of concurrent
    # re-entrancy into the batching planner. Every other task kind only
    # ever touches per-host keys of hashes pre-seeded with every host's
    # key in #initialize, which is safe under cooperative fiber scheduling
    # (see run_task_for_hosts_in_parallel's own docs for the full argument).
    private def task_forkable?(task : Task) : Bool
      return false if task.run_once
      return false if task.block?
      return false if task.include_tasks?
      return false if task.include_role?
      true
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
    private def run_task_for_hosts_in_parallel(task : Task, hosts : Array(Host))
      max_parallel = Math.min(hosts.size, @forks)
      gate = Channel(Nil).new(max_parallel)
      max_parallel.times { gate.send(nil) }
      done = Channel(Nil).new
      buffers = Hash(String, IO::Memory).new

      hosts.each do |host|
        spawn do
          gate.receive
          buffer = IO::Memory.new
          OutputRouting.redirect_current_fiber_to(buffer)
          begin
            execute_task(task, host)
          ensure
            OutputRouting.clear_current_fiber_redirect
          end
          buffers[host.name] = buffer
        ensure
          gate.send(nil)
          done.send(nil)
        end
      end

      hosts.size.times { done.receive }

      hosts.each do |host|
        if buffer = buffers[host.name]?
          print buffer.to_s
        end
      end
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
    # `0.9.77`. See ROADMAP.md for both.
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
      return execute_meta(task, host) if task.meta?
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
        resolve_loop_flattened(task, vars_context) ||
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

      finish_single_task(task, host, result)
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
      fallback.vars["ansible_connection"] = JSON::Any.new("local") if target_name == "localhost"
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
      end
    end

    # Build the base variable context (play/host/registered/task vars + facts)
    # shared by every execution path for a task.
    private def build_vars_context(task : Task, host : Host) : Hash(String, JSON::Any)
      vars_context = VariableContext.build(
        @play_vars,
        host,
        task,
        @registered_vars[host.name]
      )

      @included_vars[host.name]?.try(&.each { |key, value| vars_context[key] = value })

      @facts[host.name].each do |key, value|
        vars_context[key] = value
      end

      # Magic variables belong in vars_context itself, not only in the
      # copy VarSubstitutor makes. Bare conditions - `when:`,
      # `until:`, `changed_when:`, `failed_when:`, and `assert:`'s
      # `that:` (which is evaluated inside the plugin, against the "vars"
      # this context is serialized into) - are evaluated directly against
      # vars_context and never saw them, so `when: inventory_hostname ==
      # "web1"` silently skipped every task while
      # `when: "{{ inventory_hostname }} == web1"` worked.
      #
      # Applied after facts, with the same precedence rules
      # VarSubstitutor#add_magic_variables uses - see there for why only
      # inventory_hostname is unconditional.
      vars_context["inventory_hostname"] = JSON::Any.new(host.name)
      vars_context["ansible_hostname"] ||= JSON::Any.new(host.name)
      vars_context["ansible_host"] ||= JSON::Any.new(host.name)
      if role_name = task.role_name
        vars_context["ansible_role_name"] = JSON::Any.new(role_name)
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
      # the two spellings can never disagree, and rebuilt per task so a
      # fact added mid-play (set_fact:, a re-gather) appears in both.
      unless @facts[host.name].empty?
        facts_dict = Hash(String, JSON::Any).new
        @facts[host.name].each do |key, value|
          facts_dict[key.lchop("ansible_")] = value
        end
        vars_context["ansible_facts"] = JSON::Any.new(facts_dict)
      end

      render_task_vars(task, vars_context, host.name)

      vars_context
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
    private def render_task_vars(task : Task, vars_context : Hash(String, JSON::Any), host_name : String)
      task.vars.each_key do |key|
        raw = vars_context[key]?
        next unless raw && (raw_string = raw.raw.as?(String)) && raw_string.includes?("{{")

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
        rendered = substitutor.substitute(raw_string)

        # A dict/list-valued task var (mountinfo above) renders to JSON
        # object/array text via VariableLookup#format_value - parsed back
        # to real structure so dotted/indexed access into it
        # (`mountinfo.device`) works, the same reasoning as set_fact's own
        # dict/array coercion.
        parsed = (rendered.starts_with?('{') || rendered.starts_with?('[')) ? (JSON.parse(rendered) rescue nil) : nil
        vars_context[key] = parsed || JSON::Any.new(rendered)
      end
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
        value.as_a?
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
    private def resolve_loop_flattened(task : Task, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      sources = task.loop_flattened
      return nil unless sources

      result = [] of JSON::Any
      sources.each do |raw|
        value = resolve_template_value(raw, vars_context)
        next unless value
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
        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
        suffix = item_label ? " => (item=#{item_label})" : ""
        puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
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
      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
      puts "skipping: [#{connection_host}]".colorize(:cyan)
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
    private def prepare_batch_step(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : JSON::Any | BatchScript::Step
      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      substituted_params = substitute_task_params(task.params, substitutor)
      substituted_params = resolve_role_relative_src(task, substituted_params)
      substituted_params = inline_copy_source_content(task, substituted_params, host, vars_context)
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

        substituted_params = action_result.modified_params || substituted_params
      end

      become = task.become
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
      substituted_params = substitute_task_params(task.params, substitutor)
      substituted_params = resolve_role_relative_src(task, substituted_params)
      substituted_params = inline_copy_source_content(task, substituted_params, exec_host, vars_context)
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
      become = task.become
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
      is_local = exec_host.vars["ansible_connection"]?.try(&.as_s?) == "local" || exec_host.name == "localhost"
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
    private def finish_single_task(task : Task, host : Host, result : JSON::Any)
      merge_ansible_facts(host, result)

      if register_name = task.register
        register_result(host, register_name, result) unless register_name.empty?
      end

      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        notify_list.each { |handler_name| @handler_runner.notify(host, handler_name) } unless notify_list.empty?
      end

      ResultDisplay.display_result(host, result, @diff_mode)
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
                       rendered_items.map do |item|
                         vars_context = running_vars_context.dup
                         vars_context["item"] = item
                         vars_context[loop_var] = item if loop_var
                         result = execute_task_once(task, host, vars_context, item_label: item_display(item), exec_host: exec_host, defer_loop_stats: true)
                         if result && (facts = result["ansible_facts"]?) && (facts_hash = facts.as_h?)
                           facts_hash.each { |key, value| running_vars_context[key] = value }
                         end
                         result
                       end
                     end

      finish_looped_task(task, host, rendered_items, item_results)
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
    private def loop_batch_eligible?(task : Task, host : Host, exec_host : Host, vars_context : Hash(String, JSON::Any)) : Bool
      return false unless @batching_enabled
      return false unless exec_host == host
      return false if task.module_name.ends_with?("set_fact")
      return false if task.delegate_to
      return false if PluginManager.is_local_connection?(exec_host, vars_context)
      return false if task.changed_when || task.failed_when
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

      loop_items.each_with_index do |item, idx|
        vars_context = base_vars_context.dup
        vars_context["item"] = item
        vars_context[loop_var] = item if loop_var
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
    private def finish_looped_task(task : Task, host : Host, loop_items : Array(JSON::Any), item_results : Array(JSON::Any?))
      results = [] of JSON::Any
      any_changed = false
      any_failed = false

      executed_count = 0
      loop_items.each_with_index do |item, idx|
        result = item_results[idx]
        next unless result

        executed_count += 1
        merge_ansible_facts(host, result)

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
        notify_list.each { |handler_name| @handler_runner.notify(host, handler_name) } unless notify_list.empty?
      end

      if register_name = task.register
        unless register_name.empty?
          aggregate = {
            "changed" => JSON::Any.new(any_changed),
            "failed"  => JSON::Any.new(any_failed),
            "results" => JSON::Any.new(results),
          }
          @registered_vars[host.name][register_name] = JSON::Any.new(aggregate)
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
        notify_list.each { |handler_name| @handler_runner.notify(host, handler_name) } unless notify_list.empty?
      end

      ResultDisplay.display_result(host, result, @diff_mode)
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

        puts "TASK [#{nested_task.name}]".colorize(:white).bold
        puts "*" * 70
        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
        puts "skipping: [#{connection_host}]".colorize(:cyan)
        @results[host.name]["skipped"] += 1
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
        puts "TASK [#{nested_task.name}]".colorize(:white).bold
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
      loop_items = task.loop_items

      if loop_items
        # The item is exposed as `item` (Ansible's default) and, when
        # loop_control.loop_var is set, under that custom name too (e.g.
        # `mount` in dev-sec os_hardening's per-mountpoint include loop).
        loop_var = task.loop_var
        loop_items.each do |item|
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
          # Each include_tasks loop iteration counts as one `ok` in the
          # recap, matching real Ansible (which tallies the include plus
          # every included task per iteration).
          @results[host.name]["ok"] += 1
          run_include_tasks_once(task, host, vars_context, item_display(item))
        end
      else
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

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      file_rel = substitutor.substitute(task.include_file.as(String))
      resolved_path = File.expand_path(file_rel, task.include_file_dir.as(String))

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
      # Only clear_facts parses (see PlaybookParser.parse_meta_task), so
      # there is no other action to dispatch on here.
      @facts[host.name].clear
    end

    private def execute_include_role(task : Task, host : Host)
      base_vars_context = build_vars_context(task, host)
      loop_items = task.loop_items

      if loop_items
        loop_var = task.loop_var
        loop_items.each do |item|
          vars_context = base_vars_context.dup
          vars_context["item"] = item
          vars_context[loop_var] = item if loop_var
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

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      role_name = substitutor.substitute(task.include_role_name.as(String))

      inherited = Play.new("", "")
      inherited.become = task.become
      inherited.become_user = task.become_user

      begin
        included_tasks, included_handlers = RoleLoader.load_single_role(
          role_name,
          task.include_role_vars || Hash(String, JSON::Any).new,
          task.tags,
          inherited,
          task.include_role_dir.as(String)
        )
      rescue ex
        fail_include(task, host, "Failed to load role '#{role_name}': #{ex.message}")
        return
      end

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

      role_dir = case task.module_name
                 when "ansible.builtin.copy"     then task.role_files_dir
                 when "ansible.builtin.template"  then task.role_templates_dir
                 else                                  nil
                 end
      return params unless role_dir

      resolved = params.dup
      resolved["src"] = File.join(role_dir, src)
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
    private def inline_copy_source_content(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.copy"
      return params if ["true", "yes", "1", "on"].includes?(params["remote_src"]?.try(&.downcase))
      return params if PluginManager.is_local_connection?(host, vars_context)

      src = params["src"]?
      return params unless src && src.starts_with?('/')

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

      config = {
        "host" => {
          "name" => host.name,
          "user" => host.user,
          "port" => host.port
        },
        "params" => final_params,
        "vars" => vars_context,
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
    end
    
    # Run all notified handlers
    private def run_handlers
      # Create callback for handler execution
      # This allows HandlerRunner to execute handlers without duplicating logic
      execute_callback = ->(handler : Task, host : Host) : JSON::Any {
        execute_handler_internal(handler, host)
      }
      
      @handler_runner.run(execute_callback, @results, @diff_mode)
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
        facts_dict = Hash(String, JSON::Any).new
        @facts[host.name].each do |key, value|
          vars_context[key] = value
          facts_dict[key.lchop("ansible_")] = value
        end
        vars_context["ansible_facts"] = JSON::Any.new(facts_dict)
      end

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

      # FIXED: Use VarSubstitutor instead of VariableSubstitutor
      substitutor = VarSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )
      
      # Substitute variables in handler parameters
      substituted_params = substitute_task_params(handler.params, substitutor)
      substituted_become_user = handler.become_user.try { |raw_user| substitutor.substitute(raw_user) }

      # Build config for plugin - serialized once, with
      # ansible_connection=local already in the wire payload when this
      # handler runs over SSH (same treatment as execute_task_once).
      wire_vars = vars_context
      if PluginManager.remote_execution?(handler.module_name, host, vars_context)
        wire_vars = vars_context.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      config = build_plugin_config(handler, host, substituted_params, wire_vars, substituted_become_user)

      become = handler.become
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

      PluginManager.execute_plugin(
        handler.module_name,
        config,
        host,
        vars_context,
        become,
        become_user
      )
    end
  end
end
