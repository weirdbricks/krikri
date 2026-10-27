require "../minitest_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/conditional_evaluator"

# Issue #632 (sscheib.openwrt_extroot): the role's vars/main.yml defines
# `_ext_usb_device: '{{ ext_usb_device | mandatory }}'` with
# ext_usb_device unset, and its assert task reads it through
# `lookup('ansible.builtin.vars', _ext_usb_device)` inside the strict
# success_msg finalization. ansible-core 2.19 reports the mandatory
# FILTER PLUGIN wording for that nested read
# ("The filter plugin 'ansible.builtin.mandatory' failed: Mandatory
# variable 'usb' not defined." - live-verified), the same wording the
# direct `{{ usb | mandatory }}` span already produced here; krikri
# reported the plain "'usb' is undefined" instead, because the strict
# probe over the nested value's own template settled for the strict
# engine's undefined message - the lenient structured evaluation demoted
# the undefined source to JSON null before the mandatory filter could be
# blamed.
describe "nested mandatory-chain var read through the vars lookup" do
  include RaisesAssertion

  it "raises the mandatory filter-plugin wording for a strict nested read" do
    vars = {"_x" => JSON::Any.new("{{ x | mandatory }}")}
    sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
    assert_raises_message(
      Krikri::FilterPluginError,
      "The filter plugin 'ansible.builtin.mandatory' failed: Mandatory variable 'x' not defined.",
    ) do
      sub.substitute("[{{ lookup('ansible.builtin.vars', '_x') }}]", strict: true)
    end
  end

  it "keeps the plain undefined wording when the nested chain's first filter is not mandatory" do
    vars = {"_x" => JSON::Any.new("{{ x | lower }}")}
    sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
    assert_raises_message(Krikri::UndefinedVariableError, /'x' is undefined/) do
      sub.substitute("[{{ lookup('ansible.builtin.vars', '_x') }}]", strict: true)
    end
  end

  it "raises the mandatory wording for a two-level nested read through a ternary" do
    # Mirrors the role's _ext_usb_device_part: the outer value only reaches
    # the mandatory chain through its ternary's else branch, and ansible
    # still fails the item with the mandatory message.
    vars = {
      "_x" => JSON::Any.new("{{ x | mandatory }}"),
      "_y" => JSON::Any.new("{{ (q is defined) | ternary(q | default(''), _x ~ 1) }}"),
    }
    sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
    assert_raises_message(
      Krikri::FilterPluginError,
      "The filter plugin 'ansible.builtin.mandatory' failed: Mandatory variable 'x' not defined.",
    ) do
      sub.substitute("[{{ lookup('ansible.builtin.vars', '_y') }}]", strict: true)
    end
  end

  it "keeps the plain undefined wording for a nested chain with an undefined-tolerant first filter" do
    vars = {"_x" => JSON::Any.new("{{ x | default('fb') }}")}
    sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
    sub.substitute("[{{ lookup('ansible.builtin.vars', '_x') }}]", strict: true)
      .must_equal("[fb]")
  end
end
