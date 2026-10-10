require "../minitest_helper"
require "file_utils"

# The controller collection-set awareness refusal, end to end through
# the krikri-playbook binary: a module name the CONTROLLER cannot
# resolve (not an ansible-core module, not redirected anywhere, no
# installed collection providing it) refuses the WHOLE playbook at load
# - rc=4, zero tasks run, no PLAY RECAP, the generic couldn't-resolve
# wording plus the offending task's Origin block on stderr, byte-shape
# verified against ansible-core 2.19.11 on this machine (including the
# [WARNING] line the collection loader prints when the collection
# cannot even be imported).
#
# A name real CAN resolve keeps the existing behavior: an installed
# collection's module krikri hasn't ported skips lazily (round 811000),
# and the `collections:` keyword's listed collections participate in
# resolution.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String, String}
  playbook = File.tempname("collection-awareness", ".yml")
  File.write(playbook, pb)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
  {status, stdout.to_s, stderr.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "controller collection-set awareness refuses unresolvable module names at load" do
  it "refuses a missing-collection FQCN with rc=4, the [WARNING] + [ERROR] + Origin block, and zero tasks" do
    status, stdout, stderr = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: missing coll
            freeipa.ansible_freeipa.ipaclient_setup_nis:
              state: present
      YAML
    status.exit_code.must_equal(4, "stderr:\n#{stderr}")
    # Nothing ran - not even a play banner.
    stdout.must_equal("")
    stderr.must_include("[WARNING]: Error loading plugin 'freeipa.ansible_freeipa.ipaclient_setup_nis': No module named 'ansible_collections.freeipa'")
    stderr.must_include("[ERROR]: couldn't resolve module/action 'freeipa.ansible_freeipa.ipaclient_setup_nis'. This often indicates a misspelling, missing collection, or incorrect module path.")
    stderr.must_include("Origin: ")
    stderr.must_include("- name: missing coll")
    stderr.must_include("^ column 7")
    stderr.wont_include("PLAY RECAP")
  end

  it "refuses a bare name real cannot resolve (docker) with the generic wording and NO warning" do
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
    stdout.must_equal("")
    stderr.wont_include("[WARNING]")
    stderr.must_include("[ERROR]: couldn't resolve module/action 'docker'. This often indicates a misspelling, missing collection, or incorrect module path.")
    stderr.must_include("Origin: ")
  end

  it "refuses a bare name whose builtin redirect dies on an absent collection, warning naming the target" do
    status, stdout, stderr = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: dead redirect
            gc_storage:
              bucket: x
      YAML
    status.exit_code.must_equal(4, "stderr:\n#{stderr}")
    stdout.must_equal("")
    stderr.must_include("[WARNING]: Error loading plugin 'community.google.gc_storage': No module named 'ansible_collections.community.google'")
    stderr.must_include("[ERROR]: couldn't resolve module/action 'gc_storage'. This often indicates a misspelling, missing collection, or incorrect module path.")
  end

  it "refuses an installed collection's missing module file with the [ERROR] + Origin but NO warning" do
    status, stdout, stderr = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: coll installed module missing
            community.docker.not_a_real_module:
              state: present
      YAML
    status.exit_code.must_equal(4, "stderr:\n#{stderr}")
    stdout.must_equal("")
    stderr.wont_include("[WARNING]")
    stderr.must_include("[ERROR]: couldn't resolve module/action 'community.docker.not_a_real_module'. This often indicates a misspelling, missing collection, or incorrect module path.")
  end

  it "keeps a when:-gated task of an INSTALLED collection's unported module on the lazy skip path" do
    # The round-811000 concern is untouched: real CAN resolve
    # kubernetes.core.helm_repository (the collection ships the module
    # file), so the task parses through and skips at run time.
    status, stdout, stderr = run_playbook(<<-YAML)
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

  it "resolves a bare module name through the play's collections: keyword" do
    # community.crypto is installed here and ships x509_certificate.py,
    # so the bare spelling resolves through the keyword list exactly as
    # ansible-core does (a bare spelling without the keyword is refused,
    # no builtin redirect exists for the target name).
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
    # ansible-core folds the ROLE's own meta/main.yml collections:
    # declaration into its bare-name resolution for the role's tasks
    # (live-verified vs 2.19.11); the collection-awareness check honors
    # it too instead of refusing.
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
