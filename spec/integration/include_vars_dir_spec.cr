require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook, since dir:-mode
# include_vars: is end-to-end behavior (parse + execute-time path
# resolution + directory walking + vars merge), not something a unit
# spec against a single method can exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(task_lines : String) : {Process::Status, String}
  src_dir = File.tempname("include-vars-dir-role")
  Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars", "sub"))
  Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
  File.write(File.join(src_dir, "roles", "myrole", "vars", "a.yml"), "from_a: alpha\nshared: from_a\n")
  File.write(File.join(src_dir, "roles", "myrole", "vars", "b.yml"), "from_b: beta\nshared: from_b\n")
  File.write(File.join(src_dir, "roles", "myrole", "vars", "match_c.yml"), "from_c: gamma\n")
  File.write(File.join(src_dir, "roles", "myrole", "vars", "notes.txt"), "not a vars file\n")
  File.write(File.join(src_dir, "roles", "myrole", "vars", "sub", "d.yml"), "from_sub: delta\n")
  File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), task_lines)

  playbook = File.join(src_dir, "pb.yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      roles:
        - myrole
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(src_dir) if src_dir
end

describe "include_vars: with dir:" do
  it "loads every vars file in the directory, sorted, later files overriding earlier" do
    status, output = run_playbook(<<-YAML)
      - name: load all vars
        include_vars:
          dir: "{{ role_path }}/vars"
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_a }} {{ from_b }} shared={{ shared }}"
      YAML

    status.success?.should be_true
    output.to_s.should contain("alpha")
    output.to_s.should contain("beta")
    output.to_s.should contain("shared=from_b")
  end

  it "skips files rejected by files_matching:" do
    status, output = run_playbook(<<-YAML)
      - name: load matching vars
        include_vars:
          dir: "{{ role_path }}/vars"
          files_matching: '^match_'
      - name: show them
        debug:
          msg: "{{ from_c }} {{ from_a | default('absent') }}"
      YAML

    status.success?.should be_true
    output.to_s.should contain("gamma")
    output.to_s.should contain("absent")
  end

  it "skips non-vars files with ignore_unknown_extensions: instead of erroring" do
    status, output = run_playbook(<<-YAML)
      - name: load vars ignoring junk
        include_vars:
          dir: "{{ role_path }}/vars"
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_a }}"
      YAML

    status.success?.should be_true
    output.to_s.should contain("alpha")
  end

  it "fails the task on an unknown extension without ignore_unknown_extensions:" do
    status, output = run_playbook(<<-YAML)
      - name: load vars
        include_vars:
          dir: "{{ role_path }}/vars"
      YAML

    status.success?.should be_false
    output.to_s.should contain("does not have a valid extension")
  end

  it "nests the loaded vars under the name: key" do
    status, output = run_playbook(<<-YAML)
      - name: load vars under a name
        include_vars:
          dir: "{{ role_path }}/vars"
          ignore_unknown_extensions: true
          name: loaded_vars
      - name: show them
        debug:
          msg: "{{ loaded_vars.from_a }} but not {{ from_a | default('absent') }}"
      YAML

    status.success?.should be_true
    output.to_s.should contain("alpha but not absent")
  end

  it "honors depth: - 1 means top-level files only, 0 means unlimited recursion" do
    status, output = run_playbook(<<-YAML)
      - name: top level only
        include_vars:
          dir: "{{ role_path }}/vars"
          depth: 1
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_a | default('absent') }} {{ from_sub | default('absent') }}"
      YAML

    status.success?.should be_true
    output.to_s.should contain("alpha absent")
  end

  it "walks subdirectories by default (depth 0 = unlimited)" do
    status, output = run_playbook(<<-YAML)
      - name: recursive load
        include_vars:
          dir: "{{ role_path }}/vars"
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_sub }}"
      YAML

    status.success?.should be_true
    output.to_s.should contain("delta")
  end
end

describe "include_vars: with neither file:/path:/dir:" do
  it "hard-stops the run instead of degrading to a warning-skip" do
    # 0.9.903 policy: an unimplemented/malformed include_vars: form
    # must refuse the whole run, never silently lose the task behind a
    # "Warning: Skipping task" line.
    status, output = run_playbook(<<-YAML)
      - name: malformed include_vars
        include_vars:
          name: whatever
      YAML

    status.success?.should be_false
    output.to_s.should contain("include_vars: requires a file or dir")
    output.to_s.should_not contain("Warning: Skipping")
  end
end
