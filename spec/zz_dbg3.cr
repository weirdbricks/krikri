require "./spec_helper"
require "../src/krikri/variable_substitutor/crinja_renderer"
require "../src/krikri/jinja_filters"
v = Hash(String, JSON::Any).new
v["hostvars"] = JSON.parse(%({"host-a": {"node_ip": "10.0.0.1"}}))
renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(v)
p renderer.render(%({{ "host-a" | extract(hostvars, "node_ip") }}))
