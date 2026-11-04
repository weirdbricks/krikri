require "../minitest_helper"
require "file_utils"

# include_vars: file lookup from inside a role loaded as another role's
# meta/main.yml DEPENDENCY (issue #297).
#
# Ansible's include_vars search stack is Task.get_search_path(), which
# walks Role.get_dep_chain() - the reversed _parent_role chain ending in
# the DECLARING role - then the directory of the task's own file
# (ansible-core 2.19: base.py#get_search_path). Live-verified vs 2.19.11:
# with role `outerdep` listing `role_java` as a meta dependency and
# role_java's own task include_vars:'ing a missing relative file, the
# "Searched in:" list is
#
#   role_java/vars/X, role_java/X, outerdep/vars/X, outerdep/X,
#   role_java/tasks/vars/X, role_java/tasks/X, <basedir>/vars/X, <basedir>/X
#
# and the SAME stack resolves the file, so a vars file shipped only by the
# declaring role loads from a dependency's include_vars: (krikri silently
# failed that include with "file not found" instead).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Finds the `fatal:` FAILED! line of the run and pulls the action's own
# `message` value out of its result JSON.
private def failed_include_vars_message(output : String) : String
  line = output.each_line.find { |text_line| text_line.includes?("FAILED! => {") }
  raise "no FAILED! line in output:\n#{output}" unless line
  JSON.parse(line.sub(/\A.*FAILED! => /, ""))["message"].as_s
end

# Runs a playbook whose directory already holds the roles it references,
# with cwd anchored there (Ansible's dataloader basedir = the playbook's
# own directory, which krikri takes from the process's working directory).
private def run_in_role_dir(src_dir : String, playbook : String) : String
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new, chdir: src_dir)
  raise "playbook failed with rc=#{status.exit_code}:\n#{output}" unless status.success?
  output.to_s
end

describe "include_vars search list from a meta dependency declares the declaring role" do
  it "lists the declaring (parent) role's dirs in a missing-file Searched in: list" do
    src_dir = File.tempname("include-vars-dep-search")
    Dir.mkdir_p(File.join(src_dir, "roles", "outerdep", "meta"))
    Dir.mkdir_p(File.join(src_dir, "roles", "role_java", "tasks"))
    File.write(File.join(src_dir, "roles", "outerdep", "meta", "main.yml"), <<-YAML)
      dependencies:
        - role_java
      YAML
    File.write(File.join(src_dir, "roles", "role_java", "tasks", "main.yml"), <<-YAML)
      - name: iv
        ansible.builtin.include_vars:
          file: Missing.yml
        ignore_errors: true
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        roles:
          - outerdep
      YAML

    output = run_in_role_dir(src_dir, "pb.yml")
    message = failed_include_vars_message(output)
    message.must_match(/\ACould not find or access 'Missing\.yml'\nSearched in:\n\t/)

    role_java = File.expand_path(File.join(src_dir, "roles", "role_java"))
    outerdep = File.expand_path(File.join(src_dir, "roles", "outerdep"))
    expected = [
      "#{role_java}/vars/Missing.yml",
      "#{role_java}/Missing.yml",
      "#{outerdep}/vars/Missing.yml",
      "#{outerdep}/Missing.yml",
      "#{role_java}/tasks/vars/Missing.yml",
      "#{role_java}/tasks/Missing.yml",
      "#{src_dir}/vars/Missing.yml",
      "#{src_dir}/Missing.yml",
    ]
    searched = message.split("\nSearched in:\n")[1].split(" on the Ansible")[0].split("\n\t").map(&.strip)
    searched.must_equal(expected)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "resolves a vars file shipped only by the declaring role from inside the dependency" do
    src_dir = File.tempname("include-vars-dep-resolve")
    Dir.mkdir_p(File.join(src_dir, "roles", "outerdep", "meta"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outerdep", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "role_java", "tasks"))
    File.write(File.join(src_dir, "roles", "outerdep", "meta", "main.yml"), <<-YAML)
      dependencies:
        - role_java
      YAML
    File.write(File.join(src_dir, "roles", "outerdep", "vars", "Cellar.yml"), <<-YAML)
      from_outer: OUTER
      YAML
    File.write(File.join(src_dir, "roles", "role_java", "tasks", "main.yml"), <<-YAML)
      - name: iv
        ansible.builtin.include_vars:
          file: Cellar.yml
      - name: show
        debug:
          msg: "{{ from_outer }}"
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        roles:
          - outerdep
      YAML

    output = run_in_role_dir(src_dir, "pb.yml")
    output.must_include(%("msg": "OUTER"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "does not search the role's defaults/ dir for a plain include_vars: file" do
    # Real divergence benchmarking hammadrauf.sudousers (issue #796): the
    # role ships its secrets file as defaults/secrets.yml and include_vars:'es
    # a bare "secrets.yml". ansible-playbook FAILS the task ("Could not find
    # or access 'secrets.yml'", its Searched in: list covers only the role's
    # vars/, the role root, the including file's dir pairs and the play-dir
    # pairs - never defaults/), krikri's search stack added the role's
    # defaults/ as a root since the first include_vars: implementation, so
    # the missing file loaded silently and every later task the fatal should
    # have stopped ran anyway.
    src_dir = File.tempname("include-vars-no-defaults-root")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "defaults"))
    File.write(File.join(src_dir, "roles", "myrole", "vars", "os.yml"), "os_var: V\n")
    File.write(File.join(src_dir, "roles", "myrole", "defaults", "secrets.yml"), "secret: LEAKED\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: iv
        ansible.builtin.include_vars: secrets.yml
      - name: show
        debug:
          msg: "{{ secret }}"
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(src_dir, "pb.yml")], output: output, error: output, input: IO::Memory.new, chdir: src_dir)
    status.success?.must_equal(false)
    message = failed_include_vars_message(output.to_s)
    message.must_match(/\ACould not find or access 'secrets\.yml'/)
    defaults_dir = File.join(src_dir, "roles", "myrole", "defaults")
    output.to_s.wont_include(defaults_dir)
    output.to_s.wont_include("LEAKED")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
