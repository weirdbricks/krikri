require "../minitest_helper"
require "file_utils"

# The profile_tasks aggregate-callback emulation (src/krikri/profile_tasks.cr):
# ANSIBLE_CALLBACKS_ENABLED=ansible.posix.profile_tasks (or the short form)
# turns on the per-task timestamp lines and the TASKS RECAP block, shaped
# against live ansible-core 2.19.11 + ansible.posix 2.1.0 captures (the
# fixtures here mirror the real runs byte-for-byte modulo timestamps and
# durations, which are inherently wall-clock-dependent). Everything
# drives the compiled binary with a per-child env, so no suite-process
# ENV is touched (no serial! needed).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

raise "bin/krikri-playbook and bin/plugins/ missing - run ./build.sh first" unless File.exists?(BINARY) && Dir.exists?(File.join(PROJECT_ROOT, "bin", "plugins"))

private def run_playbook(playbook_body : String, env_overrides : Hash(String, String) = {} of String => String, args : Array(String) = [] of String) : {Process::Status, String}
  path = PluginSpecHelper.tmp_path("playbook.yml")
  File.write(path, playbook_body)
  env = {"PATH" => ENV["PATH"], "HOME" => ENV["HOME"], "LANG" => "C.UTF-8"}
  env_overrides.each { |key, value| env[key] = value }
  output = IO::Memory.new
  status = Process.run(BINARY, args + [path], output: output, error: output, chdir: PROJECT_ROOT, env: env)
  {status, output.to_s}
end

# The 3-task demo playbook whose real-Ansible capture lives in the
# module comment of src/krikri/profile_tasks.cr: a command task, a
# debug task, a looped debug task, and a notified handler.
private DEMO_PLAYBOOK = <<-YAML
  ---
  - name: demo
    hosts: localhost
    gather_facts: false
    tasks:
      - name: slow task
        ansible.builtin.command: "true"
        changed_when: true

      - name: another fast one
        ansible.builtin.debug:
          msg: done

      - name: loop task
        ansible.builtin.debug:
          msg: "item {{ item }}"
        loop:
          - a
          - b

      - name: trigger handler
        ansible.builtin.debug:
          msg: notify
        changed_when: true
        notify: my handler

    handlers:
      - name: my handler
        ansible.builtin.debug:
          msg: handler ran
  YAML

