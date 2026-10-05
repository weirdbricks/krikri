require "file_utils"
require "../minitest_helper"

# include_vars: with dir: - real Ansible's directory form. Verified live against
# ansible-core 2.19.4 with a minimal role: every vars file under the
# directory loads recursively (sorted, later files overriding earlier),
# depth: 0 means unlimited / depth: 1 means top-level files only,
# files_matching: is a regex searched against the basename,
# ignore_files: is end-anchored, an unknown extension FAILS the task by
# default (only ignore_unknown_extensions: true skips it silently), the
# role's own vars/main.yml loads like any other file (the module's
# main.yml guard is dead code), and name: nests everything under one key.
#
# Runs the compiled binary against a real playbook, since dir:-mode
# include_vars: is end-to-end behavior (parse + execute-time path
# resolution + directory walking + vars merge), not something a unit
# spec against a single method can exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

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

    status.success?.must_equal(true)
    output.to_s.must_include("alpha")
    output.to_s.must_include("beta")
    output.to_s.must_include("shared=from_b")
  end

  it "resolves a relative dir: against the role's vars/ directory" do
    # Real Ansible's _set_root_dir: inside a role, `dir: vars` resolves
    # to the role's own vars/ directory (and a plain subdir name lands
    # under role_path/vars/<name>).
    status, output = run_playbook(<<-YAML)
      - name: load via relative dir
        include_vars:
          dir: vars
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_a }} {{ from_sub }}"
      YAML

    status.success?.must_equal(true)
    output.to_s.must_include("alpha")
    output.to_s.must_include("delta")
  end

  it "skips files rejected by files_matching: and ignore_files:" do
    status, output = run_playbook(<<-YAML)
      - name: load matching vars
        include_vars:
          dir: vars
          files_matching: '^match_'
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_c }} {{ from_a | default('absent') }}"
      YAML

    status.success?.must_equal(true)
    output.to_s.must_include("gamma")
    output.to_s.must_include("absent")
  end

  it "excludes end-anchored ignore_files: entries" do
    status, output = run_playbook(<<-YAML)
      - name: load vars minus b
        include_vars:
          dir: vars
          ignore_files: ['b\\.yml']
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_a }} {{ from_b | default('absent') }}"
      YAML

    status.success?.must_equal(true)
    output.to_s.must_include("alpha")
    output.to_s.must_include("absent")
  end

  it "fails the task on an unknown extension without ignore_unknown_extensions: (real Ansible's default)" do
    status, output = run_playbook(<<-YAML)
      - name: load vars
        include_vars:
          dir: vars
      YAML

    status.success?.must_equal(false)
    output.to_s.must_include("does not have a valid extension")
  end

  it "nests the loaded vars under the name: key" do
    status, output = run_playbook(<<-YAML)
      - name: load vars under a name
        include_vars:
          dir: vars
          ignore_unknown_extensions: true
          name: loaded_vars
      - name: show them
        debug:
          msg: "{{ loaded_vars.from_a }} but not {{ from_a | default('absent') }}"
      YAML

    status.success?.must_equal(true)
    output.to_s.must_include("alpha but not absent")
  end

  it "honors depth: - 1 means top-level files only, 0 (default) means unlimited recursion" do
    status, output = run_playbook(<<-YAML)
      - name: top level only
        include_vars:
          dir: vars
          depth: 1
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_a | default('absent') }} {{ from_sub | default('absent') }}"
      YAML

    status.success?.must_equal(true)
    output.to_s.must_include("alpha absent")
  end

  it "walks subdirectories by default (depth 0 = unlimited)" do
    status, output = run_playbook(<<-YAML)
      - name: recursive load
        include_vars:
          dir: vars
          ignore_unknown_extensions: true
      - name: show them
        debug:
          msg: "{{ from_sub }}"
      YAML

    status.success?.must_equal(true)
    output.to_s.must_include("delta")
  end

  it "fails the task on a directory that does not exist" do
    status, output = run_playbook(<<-YAML)
      - name: load from missing dir
        include_vars:
          dir: vars/no_such_dir
      YAML

    status.success?.must_equal(false)
    output.to_s.must_include("directory does not exist")
  end
