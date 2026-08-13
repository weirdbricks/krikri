# Step 1c of CRINJA.md's differential-test-harness plan.
#
# Renders every corpus.jsonl entry through raw Crinja directly (Crinja.new /
# env.from_string(...).render - bypassing this codebase's own CrinjaRenderer
# wrapper, per CRINJA.md's own recommendation), with all of this codebase's
# crinja_*_ext.cr monkey-patches loaded (so already-fixed bugs don't show up
# as noise) but WITHOUT CrinjaRenderer's text-level trim-marker workaround
# (so bug #1's underlying lexer gap still shows, honestly, as a raw-engine
# divergence).
#
# No context variables are bound - same as oracle_python.py - so results
# are driven by syntax/literal semantics, not guessed Ansible fact values.
#
# Run from the repo root with: crystal run scripts/crinja_corpus/oracle_crinja.cr
# Writes scripts/crinja_corpus/oracle_crinja.jsonl, one line per corpus
# entry, same order.

require "json"
require "crinja"
require "../../src/crystal_play/crinja_hash_ext"
require "../../src/crystal_play/crinja_bool_ext"
require "../../src/crystal_play/crinja_truthy_ext"
require "../../src/crystal_play/crinja_string_ext"
require "../../src/crystal_play/crinja_trim_blocks_ext"
require "../../src/crystal_play/crinja_ternary_expr_ext"
require "../../src/crystal_play/crinja_logic_ext"
require "../../src/crystal_play/crinja_in_operator_ext"
require "../../src/crystal_play/crinja_undefined_filter_ext"

def shared_env : Crinja
  env = Crinja.new
  env.config.trim_blocks = true
  env.config.lstrip_blocks = false
  env
end

env = shared_env

in_path = File.join(__DIR__, "corpus.jsonl")
out_path = File.join(__DIR__, "oracle_crinja.jsonl")

count = 0
File.open(out_path, "w") do |outf|
  File.each_line(in_path) do |line|
    next if line.strip.empty?
    entry = JSON.parse(line)
    kind = entry["kind"].as_s
    expr = entry["expr"].as_s

    src = case kind
          when "output"
            "{{ " + expr + " }}"
          when "condition"
            "{% if " + expr + " %}TRUE{% else %}FALSE{% endif %}"
          else
            raise "unknown kind #{kind}"
          end

    row = {} of String => JSON::Any
    begin
      rendered = env.from_string(src).render
      row["ok"] = JSON::Any.new(true)
      row["output"] = JSON::Any.new(rendered)
    rescue e : Exception
      row["ok"] = JSON::Any.new(false)
      row["error_type"] = JSON::Any.new(e.class.name)
      row["error"] = JSON::Any.new(e.message.to_s)
    end
    row["kind"] = JSON::Any.new(kind)
    row["expr"] = JSON::Any.new(expr)

    outf.puts(row.to_json)
    count += 1
  end
end

STDERR.puts "rendered #{count} entries -> #{out_path}"
