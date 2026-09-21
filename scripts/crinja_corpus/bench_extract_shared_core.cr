# Phase-3 slice 4 (extract) cost check: the shared FilterCore.extract core
# keeps the hand-rolled path conversion-free, but the Crinja registration
# now converts its container host-scoped per call. This bench renders the
# canonical real-world shape - `hosts | map('extract', hostvars, 'node_ip')`
# over an 8-host inventory with 41 vars each - N times through the Crinja
# renderer and reports ns/call. Run on the pre-change tree (throwaway
# worktree) and the new tree, same N.
#   crystal run --release scripts/crinja_corpus/bench_extract_shared_core.cr
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

HOSTS =      8
N     = 20_000

v = Hash(String, JSON::Any).new
hostvars = Hash(String, JSON::Any).new
HOSTS.times do |i|
  hv = Hash(String, JSON::Any).new
  40.times { |j| hv["var_#{j}"] = JSON::Any.new("value-#{i}-#{j}") }
  hv["node_ip"] = JSON::Any.new("10.0.0.#{i}")
  hostvars["host-#{i}"] = JSON::Any.new(hv)
end
v["hostvars"] = JSON::Any.new(hostvars)
v["hosts_list"] = JSON::Any.new((0...HOSTS).map { |i| JSON::Any.new("host-#{i}") })

renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(v)
tpl = %({{ hosts_list | map('extract', hostvars, 'node_ip') | list }})

# warmup
100.times { renderer.render(tpl) }

best = Int64::MAX
3.times do
  start = Time.instant
  N.times { renderer.render(tpl) }
  elapsed = (Time.instant - start).total_nanoseconds.to_i64 // N
  best = Math.min(best, elapsed)
end
puts "8 hosts x 41 vars, map('extract') over all hosts: #{best} ns/call (best of 3, N=#{N})"
