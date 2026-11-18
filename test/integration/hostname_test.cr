require "../minitest_helper"

# hostname plugin (ansible.builtin.hostname) integration tests.
#
# Safety: this must never actually change the live system hostname. So:
# - The "no change" case feeds the *current* hostname (read-only).
# - The "would change" case uses check_mode (no hostnamectl/hostname call).
# - We only ever assert against facts derived from the system hostname
#   (System.hostname - the same gethostname call the fact gatherer itself
#   uses) or the static input, never by mutating state the host didn't
#   already have.

describe "hostname plugin" do
  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("hostname", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required arguments: name")
  end

  it "reports no change when name already equals the current hostname (read-only)" do
    current = System.hostname
    result = PluginSpecHelper.run("hostname", {"name" => current})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    # Ansible 2.19.11's success result carries no msg key at all
    # (live-verified registered shape: changed, name, ansible_facts,
    # failed) - the old "hostname is already X" msg was krikri-only.
    result["msg"]?.must_equal(nil)
    result["name"].as_s.must_equal(current)
    # Facts come back at the result top level, matching Ansible.
    result["ansible_facts"]["ansible_hostname"].as_s.must_equal(current)
    result["ansible_facts"]["ansible_nodename"].as_s.must_equal(current)
  end

  it "reports it would change the hostname in check_mode, without touching the live hostname" do
    target = "krikri-playbook-hostname-spec-target"
    before = System.hostname

    result = PluginSpecHelper.run("hostname", {"name" => target, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    # Ansible's check-mode registered shape: changed, name, ansible_facts,
    # diff, failed - no msg (live-verified).
    result["msg"]?.must_equal(nil)
    result["name"].as_s.must_equal(target)
    result["diff"].as_h.keys.must_equal(["before", "after"])
    # Ansible's diff holds two plain strings the diff callback unifies
    # into `-hostname = old` / `+hostname = new`, not a facts map
    # (live-verified vs 2.21.6).
    result["diff"]["after"].as_s.must_equal("hostname = #{target}\n")
    result["diff"]["before"].as_s.starts_with?("hostname = ").must_equal(true)
    result["diff"]["before"].as_s.ends_with?("\n").must_equal(true)
    result["ansible_facts"]["ansible_hostname"].as_s.must_equal(target)
    result["ansible_facts"]["ansible_nodename"].as_s.must_equal(target)
    # Live hostname is untouched in check_mode.
    System.hostname.must_equal(before)
  end

  it "does not touch the live hostname when the name differs but check_mode is off AND it's already set (still read-only)" do
    # Belt-and-braces: re-run the no-change path with check_mode explicitly
    # off to ensure even the non-check path is a no-op when nothing differs.
    current = System.hostname
    result = PluginSpecHelper.run("hostname", {"name" => current, "_ansible_check_mode" => "false"})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    System.hostname.must_equal(current)
  end

  # The kpg harness compares a `--check --diff` run's console bytes across
  # two different containers, and this hunk's before side is the run
  # host's own name: podman gives each engine's container its own default
  # 12-hex hostname, so the two sides describe two different machines and
  # can never agree - two real ansible runs in two containers disagree the
  # same way (kpg issue #1547). Everything around the value is fixed, so a
  # mask can anchor on `hostname = ` plus that value; this pins the shape
  # and that the value is the run host's own hostname, never one derived
  # from the requested `name`.
  it "prints the run host's own hostname as the --diff before value" do
    target = "krikri-playbook-hostname-diff-spec"
    playbook = PluginSpecHelper.tmp_path("hostname_check_diff.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.hostname:
              name: #{target}
      YAML
    engine = File.expand_path("../../bin/krikri-playbook", __DIR__)
    inventory = File.expand_path("../fixtures/inventory-explicit-localhost.ini", __DIR__)

    output = IO::Memory.new
    status = Process.run(engine, ["-i", inventory, "--check", "--diff", playbook], output: output, error: output)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include(
      "--- before\n+++ after\n@@ -1 +1 @@\n" \
      "-hostname = #{System.hostname}\n" \
      "+hostname = #{target}\n"
    )
  end

  # The kpg playbook that surfaced this (issue #1552) delegates the hostname
  # task to a second host with delegate_facts, so the diff's before side must
  # still be the machine that runs the module - the run host's own live name -
  # not the delegated host's inventory name and not one derived from `name`,
  # which is the value the harness mask anchors on. The `[a -> b]` marker on
  # the result line is Ansible's delegation rendering and must survive the
  # diff.
  it "keeps the run host's own hostname on the --diff before side of a delegated task" do
    target = "krikri-playbook-hostname-delegated-spec"
    playbook = PluginSpecHelper.tmp_path("hostname_delegated_check_diff.yml")
    File.write(playbook, <<-YAML)
      - hosts: hostone
        gather_facts: false
        tasks:
          - name: delegated hostname
            ansible.builtin.hostname:
              name: #{target}
            register: delegated_hostname
            ignore_errors: true
            delegate_to: hosttwo
            delegate_facts: true
      YAML
    engine = File.expand_path("../../bin/krikri-playbook", __DIR__)
    inventory = File.expand_path("../fixtures/inventory-two-local-hosts.ini", __DIR__)

    output = IO::Memory.new
    status = Process.run(engine, ["-i", inventory, "--check", "--diff", playbook], output: output, error: output)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include(
      "--- before\n+++ after\n@@ -1 +1 @@\n" \
      "-hostname = #{System.hostname}\n" \
      "+hostname = #{target}\n"
    )
    output.to_s.must_include("changed: [hostone -> hosttwo]")
  end
end
