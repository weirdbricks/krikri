require "../minitest_helper"

# Inventory-level `ansible_become`/`ansible_become_user` vars must reach
# plugin dispatch exactly like ansible-core's own become resolution:
# TaskExecutor._set_become_plugin reads `ansible_become` out of the
# task's cvars (inventory included) and it OVERRIDES the become keyword
# ladder, and the sudo become plugin's `become_user` option resolves
# vars before keywords (config-manager origin order: direct > vars >
# keyword). krikri used to derive become only from the parsed
# become:/become_user: keywords, so an inventory `ansible_become: true`
# was silently ignored and a `file: state: touch` ran unprivileged
# (issue #3: the touched file came out owned by the login user).
#
# The discriminator avoids depending on the controller having
# passwordless sudo: a become_user that doesn't exist fails sudo
# everywhere (unknown user or password required), while the same task
# without escalation succeeds - so "var on -> the run fails" and
# "var off -> the run succeeds" hold on any controller, regardless of
# its sudoers policy.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private NO_SUCH_USER = "krikri-no-such-user-#{Random::Secure.hex(4)}"

private def run_become_play(inventory_vars : String, tasks : Array(String)) : {Bool, String}
  inventory = PluginSpecHelper.tmp_path("become-var-inv-#{Random::Secure.hex(4)}.ini")
  File.write(inventory, "localhost ansible_connection=local #{inventory_vars}\n")
  playbook = PluginSpecHelper.tmp_path("become-var-#{Random::Secure.hex(4)}.yml")
  File.write(playbook, [
    "- hosts: localhost",
    "  gather_facts: false",
    "  connection: local",
    "  tasks:",
  ].concat(tasks).join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(inventory) if inventory && File.exists?(inventory)
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "inventory ansible_become var" do
  it "escalates a become-keyword-less task (unknown become_user proves the sudo attempt)" do
    path = PluginSpecHelper.tmp_path("become-var-touch")
    `rm -rf #{path}`

    success, output = run_become_play(
      "ansible_become=true ansible_become_user=#{NO_SUCH_USER}",
      [
        "    - name: touch",
        "      ansible.builtin.file: {path: #{path}, state: touch}",
      ]
    )

    success.must_equal(false, output)
    File.exists?(path).must_equal(false, "file must not be created when the escalation target cannot run")
    output.includes?("fatal: [localhost]").must_equal(true, output)
  end

  it "outranks an explicit become: true keyword when the var says false" do
    path = PluginSpecHelper.tmp_path("become-var-false-touch")
    `rm -rf #{path}`

    success, output = run_become_play(
      "ansible_become=false",
      [
        "    - name: touch",
        "      ansible.builtin.file: {path: #{path}, state: touch}",
        "      become: true",
        "      become_user: #{NO_SUCH_USER}",
      ]
    )

    success.must_equal(true, output)
    File.exists?(path).must_equal(true, output)
  end

  it "leaves a task unprivileged when the var is absent (control)" do
    path = PluginSpecHelper.tmp_path("become-var-control-touch")
    `rm -rf #{path}`

    success, output = run_become_play(
      "",
      [
        "    - name: touch",
        "      ansible.builtin.file: {path: #{path}, state: touch}",
      ]
    )

    success.must_equal(true, output)
    File.exists?(path).must_equal(true, output)
  end
end
