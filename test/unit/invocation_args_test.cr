require "../minitest_helper"
require "../../src/krikri/argspec_validator"
require "../../src/krikri/variable_substitutor"

describe Krikri::ArgspecValidator do
  serial!
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

  it "builds get_url's invocation.module_args with supplied args sorted, then defaults" do
    args = Krikri::ArgspecValidator.invocation_args("ansible.builtin.get_url", {"url" => "http://x/y", "dest" => "/tmp", "timeout" => "20"}).as(Hash(String, JSON::Any))
    args.keys.first(3).must_equal(%w[dest timeout url])
    args["timeout"].as_i.must_equal(20)
    args["force"].as_bool.must_equal(false)
  end

  it "keeps the caller's alias spelling next to the canonical key (file dest: -> dest and path)" do
    args = Krikri::ArgspecValidator.invocation_args("ansible.builtin.file", {"dest" => "/tmp/l", "src" => "/etc/hostname", "state" => "link"}).as(Hash(String, JSON::Any))
    args["dest"].as_s.must_equal("/tmp/l")
    args["path"].as_s.must_equal("/tmp/l")
    args.keys.first(4).must_equal(%w[dest path src state])
  end

  it "echoes get_selinux_context as a spec default in stat's invocation.module_args" do
    # ansible-core 2.21 (krikri's parity target) restored get_selinux_context
    # to stat's argspec (issue #910), so its default is echoed like the
    # other stat defaults.
    args = Krikri::ArgspecValidator.invocation_args("ansible.builtin.stat", {"path" => "/etc/hosts"}).as(Hash(String, JSON::Any))
    args.has_key?("path").must_equal(true)
    args["get_selinux_context"].as_bool.must_equal(false)
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
