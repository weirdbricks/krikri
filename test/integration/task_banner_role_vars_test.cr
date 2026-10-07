require "../minitest_helper"
require "file_utils"

# Two cosmetic TASK-banner divergences from round 2300xxx, both
# live-compared against ansible-core 2.19.11:
#
# - andrewrothstein.nats (2300765): a task name over a var whose own
#   value is unrendered Jinja must render chunk-wise at EVERY recursion
#   level - each failing sub-expression becomes its own numbered
#   `<< error N - msg >>` marker and resolvable literals/siblings
#   survive, instead of one collapsed marker for the whole span.
# - andrewrothstein.zookeeper-cluster (2300431): a task inside a
#   block's `always:` whose banner is printed by the block-skipped
#   path (the block's when: false) lost the role's invocation vars
#   (a meta/main.yml dependency's own args) in its templated name -
#   execute_block's skip path propagated role context to block:
#   children only, never to always: children.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task banner templating" do
  it "annotates each failing sub-expression of a nested template var separately (nats)" do
    src_dir = File.tempname("name-marker-recursion")
    Dir.mkdir_p(File.join(src_dir, "roles", "nr", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "nr", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "nr", "defaults"))
    File.write(File.join(src_dir, "roles", "nr", "defaults", "main.yml"), <<-YAML)
      nats_parent_install_dir: /usr/local
      YAML
    File.write(File.join(src_dir, "roles", "nr", "vars", "main.yml"), <<-YAML)
      nats_name: '{{ nats_app }}-{{ nats_ver }}-{{ nats_platform }}'
      nats_platform: linux-amd64
      nats_install_dir: '{{ nats_parent_install_dir }}/{{ nats_name }}'
      YAML
    File.write(File.join(src_dir, "roles", "nr", "tasks", "main.yml"), <<-YAML)
      - name: Look for nats app install in {{ nats_install_dir }}
        ansible.builtin.stat:
          path: '{{ nats_install_dir }}'
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - nr
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    # The task itself still fails (nats_app is genuinely undefined, the
    # stat path finalization fails in real too) - only the banner shape
    # is under test here, byte-identical to real 2.19.11's:
    #   Look for nats app install in /usr/local/<< error 1 - 'nats_app'
    #   is undefined >>-<< error 2 - 'nats_ver' is undefined >>-linux-amd64
    output.to_s.must_include("TASK [nr : Look for nats app install in /usr/local/<< error 1 - 'nats_app' is undefined >>-<< error 2 - 'nats_ver' is undefined >>-linux-amd64]")
    output.to_s.wont_include("Look for nats app install in << error")
    status.success?.must_equal(false)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "keeps role invocation vars in a skipped always: child's banner (zookeeper-cluster)" do
    src_dir = File.tempname("skipped-always-role-vars")
    Dir.mkdir_p(File.join(src_dir, "roles", "top", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "top", "meta"))
    Dir.mkdir_p(File.join(src_dir, "roles", "mid", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "mid", "defaults"))
    File.write(File.join(src_dir, "roles", "top", "meta", "main.yml"), <<-YAML)
      dependencies:
        - role: mid
          vars:
            myparam: jre
      YAML
    File.write(File.join(src_dir, "roles", "top", "tasks", "main.yml"), <<-YAML)
      - name: top task
        ansible.builtin.debug:
          msg: top ran
      YAML
    File.write(File.join(src_dir, "roles", "mid", "defaults", "main.yml"), <<-YAML)
      mydefault: defval
      YAML
    File.write(File.join(src_dir, "roles", "mid", "tasks", "main.yml"), <<-YAML)
      - when: run_block
        block:
          - name: block task with {{ myparam }}
            ansible.builtin.debug:
              msg: block
        always:
          - name: deleting /tmp/{{ myparam }}-{{ mydefault }}...
            ansible.builtin.debug:
              msg: always
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          run_block: false
        roles:
          - top
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    # Byte-identical to real 2.19.11's skipped-banner shape: the
    # dependency arg AND the role default both render in the always:
    # child's name (round 2300431: the dep arg collapsed to
    # `<< error 1 - 'openjdk_app' is undefined >>`).
    output.to_s.must_include("TASK [mid : deleting /tmp/jre-defval...]")
    output.to_s.must_include("TASK [mid : block task with jre]")
    output.to_s.wont_include("<< error")
    output.to_s.must_include("skipping: [localhost]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
