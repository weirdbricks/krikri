require "../minitest_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Ansible's debug action plugin validates its own three options through the
# shared ArgumentSpecValidator BEFORE it does anything else
# and Ansible reports only errors[0] out of
# mutually_exclusive -> types in declaration order (msg, var, verbosity) ->
# unsupported parameters LAST (live-verified vs 2.19.11). This engine
# used to run no check at all for a non-integer verbosity: it accepted
# the value silently, or crashed the whole process on the value
# (Invalid Int32), and reported the typo'd key first when there was one.
describe "debug: argument-spec validation order" do
  it "fails a wrong-typed verbosity with Ansible's own message, ahead of a typo'd key" do
    playbook = File.tempname("debug-verbosity-type", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: wrong-typed verbosity plus a typo'd key
            ansible.builtin.debug:
              msg: "gddznp"
              verbosity: epdfma
              msg_bogus: gddznp
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    out = output.to_s
    out.must_include(
      "argument 'verbosity' is of type str and we were unable to convert to int: " \
      "\"'epdfma'\" cannot be converted to an int")
    # The unsupported-parameter error is Ansible's LAST one, so it must not
    # be the message this task fails with.
    out.wont_include("Unsupported parameters")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: bool verbosity skips like
            ansible.builtin.debug:
              msg: "should not print at default verbosity"
              verbosity: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("skipping:")
    output.to_s.must_include("skipped=1")
    output.to_s.wont_include("should not print at default verbosity")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