end

describe "include_vars: with malformed parameters" do
  it "fails the task when neither file:/dir: is given" do
    # Real ansible-core 2.19.11 (live-verified): a file/dir-less
    # include_vars: is NOT a playbook-load abort - the action runs, its
    # null source_file reaches _find_needle, the dataloader warns on
    # stderr, and the task fails with the action's own result shape
    # ("Could not find file on the Ansible Controller." + the empty
    # ansible_facts/ansible_included_var_files keys), recap failed=1.
    status, output = run_playbook(<<-YAML)
      - name: malformed include_vars
        include_vars:
          name: whatever
      YAML

    status.success?.must_equal(false)
    output.to_s.must_include("[WARNING]: Invalid request to find a file that matches a \"null\" value")
    output.to_s.must_include("Could not find file on the Ansible Controller.")
    output.to_s.must_include("Task failed: Action failed: Unknown error.")
    output.to_s.wont_include("Warning: Skipping")
  end

  it "fails the task on an unknown argument like free-form" do
    # Real ansible-core 2.19.11 (live-verified): the include_vars action's
    # own argument loop rejects the FIRST unknown key at RUN time -
    # "free-form is not a valid option in include_vars" - an ordinary
    # failed task (fatal dump carries only changed + the wrapped msg),
    # not a playbook-load abort. The generator's include_vars chaos shape
    # is exactly this.
    status, output = run_playbook(<<-YAML)
      - name: unknown include_vars arg
        include_vars:
          free-form: lraeca
          hash_behaviour: replace
      YAML

    status.success?.must_equal(false)
    output.to_s.must_include("free-form is not a valid option in include_vars")
    output.to_s.must_include("Task failed: free-form is not a valid option in include_vars")
    output.to_s.wont_include("Warning: Skipping")
  end

  it "reports an unknown argument before the missing-file error" do
    # Real's validate loop runs BEFORE the file lookup, so an unknown key
    # wins even when no file/dir was given either.
    status, output = run_playbook(<<-YAML)
      - name: unknown arg wins
        include_vars:
          free-form: lraeca
      YAML

    status.success?.must_equal(false)
    output.to_s.must_include("free-form is not a valid option in include_vars")
    output.to_s.wont_include("Could not find file on the Ansible Controller.")
  end

  it "reports the alphabetically-first unknown argument, not the YAML-first one" do
    # Real 2.19's chain templar rebuilds the task args mapping with a
    # SORTED keys() iteration, so the include_vars action's
    # first-invalid-key report comes out in alphabetical key order, not
    # YAML order: `files_macthing:` written AFTER `free-form:` is still
    # the one reported ("files_macthing" < "free-form"), whichever order
    # the playbook lists them in (live-verified vs 2.19.11 both ways).
    status, output = run_playbook(<<-YAML)
      - name: sorted unknown arg
        include_vars:
          file: /nonexistent-krikri-test.yml
          free-form: uexnfi
          files_macthing: hnarks
      YAML

    status.success?.must_equal(false)
    output.to_s.must_include("files_macthing is not a valid option in include_vars")
    output.to_s.wont_include("free-form is not a valid option in include_vars")
  end

  it "fails the task when file:-style and dir:-style arguments are mixed" do
    # Real ansible-core 2.19.11 (live-verified): the mixing rejection is
    # the include_vars ACTION's own runtime check - an ordinary failed
    # task ("You are mixing file only and dir only arguments, these are
    # incompatible"), not a parse-time hard stop.
    status, output = run_playbook(<<-YAML)
      - name: mixed include_vars
        include_vars:
          file: a.yml
          dir: vars
      YAML

    status.success?.must_equal(false)
    output.to_s.must_include("mixing file only and dir only arguments")
    output.to_s.wont_include("Warning: Skipping")
  end
end
