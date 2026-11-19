require "../minitest_helper"
require "file_utils"

# A module name krikri cannot resolve no longer refuses the WHOLE playbook
# at load, and nothing about it depends on what this controller has
# installed. krikri resolves module names from its OWN baked tables
# (CollectionIndex: the pinned ansible-core name/redirect tables and the
# captured collections' file trees) and leaves an unresolvable name to the
# executor's unavailable-module flow: a `when:`-gated task skips cleanly
# (round 811000), a genuinely reached one is reported and the run exit(4)s
# at the end.
#
# The earlier "controller collection-set awareness" refused the whole run
# (rc=4, zero tasks) whenever real's installed set would have, which made
# the same playbook behave differently on two controllers - it was never
# approved and is gone. These specs pin the new contract, including the
# part that matters most: pointing ANSIBLE_COLLECTIONS_PATH at a fixture
# tree (which used to flip the verdict) changes nothing.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# A controller-shaped collection tree, pointed at via
# ANSIBLE_COLLECTIONS_PATH for the spawned binary only. Under the old
# resolution these files decided whether a name resolved; now nothing may
# read them.
private def fixture_collections_root : String
  root = PluginSpecHelper.tmp_path("collection-awareness-fixture")
  FileUtils.mkdir_p(File.join(root, "ansible_collections", "community", "docker", "plugins", "modules"))
  FileUtils.mkdir_p(File.join(root, "ansible_collections", "kubernetes", "core", "plugins", "modules"))
  File.write(File.join(root, "ansible_collections", "kubernetes", "core", "plugins", "modules", "helm_repository.py"), "#!/usr/bin/python\n")
  File.write(File.join(root, "ansible_collections", "community", "docker", "plugins", "modules", "added_by_fixture.py"), "#!/usr/bin/python\n")
  root
end

private def run_playbook(pb : String, env : Hash(String, String)? = nil) : {Process::Status, String, String}
  playbook = File.tempname("collection-awareness", ".yml")
  File.write(playbook, pb)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr, env: env)
  {status, stdout.to_s, stderr.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unresolvable module names never refuse the whole playbook" do
  it "runs the other tasks and reports a missing-collection FQCN as unimplemented (exit 4)" do
    status, stdout, stderr = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: normal
            ansible.builtin.debug: msg=hi
          - name: missing coll
            freeipa.ansible_freeipa.ipaclient_setup_nis:
              state: present
      YAML
    status.exit_code.must_equal(4, "stderr:\n#{stderr}")
    stdout.must_include("TASK [normal]")
    stdout.must_include("TASK [missing coll]")
    stdout.must_include("PLAY RECAP")
    stdout.must_include("uses unimplemented plugin: freeipa.ansible_freeipa.ipaclient_setup_nis")
    stderr.wont_include("couldn't resolve module/action")
    stderr.wont_include("Error loading plugin")
  end

  it "does the same for a bare name real cannot resolve either (docker)" do
    status, stdout, stderr = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bare docker
            docker:
              state: present
      YAML
    status.exit_code.must_equal(4, "stderr:\n#{stderr}")
    stdout.must_include("PLAY RECAP")
    stdout.must_include("uses unimplemented plugin: docker")
    stderr.wont_include("couldn't resolve module/action")
  end

  it "does the same for a bare name whose builtin redirect lands in an uncaptured collection" do
    status, stdout, stderr = run_playbook(<<-YAML, {"ANSIBLE_COLLECTIONS_PATH" => fixture_collections_root})
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: dead redirect
            gc_storage:
              bucket: x
      YAML
    status.exit_code.must_equal(4, "stderr:\n#{stderr}")
    stdout.must_include("PLAY RECAP")
    stdout.must_include("uses unimplemented plugin: gc_storage")
    stderr.wont_include("couldn't resolve module/action")
  end

  it "keeps a when:-gated unimplemented module on the lazy skip path" do
    status, stdout, stderr = run_playbook(<<-YAML, {"ANSIBLE_COLLECTIONS_PATH" => fixture_collections_root})
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: first
            ansible.builtin.debug:
              msg: hi
          - name: gated unported
            kubernetes.core.helm_repository:
              repo_name: foo
            when: false
      YAML
    status.success?.must_equal(true, stderr)
    stdout.must_include("PLAY RECAP")
    stdout.must_include("skipping: [localhost]")
    stderr.wont_include("couldn't resolve module/action")
  end

  it "answers identically with the collection env pointed at a fixture tree" do
    # The fixture ships a module file the old index would have resolved
    # (community.docker.added_by_fixture) and helm_repository for
    # kubernetes.core. Neither may change a single line of output.
    playbook = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: normal
            ansible.builtin.debug: msg=hi
          - name: fixture-provided
            community.docker.added_by_fixture:
          - name: gated unported
            kubernetes.core.helm_repository:
              repo_name: foo
            when: false
      YAML
    plain_status, plain_out, plain_err = run_playbook(playbook)
    fixture_status, fixture_out, fixture_err = run_playbook(playbook,
      {"ANSIBLE_COLLECTIONS_PATH" => fixture_collections_root})

    fixture_status.exit_code.must_equal(plain_status.exit_code)
    fixture_status.exit_code.must_equal(4)
    fixture_out.must_equal(plain_out)
    fixture_err.must_equal(plain_err)
    plain_out.must_include("uses unimplemented plugin: community.docker.added_by_fixture")
  end

  it "resolves a bare module name through the play's collections: keyword" do
    status, stdout, stderr = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        collections:
          - community.crypto
        tasks:
          - name: keyword-resolved module
            x509_certificate:
              path: /tmp/collection-awareness-x.pem
            when: false
      YAML
    status.success?.must_equal(true, stderr)
    stdout.must_include("keyword-resolved module")
    stderr.wont_include("couldn't resolve module/action")
  end

  it "resolves a bare module name through the role's meta/main.yml collections:" do
    # community.crypto is one of the captured collections, so the bare
    # spelling resolves onto krikri's own x509_certificate plugin - the
    # role's meta declaration is read from the ROLE (not from any
    # installation).
    role_root = File.join(PluginSpecHelper.tmp_path("collection-role-meta"), "role_meta")
    FileUtils.mkdir_p(File.join(role_root, "meta"))
    FileUtils.mkdir_p(File.join(role_root, "tasks"))
    File.write(File.join(role_root, "meta", "main.yml"),
      "collections:\n  - community.crypto\n")
    File.write(File.join(role_root, "tasks", "main.yml"),
      "- name: role-meta-resolved module\n  x509_certificate:\n    path: /tmp/role-meta-x.pem\n  when: false\n")
    playbook = File.tempname("collection-role-meta", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - #{role_root}
    YAML
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    status.success?.must_equal(true, stderr.to_s)
    stdout.to_s.must_include("role-meta-resolved module")
    stderr.to_s.wont_include("couldn't resolve module/action")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
