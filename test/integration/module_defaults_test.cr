require "file_utils"
require "../minitest_helper"

# `module_defaults:` supplies per-module default arguments. It was
# parsed to nothing, so a task relying on it ran with the argument
# MISSING - `ansible.builtin.debug:` with its msg coming from defaults
# failed outright with "msg or var parameter required".
#
# Expectations from an ansible-core 2.19.4 run of the same playbooks.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def markers(playbook : String) : Array(String)
  dir = File.tempname("module-defaults")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s.scan(/^\s{4}"msg": "([A-Z_]+)"$/m).map { |mat| mat[1] }
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "module_defaults:" do
  # A task's own argument always beats a default. And the key matches on
  # the BARE module name, so an FQCN key supplies defaults to a
  # short-name task (verified both directions against Ansible).
  it "applies play defaults, lets the task override, and matches short vs FQCN names" do
    markers(<<-YAML).must_equal(["FROM_DEFAULTS", "FROM_TASK", "FROM_DEFAULTS"])
      - hosts: all
        gather_facts: false
        module_defaults:
          ansible.builtin.debug:
            msg: "FROM_DEFAULTS"
        tasks:
          - name: uses default
            ansible.builtin.debug:
          - name: overrides default
            ansible.builtin.debug:
              msg: "FROM_TASK"
          - name: short name form
            debug:
      YAML
  end

  # Play, block and task scope, nearest winning.
  it "honors block and task scope over play scope" do
    markers(<<-YAML).must_equal(["PLAY_DEFAULT", "BLOCK_DEFAULT", "TASK_DEFAULT"])
      - hosts: all
        gather_facts: false
        module_defaults:
          debug:
            msg: "PLAY_DEFAULT"
        tasks:
          - name: fqcn task, short key
            ansible.builtin.debug:
          - name: block scope
            module_defaults:
              debug:
                msg: "BLOCK_DEFAULT"
            block:
              - name: inside block
                ansible.builtin.debug:
          - name: task scope
            ansible.builtin.debug:
            module_defaults:
              debug:
                msg: "TASK_DEFAULT"
      YAML
  end

  # An action-group key expands to its member modules. `group/aws` is
  # defined by ansible.builtin itself (as an extend_group pointer into
  # amazon.aws), so it RESOLVES even with that collection absent and the
  # rest of the mapping applies - verified against Ansible, which
  # exits 0 here.
  it "accepts a builtin action-group key that resolves to no installed modules" do
    markers(<<-YAML).must_equal(["STILL_APPLIED"])
      - hosts: all
        gather_facts: false
        module_defaults:
          group/aws:
            region: eu-west-1
          debug:
            msg: "STILL_APPLIED"
        tasks:
          - name: t
            ansible.builtin.debug:
      YAML
  end

  # Guard against over-reach: a module with no defaults entry is
  # untouched, and a task whose argument is absent everywhere still
  # fails the way it always did.
  it "leaves an unrelated module alone" do
    markers(<<-YAML).must_equal(["EXPLICIT"])
      - hosts: all
        gather_facts: false
        module_defaults:
          ansible.builtin.file:
            mode: "0640"
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "EXPLICIT"
      YAML
  end
end

# Action groups proper: membership comes from krikri's OWN baked capture of
# the collections' meta/runtime.yml (collection_runtime_data.cr), not from
# anything installed on this machine - so a group resolves the same way on
# every controller and a collection tree planted via
# ANSIBLE_COLLECTIONS_PATH changes nothing.
# A decoy runtime.yml for the action-group specs below: it defines a
# `demo` group (and an `extended` one that extends it) exactly the way a
# collection the operator had installed would. krikri's action groups come
# from its OWN baked capture, so nothing here may resolve.
private ACTION_GROUP_RUNTIME = <<-YAML
  action_groups:
    demo:
      - debug
    extended:
      - metadata:
          extend_group:
            - testns.testcoll.demo
  YAML

private def run_with_collections(playbook : String, runtime : String) : {Int32, String}
  dir = File.tempname("action-groups")
  # A DECOY collection whose runtime.yml defines a `demo` group: under the
  # old scan this is what made `group/demo` resolvable.
  meta = File.join(dir, "collections", "ansible_collections", "testns", "testcoll", "meta")
  Dir.mkdir_p(meta)
  File.write(File.join(meta, "runtime.yml"), runtime)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir,
    env: {"ANSIBLE_COLLECTIONS_PATH" => File.join(dir, "collections")})
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "module_defaults: action groups" do
  # community.docker's own `docker` group is in krikri's capture (its
  # members are the docker_* modules), so it resolves and the rest of the
  # mapping still applies.
  it "accepts a captured collection's action group" do
    code, output = run_with_collections(<<-YAML, ACTION_GROUP_RUNTIME)
      - hosts: all
        gather_facts: false
        module_defaults:
          group/community.docker.docker:
            docker_host: unix:///var/run/docker.sock
          debug:
            msg: "STILL_APPLIED"
        tasks:
          - name: t
            ansible.builtin.debug:
      YAML

    code.must_equal(0)
    output.must_include("STILL_APPLIED")
  end

  # metadata/extend_group pulls in another group's members:
  # community.mysql's `all` extends ansible.mysql's `all`.
  it "follows extend_group in the captured tables" do
    groups = Krikri::ActionGroups.groups
    groups["community.mysql.all"]?.must_equal(Krikri::ActionGroups.groups["ansible.mysql.all"])
    code, _output = run_with_collections(<<-YAML, ACTION_GROUP_RUNTIME)
      - hosts: all
        gather_facts: false
        module_defaults:
          group/community.mysql.all:
            login_user: krikri
          debug:
            msg: "STILL_APPLIED"
        tasks:
          - name: t
            ansible.builtin.debug:
      YAML
    code.must_equal(0)
  end

  # A group nothing defines is an ERROR, with Ansible's own message and
  # exit code 4 - a bare name resolves in ansible.builtin, so `group/demo`
  # does NOT match a collection's `demo` group... and the planted decoy
  # that would have defined one no longer counts.
  it "refuses an unresolvable group the way Ansible does, whatever is installed" do
    code, output = run_with_collections(<<-YAML, ACTION_GROUP_RUNTIME)
      - hosts: all
        gather_facts: false
        module_defaults:
          group/demo:
            msg: "NEVER"
        tasks:
          - name: t
            ansible.builtin.debug:
      YAML

    code.must_equal(4)
    output.must_include("could not resolve the module_defaults group ansible.builtin.demo")
  end
end
