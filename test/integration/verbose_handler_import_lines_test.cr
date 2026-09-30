require "../minitest_helper"

# Regression tests for the -vv console lines real ansible-playbook emits
# around handlers and static imports: the strategy's "Notification for
# handler ... has been saved.", the default callback's "NOTIFIED HANDLER
# ... for ..." and the handler's own `task path:` line, plus the parser's
# "statically imported: <path>" line. All captured from real
# ansible-core 2.19.11 runs (ANSIBLE_NOCOLOR=1).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_vv(yaml : String) : {Process::Status, String, String}
  playbook = File.tempname("vv-handler-import", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "-vv", playbook], output: output, error: output)
  {status, output.to_s, playbook}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "-vv handler and static-import console lines" do
  it "prints the notification-saved, NOTIFIED HANDLER and handler task path lines" do
    status, output, playbook_path = run_playbook_vv(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            changed_when: true
            notify: my handler
        handlers:
          - name: my handler
            ansible.builtin.debug:
              msg: ran
      YAML

    status.success?.must_equal(true)
    output.must_include("Notification for handler my handler has been saved.")
    output.must_include("NOTIFIED HANDLER my handler for localhost")
    # The handler's own `task path:` follows its RUNNING HANDLER banner,
    # pointing at the handlers: entry's source line (10 in the playbook).
    output.must_match(/RUNNING HANDLER \[my handler\].*\ntask path: #{Regex.escape(playbook_path)}:10/)
  end

  it "does not print the notification-saved line for a handler notifying another handler" do
    status, output, _playbook_path = run_playbook_vv(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            changed_when: true
            notify: first
        handlers:
          - name: first
            ansible.builtin.debug:
              msg: one
            notify: second
          - name: second
            ansible.builtin.debug:
              msg: two
      YAML

    status.success?.must_equal(true)
    output.must_include("Notification for handler first has been saved.")
    output.includes?("Notification for handler second has been saved.").must_equal(false)
    # Real (verified 2.19.11) neither runs "second" nor prints its
    # NOTIFIED HANDLER line when it is notified by a handler during the
    # flush - krikri's own two-pass scheduling agrees.
    output.includes?("NOTIFIED HANDLER second for localhost").must_equal(false)
    output.includes?("RUNNING HANDLER [second]").must_equal(false)
  end

  it "prints one statically imported line per import_tasks file, before the Skipping callback lines" do
    dir = PluginSpecHelper.tmp_path("vv-static-import")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inner.yml"), "- name: inner\n  ansible.builtin.debug:\n    msg: inner\n")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: outer import
            ansible.builtin.import_tasks: inner.yml
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "-vv", playbook], output: output, error: output)
    status.success?.must_equal(true)

    text = output.to_s
    text.must_include("statically imported: #{File.join(dir, "inner.yml")}")
    # Real prints it after the config-file line and before the two
    # Skipping callback lines.
    cfg_idx = text.index("No config file found; using defaults")
    import_idx = text.index("statically imported: ")
    skip_idx = text.index("Skipping callback 'minimal'")
    ordered = false
    if cfg_idx && import_idx && skip_idx
      ordered = cfg_idx < import_idx && import_idx < skip_idx
    end
    ordered.must_equal(true)
  end
end
