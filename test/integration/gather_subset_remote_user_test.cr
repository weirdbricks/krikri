require "file_utils"
require "../minitest_helper"

# `gather_subset:` and `remote_user:`, both previously parsed to nothing.
#
# NOTE on verifying gather_subset against Ansible: this machine's
# shell exports ANSIBLE_GATHERING=smart with a pickle fact cache, which
# makes a subsetted gather appear to have NO effect (the cached full set
# is reused). The real behavior only shows with those unset - a trap
# worth recording, since it makes the feature look already-correct.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_play(playbook : String) : String
  dir = File.tempname("gs-ru")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private def facts_for(subset : String) : String
  run_play(<<-YAML)
    - hosts: all
      gather_facts: true
      gather_subset: #{subset}
      tasks:
        - name: t
          ansible.builtin.debug:
            msg: "proc={{ ansible_processor_count | default('none') }} dist={{ ansible_distribution | default('none') }}"
    YAML
end

describe "gather_subset:" do
  it "gathers hardware facts with the default/all subset" do
    facts_for("all").must_match(/proc=\d+ dist=\w+/)
  end

  # !hardware skips the expensive family but KEEPS the minimal facts -
  # this is the whole point of subsetting.
  it "skips hardware facts for !hardware, keeping the minimal set" do
    output = facts_for(%("!hardware"))
    output.must_include("proc=none")
    output.wont_include("dist=none")
  end

  # min is a floor: "!all, min" still yields the minimal facts.
  it "treats min as a floor that !all cannot remove" do
    output = facts_for(%(["!all", "min"]))
    output.must_include("proc=none")
    output.wont_include("dist=none")
  end
end

describe "remote_user:" do
  # Ansible surfaces remote_user as ansible_user, and a task's own
  # value overrides the play's for that task.
  it "sets ansible_user at play scope and lets a task override it" do
    output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        remote_user: playuser
        tasks:
          - name: play-level
            ansible.builtin.debug: {msg: "U={{ ansible_user | default('-') }}"}
          - name: task-level
            ansible.builtin.debug: {msg: "T={{ ansible_user | default('-') }}"}
            remote_user: taskuser
      YAML

    output.must_include("U=playuser")
    output.must_include("T=taskuser")
  end

  # ANSIBLE_REMOTE_USER (issue #1067) - the env form of ansible's
  # DEFAULT_REMOTE_USER - surfaces exactly like the keyword: PlayContext
  # update_vars fills BOTH magic names from the resolved remote_user
  # when no variable supplies either (verified 2.21.6: with only
  # ANSIBLE_REMOTE_USER=root set, `{{ ansible_user }}` and
  # `{{ ansible_ssh_user }}` both render root). The child runs with the
  # env var set, so no process-wide ENV is mutated here.
  it "surfaces ANSIBLE_REMOTE_USER as ansible_user/ansible_ssh_user" do
    dir = File.tempname("ru-env")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "U={{ ansible_user | default('-') }} S={{ ansible_ssh_user | default('-') }}"}
      YAML

    begin
      stdout_io = IO::Memory.new
      Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir,
        env: {"ANSIBLE_REMOTE_USER" => "envuser"})
      stdout_io.to_s.must_include("U=envuser S=envuser")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # A user VARIABLE outranks the env setting (ansible's vars-before-env
  # order) and then surfaces on its own - the fill never overwrites it.
  it "keeps an inventory ansible_user above ANSIBLE_REMOTE_USER" do
    dir = File.tempname("ru-env-inv")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local ansible_user=invuser\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "U={{ ansible_user | default('-') }}"}
      YAML

    begin
      stdout_io = IO::Memory.new
      Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir,
        env: {"ANSIBLE_REMOTE_USER" => "envuser"})
      stdout_io.to_s.must_include("U=invuser")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # -e/--extra-vars still outranks it, as it outranks everything.
  it "is still beaten by --extra-vars" do
    dir = File.tempname("ru-extra")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        remote_user: playuser
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "U={{ ansible_user }}"}
      YAML

    begin
      stdout_io = IO::Memory.new
      Process.run(BINARY, ["-i", "inv.ini", "-e", "ansible_user=cliuser", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir)
      stdout_io.to_s.must_include("U=cliuser")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
