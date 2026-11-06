require "../minitest_helper"
require "../../src/krikri/invocation_injection"

# The process-wide ENV reads make these serial (see minitest_helper's
# parallel-safety rules): ANSIBLE_INJECT_INVOCATION is consulted on every
# resolution, so a concurrent test's env pinning would race the reads.
describe Krikri::InvocationInjection do
  serial!

  it "defaults to false with no env and no var" do
    Krikri::InvocationInjection.enabled?.must_equal(false)
  end

  it "honors the ANSIBLE_INJECT_INVOCATION env tier with Ansible's boolean spellings" do
    begin
      ENV["ANSIBLE_INJECT_INVOCATION"] = "1"
      Krikri::InvocationInjection.enabled?.must_equal(true)
      ENV["ANSIBLE_INJECT_INVOCATION"] = "false"
      Krikri::InvocationInjection.enabled?.must_equal(false)
      ENV["ANSIBLE_INJECT_INVOCATION"] = "yes"
      Krikri::InvocationInjection.enabled?.must_equal(true)
      ENV["ANSIBLE_INJECT_INVOCATION"] = "bogus"
      Krikri::InvocationInjection.enabled?.must_equal(false)
    ensure
      ENV.delete("ANSIBLE_INJECT_INVOCATION")
    end
  end

  it "lets the ansible_inject_invocation var override the env tier" do
    begin
      ENV["ANSIBLE_INJECT_INVOCATION"] = "0"
      vars = {"ansible_inject_invocation" => JSON::Any.new("true")}
      Krikri::InvocationInjection.enabled?(vars).must_equal(true)
      off = {"ansible_inject_invocation" => JSON::Any.new("no")}
      Krikri::InvocationInjection.enabled?(off).must_equal(false)
      native = {"ansible_inject_invocation" => JSON::Any.new(true)}
      Krikri::InvocationInjection.enabled?(native).must_equal(true)
    ensure
      ENV.delete("ANSIBLE_INJECT_INVOCATION")
    end
  end

  it "strips a top-level invocation key and leaves the rest of the shape alone" do
    result = JSON.parse(%({"changed": false, "stat": {"exists": true}, "invocation": {"module_args": {"path": "/x"}}, "failed": false}))
    stripped = Krikri::InvocationInjection.strip(result)
    stripped.as_h.has_key?("invocation").must_equal(false)
    stripped.as_h["stat"]["exists"].as_bool.must_equal(true)
    stripped.as_h.keys.must_equal(%w[changed stat failed])
  end

  it "passes a result without invocation through unchanged" do
    result = JSON.parse(%({"changed": false, "msg": "hi"}))
    Krikri::InvocationInjection.strip(result).must_equal(result)
    Krikri::InvocationInjection.strip(JSON::Any.new("plain")).must_equal(JSON::Any.new("plain"))
  end
end
