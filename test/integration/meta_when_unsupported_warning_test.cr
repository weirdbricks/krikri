require "../minitest_helper"

# ansible-core's strategy raises `_cond_not_supported_warn` from
# _execute_meta for the meta actions that IGNORE a `when:` completely
# (noop / refresh_inventory / reset_connection): a
# `[WARNING]: <action> task does not support when conditional` line,
# printed BEFORE anything is decided, so it appears whether the
# conditional is true, false, or inherited from a false block - and once
# per run, because Display dedupes the formatted line. Every expectation
# below is live-verified against ansible-core 2.21.6 (issue #1003: a
# generator playbook whose `meta: noop` carried a when-false registered
# check printed the warning in real and nothing in krikri).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private NOOP_WARNING = "[WARNING]: noop task does not support when conditional"

# Runs *tasks* (already indented for the play's task list) and returns the
# merged stdout+stderr plus the exit status. The warning goes to stderr and
# the `skipping:` lines to stdout, so both streams land in one buffer - the
# same way a user's terminal shows them.
private def run_meta_play(tasks : Array(String)) : {Bool, String}
  playbook = File.tempname("meta-when-unsupported", ".yml")
  body = [
    "- hosts: localhost",
    "  connection: local",
    "  gather_facts: false",
    "  tasks:",
  ] of String
  body.concat(tasks)
  File.write(playbook, body.join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "a meta action that rejects when: conditionals" do
  it "warns for a when-false noop, and once per run even with a second such task" do
    success, text = run_meta_play([
      "  - name: noop with a false when",
      "    ansible.builtin.meta: noop",
      "    when: false",
      "  - name: noop with a true when",
      "    ansible.builtin.meta: noop",
      "    when: true",
      "  - name: after the noops",
      "    ansible.builtin.debug:",
      "      msg: reached after the noops",
    ])

    success.must_equal(true)
    text.scan(NOOP_WARNING).size.must_equal(1)
    # Real never evaluates the conditional for these actions, so a
    # when-false one prints no skipping line either.
    text.wont_include("skipping:")
    text.must_include("reached after the noops")
  end

  it "warns for refresh_inventory and reset_connection, but not for actions that support a when" do
    success, text = run_meta_play([
      "  - name: refresh with a when",
      "    ansible.builtin.meta: refresh_inventory",
      "    when: true",
      "  - name: reset with a when",
      "    ansible.builtin.meta: reset_connection",
      "    when: true",
      "  - name: flush with a false when",
      "    ansible.builtin.meta: flush_handlers",
      "    when: false",
      "  - name: clear facts with a false when",
      "    ansible.builtin.meta: clear_facts",
      "    when: false",
    ])

    success.must_equal(true)
    text.must_include("[WARNING]: refresh_inventory task does not support when conditional")
    text.must_include("[WARNING]: reset_connection task does not support when conditional")
    text.wont_include("[WARNING]: flush_handlers task does not support when conditional")
    text.wont_include("[WARNING]: clear_facts task does not support when conditional")
    # Those two DO evaluate their when:, so they skip visibly.
    text.must_include("skipping: [localhost]")
  end

  it "warns for a noop under a when-false block, whose condition the block hands down" do
    success, text = run_meta_play([
      "  - block:",
      "    - name: noop inside a false block",
      "      ansible.builtin.meta: noop",
      "    when: false",
      "  - name: after the block",
      "    ansible.builtin.debug:",
      "      msg: reached after the block",
    ])

    success.must_equal(true)
    text.must_include(NOOP_WARNING)
    text.wont_include("skipping:")
    text.must_include("reached after the block")
  end

  it "warns for a when-false block's meta children even when their own when: is an empty list" do
    success, text = run_meta_play([
      "  - block:",
      "    - name: noop with an empty own when inside a false block",
      "      ansible.builtin.meta: noop",
      "      when: []",
      "    - name: refresh with no own when inside a false block",
      "      ansible.builtin.meta: refresh_inventory",
      "    when: false",
      "  - name: after the block",
      "    ansible.builtin.debug:",
      "      msg: reached after the block",
    ])

    # Real extends the child's `when` with the block's clause and then tests
    # THAT list for truthiness, so a child whose own `when: []` contributes
    # nothing still has the block's entry and warns (live-verified vs
    # ansible-core 2.21.6) - the child's own clause must not shadow it.
    success.must_equal(true)
    text.must_include(NOOP_WARNING)
    text.must_include("[WARNING]: refresh_inventory task does not support when conditional")
    text.wont_include("skipping:")
    text.must_include("reached after the block")
  end

  it "stays silent when the only when: anywhere is an empty list" do
    success, text = run_meta_play([
      "  - block:",
      "    - name: ungated noop inside a block with no when",
      "      ansible.builtin.meta: noop",
      "    - name: noop whose own when is an empty list",
      "      ansible.builtin.meta: noop",
      "      when: []",
      "  - name: after the block",
      "    ansible.builtin.debug:",
      "      msg: reached after the block",
    ])

    success.must_equal(true)
    text.wont_include(NOOP_WARNING)
    text.must_include("reached after the block")
  end
end
