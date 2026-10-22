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

  it "reports find's patterns default as [\"*\"] in invocation.module_args" do
    args = Krikri::ArgspecValidator.invocation_args("ansible.builtin.find", {"paths" => "/tmp"}).as(Hash(String, JSON::Any))
    args["patterns"].as_a.map(&.as_s).must_equal(["*"])
  end

  it "orders find's invocation.module_args supplied args first, then defaults" do
    args = Krikri::ArgspecValidator.invocation_args("ansible.builtin.find", {"recurse" => "true", "paths" => "/tmp/x", "hidden" => "false", "age" => "1d"}).as(Hash(String, JSON::Any))
    args.keys.must_equal(%w[age hidden paths recurse patterns read_whole_file file_type age_stamp follow get_checksum checksum_algorithm use_regex exact_mode excludes contains size depth mode encoding limit])
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
