require "../minitest_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Ansible's gather_facts ACTION plugin pops its own `parallel` option and
# hands every other task arg to the ansible.legacy.setup module it runs, so
# a key setup's argument spec does not know fails INSIDE that module and
# comes back as the action's "The following modules failed to execute:
# ansible.legacy.setup." wrapper with the module's failure under
# failed_modules. krikri's gather_facts plugin used to ignore unknown keys
# and report the task ok (issue #933).
#
# Every expected shape below was captured from an ansible-playbook 2.21.6
# run of the same task on a local connection (see the issue's playbook).
describe "Krikri::FactsGatherer unknown-parameter failures (facts_gather_param_validation_test.cr)" do
  # `_first_gather` off keeps interpreter discovery - and the
  # environment-dependent warning and discovered-interpreter fact it
  # stamps - out of these payloads; the failure shape itself is identical
  # either way.
  private def config(params = {} of String => JSON::Any,
                     module_name : String = "ansible.builtin.gather_facts",
                     async : Bool = false,
                     first_gather : Bool = false) : JSON::Any
    values = {} of String => JSON::Any
    values["_first_gather"] = JSON::Any.new(first_gather.to_s)
    values["_module_name"] = JSON::Any.new(module_name)
    values["_ansible_gather_async"] = JSON::Any.new("true") if async
    params.each { |key, value| values[key] = value }
    JSON.parse({
      "host"   => {"name" => "testhost", "user" => "root", "port" => 22},
      "vars"   => {} of String => JSON::Any,
      "params" => values,
    }.to_json)
  end

  private def flag(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  it "wraps a rejected gather_facts task arg the way the action plugin does" do
    result = JSON.parse(Krikri::FactsGatherer.run(config({"parallel_bogus" => flag("true")})))

    message = "Unsupported parameters for (ansible.legacy.setup) module: parallel_bogus. " \
              "Supported parameters include: fact_path, filter, gather_subset, gather_timeout."
    result["msg"].as_s.must_equal("The following modules failed to execute: ansible.legacy.setup.")
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["ansible_facts"].as_h.must_be_empty

    failed = result["failed_modules"].as_h["ansible.legacy.setup"].as_h
    failed["msg"].as_s.must_equal(message)
    failed["failed"].as_bool.must_equal(true)
    failed["changed"].as_bool.must_equal(false)
    failed["exception"].as_s.must_equal("(traceback unavailable)")
    failed["deprecations"].as_a.must_be_empty
    failed["warnings"].as_a.must_be_empty
    # The serial form of the failure runs no async job, so real's module
    # result carries neither the job id nor the async-status `finished`.
    failed.has_key?("ansible_job_id").must_equal(false)
    failed.has_key?("finished").must_equal(false)
  end

  it "adds the async job id and finished flag for a parallel: gather" do
    result = JSON.parse(Krikri::FactsGatherer.run(config({"parallel_bogus" => flag("true")}, async: true)))

    failed = result["failed_modules"].as_h["ansible.legacy.setup"].as_h
    # Real's jid is "j<random digits>.<pid>" (the action plugin's
    # secrets.randbelow plus async_wrapper's pid), so only the shape can be
    # asserted.
    failed["ansible_job_id"].as_s.must_match(/\Aj\d+\.\d+\z/)
    failed["finished"].as_bool.must_equal(true)
  end

  it "fails a direct setup: task with the invoked name and no wrapper" do
    result = JSON.parse(Krikri::FactsGatherer.run(
      config({"bogus" => flag("true")}, module_name: "ansible.builtin.setup")))

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (ansible.builtin.setup) module: bogus. " \
      "Supported parameters include: fact_path, filter, gather_subset, gather_timeout.")
    result.as_h.has_key?("failed_modules").must_equal(false)
  end

  it "stamps the interpreter a direct setup task discovered when it fails" do
    first = JSON.parse(Krikri::FactsGatherer.run(
      config({"bogus" => flag("true")}, module_name: "ansible.builtin.setup", first_gather: true)))

    first["failed"].as_bool.must_equal(true)
    first["changed"].as_bool.must_equal(false)
    first["ansible_facts"].as_h.keys.must_equal(["discovered_interpreter_python"])
    first["ansible_facts"].as_h["discovered_interpreter_python"].as_s.wont_be_empty
    first.as_h.has_key?("failed_modules").must_equal(false)
    # The module's own fail_json payload carries no
    # deprecations/warnings/exception keys - those belong to the async_status
    # copy the action wrapper reports for a failed parallel gather.
    first.as_h.has_key?("warnings").must_equal(false)

    # A later setup: task never runs discovery (real caches the discovered
    # interpreter in the host's facts), so its failure carries no stamp.
    later = JSON.parse(Krikri::FactsGatherer.run(
      config({"bogus" => flag("true")}, module_name: "ansible.builtin.setup")))
    later["failed"].as_bool.must_equal(true)
    later.as_h.has_key?("ansible_facts").must_equal(false)
  end

  it "sorts several unknown parameters like Ansible's UnsupportedError" do
    result = JSON.parse(Krikri::FactsGatherer.run(
      config({"zeta" => flag("true"), "alpha" => flag("true")})))

    result["failed_modules"].as_h["ansible.legacy.setup"].as_h["msg"].as_s.must_equal(
      "Unsupported parameters for (ansible.legacy.setup) module: alpha, zeta. " \
      "Supported parameters include: fact_path, filter, gather_subset, gather_timeout.")
  end

  it "never fails on parallel itself - the action consumes it" do
    result = JSON.parse(Krikri::FactsGatherer.run(config({"parallel" => flag("true")}, async: true)))

    expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
    result["ansible_facts"].as_h.wont_be_empty
  end

  it "never fails on a null-valued unknown parameter - the action strips Nones" do
    result = JSON.parse(Krikri::FactsGatherer.run(config({"parallel_bogus" => JSON::Any.new(nil)})))

    expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
    result["ansible_facts"].as_h.wont_be_empty
  end
end