describe "profile_tasks callback emulation" do
  describe "enabled display" do
    it "prints an 80-column timestamp line under every task banner" do
      _, output = run_playbook(DEMO_PLAYBOOK, {"ANSIBLE_CALLBACKS_ENABLED" => "ansible.posix.profile_tasks"})

      lines = output.lines
      # Four tasks + one handler = five banners, each immediately followed
      # by the callback's timestamp line.
      banners = lines.each_with_index.select { |(line, _)| line.starts_with?("TASK [") || line.starts_with?("RUNNING HANDLER [") }
      banners.size.must_equal(5)
      banners.each do |(_, idx)|
        line = lines[idx + 1]
        # Exact real shape: `<weekday> <dd> <Month> <yyyy>  <HH:MM:SS> <±HHMM>
        # (<H:MM:SS.mmm>)` + 7 spaces + running total, `*`-padded out to
        # 80 columns with one trailing space (profile_tasks.py's filled()).
        line.must_match(/\A[A-Z][a-z]+day \d{2} [A-Z][a-z]+ \d{4}  \d{2}:\d{2}:\d{2} [-+]\d{4} \(\d+:\d{2}:\d{2}\.\d{3}\) {7}\d+:\d{2}:\d{2}\.\d{3} \*+ \z/)
        line.size.must_equal(80)
      end
    end

    it "prints the TASKS RECAP block after PLAY RECAP, slowest first" do
      _, output = run_playbook(DEMO_PLAYBOOK, {"ANSIBLE_CALLBACKS_ENABLED" => "profile_tasks"})

      lines = output.lines
      recap_idx = lines.index { |line| line.starts_with?("TASKS RECAP ") && line.size == 80 }
      recap_idx = recap_idx.not_nil!
      recap_idx.wont_be_nil

      # The banner is preceded by the blank line its Display.banner call
      # emits, then the callback's own tasktime line, then the 79-char
      # `=` rule with filled()'s trailing space.
      lines[recap_idx - 1].must_equal("")
      lines[recap_idx + 1].must_match(/\A[A-Z][a-z]+day \d{2} [A-Z][a-z]+ \d{4}  \d{2}:\d{2}:\d{2} [-+]\d{4} \(\d+:\d{2}:\d{2}\.\d{3}\) {7}\d+:\d{2}:\d{2}\.\d{3} \*+ \z/)
      lines[recap_idx + 1].size.must_equal(80)
      lines[recap_idx + 2].must_equal("=" * 79 + " ")

      # One row per tracked task (looped task = ONE row), handlers
      # included under their own names, sorted slowest first: the slow
      # command task must outrank everything else.
      rows = lines[(recap_idx + 3)..].select { |line| line =~ /-+ +\d+\.\d{2}s\z/ }
      row_names = rows.map { |line| line.sub(/ -+ +\d+\.\d{2}s\z/, "") }
      row_names.includes?("slow task").must_equal(true)
      row_names.includes?("another fast one").must_equal(true)
      row_names.includes?("loop task").must_equal(true)
      row_names.includes?("trigger handler").must_equal(true)
      row_names.includes?("my handler").must_equal(true)
      row_names.size.must_equal(5)

      # Real row shape: `name ` dash-padded to 70 columns, then the
      # ` X.XXs` value right-aligned in 9 columns with dashes; 79 total
      # (Display.columns - 9 + 9, live-verified against 2.19.11 - the
      # timestamp LINES above are 80 wide, but rows are 79).
      rows.each do |row|
        row.size.must_equal(79)
        row.must_match(/\A.+ -{5,} \d+\.\d{2}s\z/)
      end
      slow_row = rows.find! { |row| row.starts_with?("slow task ") }
      slow_row.must_match(/\Aslow task -+ +\d+\.\d{2}s\z/)
      # The 2-second command task is the slowest row.
      rows.first.must_equal(slow_row)
    end

    it "runs the same path through the --krikri-profile-tasks flag" do
      _, output = run_playbook(DEMO_PLAYBOOK, args: ["--krikri-profile-tasks"])

      output.must_match(/\(\d+:\d{2}:\d{2}\.\d{3}\)/)
      output.must_include("TASKS RECAP ")
    end
  end

  describe "off by default" do
    it "adds nothing to the output when the env var is absent" do
      _, output = run_playbook(DEMO_PLAYBOOK)

      output.wont_include("TASKS RECAP")
      output.lines.none? { |line| line =~ /\(\d+:\d{2}:\d{2}\.\d{3}\)/ }.must_equal(true)
    end
  end

  describe "error-on-unknown" do
    it "exits 1 with the loader error for an unrecognized callback" do
      status, output = run_playbook(DEMO_PLAYBOOK, {"ANSIBLE_CALLBACKS_ENABLED" => "unreal_callback"})

      status.success?.must_equal(false)
      status.exit_code.must_equal(1)
      output.must_include("[ERROR]: Could not load 'unreal_callback' callback plugin.")
      output.wont_include("PLAY [")
    end

    it "errors on any unrecognized entry in a comma-separated list" do
      status, output = run_playbook(DEMO_PLAYBOOK, {"ANSIBLE_CALLBACKS_ENABLED" => "ansible.posix.profile_tasks, dense"})

      status.success?.must_equal(false)
      output.must_include("[ERROR]: Could not load 'dense' callback plugin.")
    end
  end

  describe "coexistence with the oneline stdout callback" do
    it "keeps the TASKS RECAP while oneline suppresses PLAY RECAP" do
      _, output = run_playbook(DEMO_PLAYBOOK, {
        "ANSIBLE_CALLBACKS_ENABLED" => "profile_tasks",
        "ANSIBLE_STDOUT_CALLBACK"   => "oneline",
      })

      output.wont_include("PLAY RECAP")
      output.must_include("TASKS RECAP ")
      # The timestamp lines still print under oneline's bannerless output.
      output.must_match(/\(\d+:\d{2}:\d{2}\.\d{3}\)/)
    end
  end

  it "prints nothing for --syntax-check and --list-tasks" do
    _, syntax = run_playbook(DEMO_PLAYBOOK, {"ANSIBLE_CALLBACKS_ENABLED" => "profile_tasks"}, args: ["--syntax-check"])
    syntax.wont_include("TASKS RECAP")
    syntax.lines.none? { |line| line =~ /\(\d+:\d{2}:\d{2}\.\d{3}\)/ }.must_equal(true)

    _, listing = run_playbook(DEMO_PLAYBOOK, {"ANSIBLE_CALLBACKS_ENABLED" => "profile_tasks"}, args: ["--list-tasks"])
    listing.wont_include("TASKS RECAP")
  end
end
