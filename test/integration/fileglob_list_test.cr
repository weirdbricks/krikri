require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_fileglob, a private method not reachable from a
# unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "with_fileglob: templating a list variable" do
  it "treats each list element as its own glob pattern, not the JSON array text as one pattern" do
    # Real bug found benchmarking cloudalchemy.prometheus's own "copy
    # custom alerting rule files" task: `with_fileglob: "{{
    # prometheus_alert_rules_files }}"`, a templated variable whose
    # value is a LIST of patterns (`[prometheus/rules/*.rules]`) -
    # Ansible's own idiom for this. #resolve_fileglob's plain string
    # substitution had no notion of the underlying value being a real
    # array, so it rendered the whole thing as the JSON-array TEXT
    # (`["prometheus/rules/*.rules"]`, literal brackets/quotes) and
    # handed that straight to Dir.glob as one pattern - its own bracket
    # syntax means "character class", so this always raised
    # Regex::Error ("unterminated character set") instead of matching
    # real files.
    dir = File.tempname("fileglob-list-spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.rules"), "a")
    File.write(File.join(dir, "b.rules"), "b")

    playbook = File.tempname("fileglob-list-spec-playbook", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          my_patterns:
            - #{dir}/*.rules
        tasks:
          - name: glob
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_fileglob: "{{ my_patterns }}"
            register: glob_result
          - name: assert count
            ansible.builtin.assert:
              that:
                - glob_result.results | length == 2
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.wont_include("unterminated character set")
  ensure
    FileUtils.rm_rf(dir) if dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Real bug found benchmarking clouddrove.ansible_role_docker_nginx
  # (round 5210000): `with_fileglob: ../templates/config/site.d/*.*`
  # inside the role's tasks/ dir. The old pattern handling left every
  # pattern with a directory part cwd-relative, so it globbed the
  # process cwd and matched nothing - all four config-transfer tasks
  # skipped, nginx ran without its config, and the role's wait_for
  # timed out at 305s where real had already failed the role on an
  # unrelated undefined var. Ansible's fileglob lookup dwims a
  # dir-carrying pattern's dirname through find_file_in_search_path
  # (first existing candidate of the task's search stack, basedir
  # first) and a bare pattern through `<p>/files` then `<p>` per
  # search-stack path, first match winning - each shape verified
  # byte-identical against 2.19.11 (item paths keep the unnormalized
  # `<tasks>/../templates/...` join).
  it "dwims a dir-carrying pattern through the task's search stack" do
    dir = File.tempname("fileglob-dwim-spec")
    FileUtils.mkdir_p(File.join(dir, "roles", "r", "tasks"))
    FileUtils.mkdir_p(File.join(dir, "roles", "r", "templates", "config", "site.d"))
    File.write(File.join(dir, "roles", "r", "templates", "config", "site.d", "a.conf"), "a")
    File.write(File.join(dir, "roles", "r", "templates", "config", "site.d", "b.conf"), "b")
    # a cwd-relative leftover the old cwd-relative bug would have picked up
    File.write(File.join(dir, "stray.conf"), "stray")
    File.write(File.join(dir, "roles", "r", "tasks", "main.yml"), <<-YAML)
      - name: glob transfer
        ansible.builtin.debug:
          msg: "{{ item }}"
        with_fileglob:
          - ../templates/config/site.d/*.conf
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - r
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)

    status.success?.must_equal(true)
    expected = File.join(dir, "roles", "r", "tasks", "..", "templates", "config", "site.d")
    output.to_s.must_include(File.join(expected, "a.conf"), output.to_s)
    output.to_s.must_include(File.join(expected, "b.conf"), output.to_s)
    output.to_s.wont_include("stray.conf")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "falls a bare pattern back to the role root when files/ has no match" do
    dir = File.tempname("fileglob-bare-spec")
    FileUtils.mkdir_p(File.join(dir, "roles", "r", "tasks"))
    File.write(File.join(dir, "roles", "r", "root_only.conf"), "x")
    File.write(File.join(dir, "roles", "r", "tasks", "main.yml"), <<-YAML)
      - name: bare glob
        ansible.builtin.debug:
          msg: "{{ item }}"
        with_fileglob:
          - "*.conf"
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - r
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)

    status.success?.must_equal(true)
    output.to_s.must_include(File.join(dir, "roles", "r", "root_only.conf"), output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
