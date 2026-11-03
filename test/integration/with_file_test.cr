require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_with_file, a private method not reachable from a
# unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "with_file:" do
  # Real bug found benchmarking juju4.adduser's own "Add authorized keys
  # for user" task: `with_file: "{{ adduser_public_keys }}"` (a
  # templated variable resolving to a real list, e.g. [dummykey.pub],
  # Ansible's own idiom - the same shape with_fileglob's own
  # templated-list handling already covers). with_file: was entirely
  # unimplemented as a distinct loop type - `item` never got bound at
  # all, failing every task with "'item' is undefined" regardless of
  # whether the listed file actually existed. Ansible's `file`
  # lookup plugin reads each listed file's CONTENT (not just the
  # filename, unlike with_fileglob's pattern matching) and searches a
  # relative entry under the role's own files/ dir.
  it "reads each listed file's content into item, searching a relative entry under the role's files/ dir" do
    role_dir = File.join(PROJECT_ROOT, "test", "tmp", "with_file_role_spec")
    FileUtils.rm_rf(role_dir)
    Dir.mkdir_p(File.join(role_dir, "files"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "files", "dummykey.pub"), "ssh-rsa AAAATESTKEY foo@bar.local\n")
    File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
      - name: read the file
        ansible.builtin.debug:
          msg: "{{ item }}"
        with_file: "{{ public_keys }}"
        register: result
      - name: assert content, not the filename, was bound to item
        ansible.builtin.assert:
          that:
            - result.results[0].item == "ssh-rsa AAAATESTKEY foo@bar.local"
      YAML

    playbook = File.tempname("with-file-spec-playbook", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          public_keys: [dummykey.pub]
        roles:
          - #{role_dir}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.wont_include("'item' is undefined")
  ensure
    FileUtils.rm_rf(role_dir) if role_dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Real bug found benchmarking gurkalov.deploy_user (issue #787): its
  # dependency lnovara.deploy-user defaults `public_keys: [~/.ssh/id_rsa.pub]`
  # and feeds it to `with_file:`. Ansible's file lookup expands the term
  # against the controller user's home BEFORE the role-relative search
  # (same rule issue #52 already fixed for lookup('file', ...)), while
  # resolve_with_file joined `files/~/.ssh/id_rsa.pub` under the role and
  # failed the whole task. HOME is passed through the child's env, not
  # mutated here, so no serial! opt-in is needed.
  it "resolves a ~/ term against the controller user's HOME, not the role's files/ dir" do
    fake_home = File.join(PROJECT_ROOT, "test", "tmp", "with_file_home_spec")
    FileUtils.rm_rf(fake_home)
    Dir.mkdir_p(File.join(fake_home, ".ssh"))
    File.write(File.join(fake_home, ".ssh", "testkey.pub"), "ssh-rsa AAAAHOMEKEY home@host.local\n")
    role_dir = File.join(PROJECT_ROOT, "test", "tmp", "with_file_role_tilde_spec")
    FileUtils.rm_rf(role_dir)
    Dir.mkdir_p(File.join(role_dir, "files"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
      - name: read the home key
        ansible.builtin.debug:
          msg: "{{ item }}"
        with_file: "{{ public_keys }}"
        register: result
      - name: assert the home file's content was bound to item
        ansible.builtin.assert:
          that:
            - result.results[0].item == "ssh-rsa AAAAHOMEKEY home@host.local"
      YAML

    playbook = File.tempname("with-file-tilde-spec-playbook", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          public_keys: ["~/.ssh/testkey.pub"]
        roles:
          - #{role_dir}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"HOME" => fake_home})

    status.success?.must_equal(true)
    output.to_s.wont_include("Unable to access the file")
  ensure
    FileUtils.rm_rf(fake_home) if fake_home
    FileUtils.rm_rf(role_dir) if role_dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails the task clearly when a listed file doesn't exist, instead of leaving item undefined" do
    playbook = File.tempname("with-file-missing-spec-playbook", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: read a file that does not exist
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_file:
              - /nonexistent/path/does-not-exist.txt
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.must_include("Unable to access the file")
    output.to_s.wont_include("'item' is undefined")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
