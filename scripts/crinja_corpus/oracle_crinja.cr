# Step 1c of CRINJA.md's differential-test-harness plan.
#
# Renders every corpus.jsonl entry through raw Crinja directly (Crinja.new /
# env.from_string(...).render - bypassing this codebase's own CrinjaRenderer
# wrapper, per CRINJA.md's own recommendation), with the FULL real-runtime
# require chain loaded (`jinja_filters.cr`, which transitively requires
# every `crinja_*_ext.cr` patch AND registers every Ansible-specific
# filter/test this codebase adds - `ternary`, `regex_replace`, `match`,
# `boolean`, etc.) but WITHOUT CrinjaRenderer's text-level trim-marker
# workaround (so bug #1's underlying lexer gap still shows, honestly, as a
# raw-engine divergence).
#
# Originally required each `crinja_*_ext.cr` file individually rather than
# `jinja_filters.cr` itself, deliberately scoping the harness to "core
# Crinja" and treating Ansible-specific additions as expected mutual gaps
# (see this directory's own README on bucket E's "expected noise").
# Switched to `jinja_filters.cr` directly (2026-08-13) after repeatedly
# forgetting to add a new ext file to this list separately from the real
# require chains (`src/krikri/jinja_filters.cr`/`variable_
# substitutor/crinja_renderer.cr`), AND after several filters/tests added
# directly in `jinja_filters.cr` itself (`match`/`search`/`ne`/`truthy`/
# `boolean`/`integer`/`float`) kept showing as "missing" here even after
# being verified fixed, purely because this file's require list didn't
# reach them. Requiring the real production entry point directly
# eliminates both problems at once - one require list to keep in sync,
# not two - at the cost of also making some Ansible-specific gaps (real
# Python jinja2 has no `ternary`/`regex_replace`/etc.) resolve to bucket D
# ("python fails, crinja succeeds") instead of bucket E, which is
# correct, not noise: Crinja does very legitimately have a real advantage
# there now.
#
# No context variables are bound - same as oracle_python.py - so results
# are driven by syntax/literal semantics, not guessed Ansible fact values.
#
# Run from the repo root with: crystal run scripts/crinja_corpus/oracle_crinja.cr
# Writes scripts/crinja_corpus/oracle_crinja.jsonl, one line per corpus
# entry, same order.

require "json"
require "../../src/krikri/jinja_filters"

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
          when "for_block"
            expr
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
