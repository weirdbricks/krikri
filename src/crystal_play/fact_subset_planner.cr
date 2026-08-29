require "./playbook_parser"

module CrystalPlay
  # OPUS_PERFORMANCE_IMPROVEMENTS.md item 12 - "gather only the facts the
  # play references". BREAKING, and therefore reachable only from the
  # `crystal-ansible-fast` binary (see FastMode).
  #
  # `gather_facts` collects three optional families on top of an
  # always-gathered floor. Measured with the real plugin: the full set
  # costs ~88ms, `min` ~37ms - so a play that never reads a hardware,
  # network or mount fact is paying ~50ms per host per play for nothing.
  # That is small in absolute terms and large relative to a sub-second
  # warm run, which is exactly the shape items 1-3 cannot help.
  #
  # ## Why this is BREAKING and cannot be the default
  #
  # The analysis is textual. It sees `ansible_default_ipv4` written out
  # in a template or a `when:`, and it does NOT see:
  #
  #   - `vars['ansible_' ~ something]` or any other computed name
  #   - `hostvars[h].ansible_mounts` read for a DIFFERENT host
  #   - a fact read only inside a `.j2` file this scan never opens
  #   - a fact a custom module or lookup pulls from the fact dict
  #
  # Any of those yields an undefined variable instead of a value, which
  # is a wrong answer rather than a slow one. Hence: opt-in binary, and
  # the planner is deliberately generous - it keeps a family on ANY
  # sighting, and keeps everything the moment it sees a dynamic-looking
  # fact reference at all.
  module FactSubsetPlanner
    # Fact keys contributed by each optional family, from
    # FactsGatherer's own `subset_enabled?` gates. Keep in step with it:
    # a key that moves between families and is not listed here would be
    # silently dropped.
    FAMILY_FACTS = {
      "network"  => %w[ansible_all_ipv4_addresses ansible_default_ipv4],
      "hardware" => %w[
        ansible_memfree_mb ansible_memtotal_mb ansible_processor
        ansible_processor_cores ansible_processor_count
        ansible_processor_vcpus ansible_swapfree_mb ansible_swaptotal_mb
      ],
      "mounts" => %w[ansible_mounts],
    }

    # Anything matching this means a fact name is being BUILT rather than
    # written literally, so no textual scan can know which one. Seeing it
    # abandons the optimization for the whole run.
    DYNAMIC_MARKERS = [
      "ansible_facts[", "vars['ansible", "vars[\"ansible",
      "hostvars", "'ansible_' ~", "\"ansible_\" ~",
    ]

    # Returns the gather_subset tokens to pass, or nil meaning "gather
    # everything, this play is not safely analysable".
    def self.plan(playbook : Playbook) : Array(String)?
      text = collect_text(playbook)
      return nil if DYNAMIC_MARKERS.any? { |marker| text.includes?(marker) }

      needed = FAMILY_FACTS.keys.select do |family|
        FAMILY_FACTS[family].any? { |fact| text.includes?(fact) }
      end
      return nil if needed.size == FAMILY_FACTS.size

      # Expressed as `all` plus subtractions rather than as an
      # allow-list, so a family this planner does not know about stays
      # gathered. The leading `all` is load-bearing, not decoration:
      # FactsGatherer#subset_enabled? starts from
      # `subset.empty? || subset.includes?("all")`, so a bare
      # `!network,!mounts` reads as an allow-list of nothing and
      # disables EVERY optional family - including ones the play does
      # reference. Caught by a play that reads ansible_processor_vcpus:
      # the planner correctly kept `hardware`, and the fact came back
      # undefined anyway. This is also real Ansible's own spelling
      # (`all,!hardware`).
      ["all"] + (FAMILY_FACTS.keys - needed).map { |family| "!#{family}" }
    end

    # Every string in the play a fact name could plausibly appear in.
    # Deliberately over-collects - a false "this fact is used" only costs
    # the speedup, while a false "unused" costs correctness.
    private def self.collect_text(playbook : Playbook) : String
      String.build do |io|
        playbook.plays.each do |play|
          play.vars.each { |key, value| io << key << ' ' << value.to_s << ' ' }
          collect_tasks(play.tasks, io)
          collect_tasks(play.handlers, io)
        end
      end
    end

    private def self.collect_tasks(tasks : Array(Task), io : IO) : Nil
      tasks.each do |task|
        task.params.each_value { |value| io << value << ' ' }
        task.vars.each_value { |value| io << value.to_s << ' ' }
        {task.when_condition, task.changed_when, task.failed_when,
         task.until_condition, task.delegate_to}.each do |expr|
          io << expr << ' ' if expr
        end
        {task.block_tasks, task.rescue_tasks, task.always_tasks}.each do |nested|
          collect_tasks(nested, io) if nested
        end
      end
    end
  end
end
