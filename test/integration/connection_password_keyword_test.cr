require "../minitest_helper"
require "file_utils"

# Regression spec for issue #1419: ansible post-validates every task's
# PlayContext connection keywords, so a role's exported
# `ansible_password: "{{ vault_ansible_password }}"` whose vault variable
# is missing fails the FIRST task the host runs - the implicit Gathering
# Facts task included - with "Error processing keyword 'password': ...".
# krikri read the variable raw, connected anyway and diverged later on a
# different task (jedimt.authorized_keys).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a connection password whose template does not resolve" do
  it "fails the implicit Gathering Facts task with ansible's keyword chain" do
    root = File.tempname("connection-password-gather")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        vars:
          ansible_password: "{{ vault_missing }}"
        tasks:
          - name: never runs
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"],
      output: output, error: output, chdir: root,
      # Pin gathering: the ambient developer env (ANSIBLE_GATHERING=smart
      # plus a warm fact cache) would skip the implicit gather task.
      env: {"PATH" => ENV["PATH"], "HOME" => ENV["HOME"], "ANSIBLE_GATHERING" => "implicit"})
    text = output.to_s

    status.success?.must_equal(false, text)
    text.includes?("TASK [Gathering Facts]").must_equal(true, text)
    text.includes?("[ERROR]: Task failed: Error processing keyword 'password': 'vault_missing' is undefined").must_equal(true, text)
    # The implicit task has no source position of its own: the collapsed
    # chain's first link prints bare, the keyword link points at the
    # variable's definition.
    text.includes?("Task failed.\n\n<<< caused by >>>").must_equal(true, text)
    text.includes?("Error processing keyword 'password': 'vault_missing' is undefined\nOrigin: ").must_equal(true, text)
    text.includes?("pb.yml:4:23").must_equal(true, text)
    text.includes?(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Error processing keyword 'password': 'vault_missing' is undefined"})).must_equal(true, text)
    # The play's own tasks never ran.
    text.includes?(%("msg": "hi")).must_equal(false, text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "reads only the password spellings PlayContext reads" do
    root = File.tempname("connection-password-spellings")
    Dir.mkdir_p(root)

    # ansible_ssh_pass is a MAGIC_VARIABLE_MAPPING spelling of `password`,
    # ansible_ssh_password only the ssh plugin's own option - a broken
    # template behind the latter fails nothing (live-verified vs 2.21.6).
    File.write(File.join(root, "ssh_pass.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        vars:
          ansible_ssh_pass: "{{ vault_missing }}"
        tasks:
          - name: never runs
            debug:
              msg: hi
      YAML
    File.write(File.join(root, "ssh_plugin_pass.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        vars:
          ansible_ssh_password: "{{ vault_missing }}"
        tasks:
          - name: plain
            debug:
              msg: hi
      YAML

    gather_env = {"PATH" => ENV["PATH"], "HOME" => ENV["HOME"], "ANSIBLE_GATHERING" => "implicit"}

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "ssh_pass.yml"],
      output: output, error: output, chdir: root, env: gather_env)
    text = output.to_s
    status.success?.must_equal(false, text)
    text.includes?(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Error processing keyword 'password': 'vault_missing' is undefined"})).must_equal(true, text)

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "ssh_plugin_pass.yml"],
      output: output, error: output, chdir: root, env: gather_env)
    text = output.to_s
    status.success?.must_equal(true, text)
    text.includes?("Error processing keyword").must_equal(false, text)
    text.includes?(%("msg": "hi")).must_equal(true, text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "sees a vars_files password when gathering facts" do
    root = File.tempname("connection-password-vars-file")
    Dir.mkdir_p(root)

    File.write(File.join(root, "vars.yml"), <<-YAML)
      ansible_password: "{{ vault_missing }}"
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        vars_files:
          - vars.yml
        tasks:
          - name: never runs
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"],
      output: output, error: output, chdir: root,
      env: {"PATH" => ENV["PATH"], "HOME" => ENV["HOME"], "ANSIBLE_GATHERING" => "implicit"})
    text = output.to_s

    status.success?.must_equal(false, text)
    text.includes?("TASK [Gathering Facts]").must_equal(true, text)
    text.includes?(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Error processing keyword 'password': 'vault_missing' is undefined"})).must_equal(true, text)
    text.includes?("vars.yml:1:19").must_equal(true, text)
    text.includes?(%("msg": "hi")).must_equal(false, text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails the first regular task before its args finalize" do
    root = File.tempname("connection-password-task")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          ansible_password: "{{ vault_missing }}"
        tasks:
          - name: plain
            debug:
              msg: "{{ also_missing }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
    text = output.to_s

    status.success?.must_equal(false, text)
    # A debug: task's fatal carries msg alone (real drops changed: false
    # from the dump), and the keyword failure beats the undefined arg.
    text.includes?(%(fatal: [localhost]: FAILED! => {"msg": "Task failed: Error processing keyword 'password': 'vault_missing' is undefined"})).must_equal(true, text)
    text.includes?("Finalization of task args").must_equal(false, text)
    text.includes?("Task failed.\nOrigin: ").must_equal(true, text)
    text.includes?("pb.yml:6:7").must_equal(true, text)
    text.includes?("pb.yml:4:23").must_equal(true, text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still skips a when: false task instead of failing it" do
    root = File.tempname("connection-password-skip")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          ansible_password: "{{ vault_missing }}"
        tasks:
          - name: skipped first
            debug:
              msg: skipped
            when: false
          - name: plain
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
    text = output.to_s

    status.success?.must_equal(false, text)
    skip_idx = text.index("skipping: [localhost]")
    error_idx = text.index("[ERROR]: Task failed: Error processing keyword 'password'")
    skip_idx.wont_be_nil(text)
    error_idx.wont_be_nil(text)
    (error_idx.not_nil! > skip_idx.not_nil!).must_equal(true, text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "runs the play when the password renders and when the task is delegated" do
    root = File.tempname("connection-password-defined")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          real_pass: "hunter2"
          ansible_password: "{{ real_pass }}"
        tasks:
          - name: plain
            debug:
              msg: hi
          - name: delegated
            debug:
              msg: delegated
            delegate_to: localhost
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
    text = output.to_s

    status.success?.must_equal(true, text)
    text.includes?(%("msg": "hi")).must_equal(true, text)
    text.includes?(%("msg": "delegated")).must_equal(true, text)
    text.includes?("Error processing keyword 'password'").must_equal(false, text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails a handler whose own vars carry the broken password" do
    root = File.tempname("connection-password-handler")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            debug:
              msg: trigger
            changed_when: true
            notify: broken
        handlers:
          - name: broken
            vars:
              ansible_password: "{{ vault_missing }}"
            debug:
              msg: handler
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
    text = output.to_s

    status.success?.must_equal(false, text)
    handler_idx = text.index("RUNNING HANDLER [broken]")
    error_idx = text.index("[ERROR]: Task failed: Error processing keyword 'password': 'vault_missing' is undefined")
    handler_idx.wont_be_nil(text)
    error_idx.wont_be_nil(text)
    (error_idx.not_nil! > handler_idx.not_nil!).must_equal(true, text)
    text.includes?("pb.yml:12:27").must_equal(true, text)
    text.includes?(%("msg": "handler")).must_equal(false, text)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
