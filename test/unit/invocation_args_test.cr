require "../minitest_helper"
require "../../src/krikri/argspec_validator"

describe Krikri::ArgspecValidator do
  it "builds invocation.module_args with spec defaults for command" do
    args = Krikri::ArgspecValidator.invocation_args("ansible.builtin.command", {"cmd" => "echo a"}).not_nil!
    args["cmd"].as_s.must_equal("echo a")
    args["argv"].raw.must_be_nil
    args["_uses_shell"].as_bool.must_equal(false)
    args["expand_argument_vars"].as_bool.must_equal(true)
  end

  it "has no invocation for an unknown module" do
    Krikri::ArgspecValidator.invocation_args("ansible.builtin.nope", {} of String => String).must_be_nil
  end
end
