require "json"

# ansible-core 2.21 rebuilt task-result assembly on a dataclass
# (ansible._internal._task.UnifiedTaskResult): the exported result renders
# the dataclass's declared fields first (in declaration order, present
# ones only), then the module's own keys (result_data), then the derived
# stdout_lines/stderr_lines. Concretely - live-verified against a real
# 2.21.6 controller across stat/file/copy/getent/command/fail, solo and
# looped, ok/failed/skipped/failed_when-suppressed (probe playbooks in
# UPGRADE_PLAN_221.md's session notes):
#
#   stat solo        changed,failed,stat                     (2.19: changed,stat,failed)
#   command ok solo  changed,failed,msg,rc,stdout,stderr,cmd,start,end,delta,stdout_lines,stderr_lines
#                    (2.19: changed,stdout,stderr,rc,cmd,...,msg,...,failed)
#   command fail     changed,failed,msg,rc,failed_when_result,failed_when_suppressed_exception,
#     (suppressed)   stdout,stderr,cmd,stdout_lines,stderr_lines
#   loop item stat   changed,failed,failed_when_result,ansible_loop_var,item,stat
#   loop item cmd    changed,failed,msg,rc,ansible_loop_var,item,stdout,...,delta,stdout_lines,stderr_lines
#   skipped item     changed,failed,skipped,skip_reason,false_condition,ansible_loop_var,item
#   loop aggregate   changed,failed,msg,results
#
# So the 2.21 partition krikri must reproduce is:
#   1. changed, failed, unreachable, skipped, ansible_facts, exception,
#      finished, msg, rc  - the declared dataclass fields, present ones
#      only, in declaration order (warnings/deprecations deliberately
#      NOT here: a result carrying them renders them after the module's
# own keys, live-verified on a registered debug result).
#   2. the changed_when/failed_when/break_when verdict pairs - result
#      before its suppressed-exception summary.
#   3. loop items only: ansible_loop_var, ansible_index_var, the loop
#      variable itself (named by ansible_loop_var, default item),
#      ansible_loop - the wrapper keys moved ahead of the module payload.
#   4. everything else in its existing relative order - the module's own
#      keys (diff included, wherever the action emitted it), any
#      controller keys not listed above, an injected `invocation`, and
#      the derived *_lines (which the task-result build appends after
#      result_data).
module Krikri
  module ResultShape
    extend self

    private LEAD_KEYS = %w[changed failed unreachable skipped ansible_facts exception finished msg rc]

    # The skip verdict's own body keys: a skipped result carries them
    # right after the declared-field lead (2.21.6: a when:-skipped solo
    # register reads changed,failed,skipped,skip_reason,false_condition;
    # an all-skipped loop item adds ansible_loop_var,item after them),
    # ahead of both the when-verdict keys and the loop wrapper.
    private SKIP_BODY_KEYS = %w[skip_reason skipped_reason false_condition]

    private WHEN_KEYS = %w[changed_when_result
      changed_when_suppressed_exception
      failed_when_result
      failed_when_suppressed_exception
      break_when_result
      break_when_suppressed_exception]

    def normalize!(hash : Hash(String, JSON::Any), loop_item : Bool = false) : Nil
      rebuilt = Hash(String, JSON::Any).new
      LEAD_KEYS.each do |key|
        rebuilt[key] = hash[key] if hash.has_key?(key)
      end
      SKIP_BODY_KEYS.each do |key|
        rebuilt[key] = hash[key] if hash.has_key?(key)
      end
      WHEN_KEYS.each do |key|
        rebuilt[key] = hash[key] if hash.has_key?(key)
      end
      if loop_item
        loop_var = hash["ansible_loop_var"]?.try(&.as_s?) || "item"
        rebuilt["ansible_loop_var"] = hash["ansible_loop_var"] if hash.has_key?("ansible_loop_var")
        rebuilt["ansible_index_var"] = hash["ansible_index_var"] if hash.has_key?("ansible_index_var")
        rebuilt[loop_var] = hash[loop_var] if hash.has_key?(loop_var)
        rebuilt["ansible_loop"] = hash["ansible_loop"] if hash.has_key?("ansible_loop")
      end
      hash.each do |key, value|
        rebuilt[key] = value unless rebuilt.has_key?(key)
      end
      hash.clear
      rebuilt.each do |key, value|
        hash[key] = value
      end
    end

    # A looped register's aggregate: the top-level dict normalizes
    # solo-style (results stays in the tail), and each results[] entry is
    # a loop ITEM - the wrapper keys move ahead of the module payload.
    def normalize_registered!(hash : Hash(String, JSON::Any)) : Nil
      if results = hash["results"]?.try(&.as_a?)
        results.each do |entry|
          if item = entry.as_h?
            backfill_bools!(item)
            normalize!(item, loop_item: true)
          end
        end
      end
      backfill_bools!(hash)
      normalize!(hash)
    end

    # 2.21's export always carries `changed` and `failed` (plain bool
    # properties), while `skipped`/`unreachable` export only when true.
    private def backfill_bools!(hash : Hash(String, JSON::Any)) : Nil
      hash["changed"] = JSON::Any.new(false) unless hash.has_key?("changed")
      hash["failed"] = JSON::Any.new(false) unless hash.has_key?("failed")
    end
  end
end
