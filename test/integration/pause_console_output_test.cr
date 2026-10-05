require "../minitest_helper"

# Ansible's pause action plugin writes "Pausing for N seconds" (and, when a
# prompt was given too, the ctrl+C hint) to the console ITSELF while the
# task is running - Display.display(), before the sleep, and therefore
# always between the task banner and that item's own status line. This
# drives the compiled binary to pin that placement, including the one
# place it is easy to get wrong: a LOOPED pause, where the engine defers
# every item's display to the end of the loop, so a plugin that wrote the
# line directly would print every item's banner ahead of the very first
# item's "ok:".
private BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)

private def run_pause_playbook(yaml : String) : String
  playbook = PluginSpecHelper.tmp_path("pause-console.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", "localhost,", "-c", "local", playbook], output: output, error: output)
  output.to_s
end

describe "pause console output" do
  it "announces the wait between the task banner and the status line" do
    output = run_pause_playbook(<<-YAML)
      ---
      - name: pause console
        hosts: all
        gather_facts: false
        tasks:
          - name: wait a moment
            ansible.builtin.pause:
              prompt: kpg pause
              seconds: "1"
      YAML

    lines = output.lines.map(&.chomp)
    banner = lines.index { |line| line.starts_with?("TASK [wait a moment]") }
    pausing = lines.index { |line| line == "Pausing for 1 seconds" }
    hint = lines.index { |line| line == "(ctrl+C then 'C' = continue early, ctrl+C then 'A' = abort)" }
    ok = lines.index { |line| line == "ok: [localhost]" }

    # Ansible writes the hint as display(msg + "\r"), so the CR is part of
    # the line it emits (and chomp above strips it off for comparison).
    output.must_include("(ctrl+C then 'C' = continue early, ctrl+C then 'A' = abort)\r\n")
    (banner.not_nil! < pausing.not_nil!).must_equal(true)
    (pausing.not_nil! < hint.not_nil!).must_equal(true)
    (hint.not_nil! < ok.not_nil!).must_equal(true)
  end

  it "omits the ctrl+C hint when no prompt was given" do
    output = run_pause_playbook(<<-YAML)
      ---
      - name: pause console
        hosts: all
        gather_facts: false
        tasks:
          - name: wait a moment
            ansible.builtin.pause:
              seconds: "1"
      YAML

    output.must_include("Pausing for 1 seconds")
    output.wont_include("ctrl+C")
  end

  it "notes hidden output when echo is false" do
    output = run_pause_playbook(<<-YAML)
      ---
      - name: pause console
        hosts: all
        gather_facts: false
        tasks:
          - name: wait quietly
            ansible.builtin.pause:
              echo: false
              seconds: "1"
      YAML

    output.must_include("Pausing for 1 seconds (output is hidden)")
  end

  it "keeps each loop item's announcement next to that item's status line" do
    output = run_pause_playbook(<<-YAML)
      ---
      - name: pause console
        hosts: all
        gather_facts: false
        tasks:
          - name: wait per item
            ansible.builtin.pause:
              seconds: "1"
            loop: [a, b]
      YAML

    lines = output.lines.map(&.chomp)
    first_ok = lines.index { |line| line == "ok: [localhost] => (item=a)" }
    second_ok = lines.index { |line| line == "ok: [localhost] => (item=b)" }
    first_ok.not_nil!
    second_ok.not_nil!
    # The first "ok:" must already be on the page when the second item
    # announces itself - i.e. the announcements alternate, not stack.
    pausing_before_first = lines[0...first_ok].count { |line| line == "Pausing for 1 seconds" }
    pausing_before_second = lines[0...second_ok].count { |line| line == "Pausing for 1 seconds" }
    pausing_before_first.must_equal(1)
    pausing_before_second.must_equal(2)
  end

  it "stays silent for a when-false pause" do
    output = run_pause_playbook(<<-YAML)
      ---
      - name: pause console
        hosts: all
        gather_facts: false
        tasks:
          - name: never runs
            ansible.builtin.pause:
              prompt: kpg pause
              seconds: "1"
            when: false
      YAML

    output.wont_include("Pausing for")
    output.wont_include("ctrl+C")
  end

  it "keeps the internal console marker out of a registered result" do
    output = run_pause_playbook(<<-YAML)
      ---
      - name: pause console
        hosts: all
        gather_facts: false
        tasks:
          - name: wait a moment
            ansible.builtin.pause:
              prompt: kpg pause
              seconds: "1"
            register: waited
          - name: show it
            ansible.builtin.debug:
              var: waited
      YAML

    output.wont_include("_ansible_pause_console")
  end
end
