require "../minitest_helper"
require "../../src/krikri/argspec_validator"
require "../../src/krikri/variable_substitutor"

describe Krikri::ArgspecValidator do
  it "builds invocation.module_args with spec defaults for command" do
    args = Krikri::ArgspecValidator.invocation_args("ansible.builtin.command", {"cmd" => "echo a"}).as(Hash(String, JSON::Any))
    args["cmd"].as_s.must_equal("echo a")
    args["argv"].raw.must_be_nil
    args["_uses_shell"].as_bool.must_equal(false)
    args["expand_argument_vars"].as_bool.must_equal(true)
  end

  it "has no invocation for an unknown module" do
    Krikri::ArgspecValidator.invocation_args("ansible.builtin.nope", {} of String => String).must_be_nil
  end
end

describe "mustache scanning with escaped quotes" do
  it "does not end a string literal at a backslash-escaped quote" do
    r = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")
    r.substitute("{{ 'q\\'uote' }} x").must_equal("q\\'uote x")
  end
end
