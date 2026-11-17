require "../minitest_helper"
require "file_utils"

# `throttle:` is converted by ansible-core's strategy as it QUEUES a task
# for a host - plugins/strategy/__init__.py's
# `int(templar.template(task.throttle))` - and a value its int() refuses
# is an AnsibleError that takes the WHOLE run down: it prints after that
# task's banner, before any host's result, with no PLAY RECAP and rc=1
# (live-verified vs ansible-core 2.21.6). This engine settled the keyword
# at parse time (`to_i? || 0`) and kept going, so a playbook real aborted
# at its first task ran to completion here - issue #1454's
# `throttle: kpg-many`.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The binary's streams plus the playbook's own (now deleted) path, which
# the stderr Origin line carries - the file itself is gone by the time
# the assertions run, so only its text matters.
private def run_throttle_playbook(body : String, env : Hash(String, String)? = nil) : {Int32, String, String, String}
  dir = File.tempname("throttle").tap { |path| Dir.mkdir(path) }
  playbook = File.join(dir, "pb.yml")
  File.write(playbook, body)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr, chdir: dir, env: env)
  {status.exit_code, stdout.to_s, stderr.to_s, File.expand_path(playbook)}
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "throttle:" do
  it "aborts at the first task on a non-integer play-level throttle, like ansible" do
    code, stdout, stderr, path = run_throttle_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        throttle: kpg-many
        tasks:
          - name: one
            ansible.builtin.debug:
              msg: one
          - name: two
            ansible.builtin.debug:
              msg: two
      YAML

    code.must_equal 1
    # Real banners the task it was queueing and then dies: the first
    # task's result, the second task and the recap never print.
    stdout.must_include "TASK [one]"
    stdout.wont_include "ok:"
    stdout.wont_include "TASK [two]"
    stdout.wont_include "PLAY RECAP"
    stderr.must_include "Failed to convert the throttle value to an integer: " \
                        "invalid literal for int() with base 10: 'kpg-many'"
    stderr.must_include "Origin: #{path}:3:13"
    stderr.must_include "3   throttle: kpg-many"
    stderr.must_include "^ column 13"
  end

  it "aborts after the earlier tasks on a non-integer task-level throttle" do
    code, stdout, stderr, path = run_throttle_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: one
            ansible.builtin.debug:
              msg: one
          - name: two
            ansible.builtin.debug:
              msg: two
            throttle: kpg-many
      YAML

    code.must_equal 1
    stdout.must_include %("msg": "one")
    stdout.must_include "TASK [two]"
    stdout.wont_include "PLAY RECAP"
    stderr.must_include "invalid literal for int() with base 10: 'kpg-many'"
    stderr.must_include "Origin: #{path}:10:17"
  end

  it "aborts a block's inherited throttle at its first nested task" do
    code, stdout, stderr, path = run_throttle_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        throttle: 2
        tasks:
          - block:
              - name: inner
                ansible.builtin.debug:
                  msg: hi
            throttle: kpg-many
      YAML

    code.must_equal 1
    stdout.must_include "TASK [inner]"
    stdout.wont_include "ok:"
    stdout.wont_include "PLAY RECAP"
    # The block's own value wins over the play's, so the Origin points at
    # the block's throttle: line.
    stderr.must_include "Origin: #{path}:9:17"
  end

  it "keeps running when a templated throttle renders to an integer" do
    code, stdout, _stderr, _path = run_throttle_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        throttle: "{{ 2 }}"
        tasks:
          - name: one
            ansible.builtin.debug:
              msg: one
          - name: two
            ansible.builtin.debug:
              msg: two
            throttle: 1
      YAML

    code.must_equal 0
    stdout.must_include %("msg": "two")
    stdout.must_include "ok=2"
  end

  it "reports an undefined throttle variable with the renderer's own message" do
    code, _stdout, stderr, path = run_throttle_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        throttle: "{{ nope }}"
        tasks:
          - name: one
            ansible.builtin.debug:
              msg: one
      YAML

    code.must_equal 1
    stderr.must_include "Failed to convert the throttle value to an integer: 'nope' is undefined"
    stderr.must_include "Origin: #{path}:3:13"
  end

  # The implicit Gathering Facts task is queued before any regular task,
  # so a play-level throttle kills the run at ITS banner instead.
  it "aborts at the implicit Gathering Facts task for a play-level throttle" do
    code, stdout, stderr, path = run_throttle_playbook(<<-YAML, env: {"ANSIBLE_GATHERING" => "implicit"})
      - hosts: localhost
        connection: local
        throttle: kpg-many
        tasks:
          - name: one
            ansible.builtin.debug:
              msg: one
      YAML

    code.must_equal 1
    stdout.must_include "TASK [Gathering Facts]"
    stdout.wont_include "ok:"
    stdout.wont_include "PLAY RECAP"
    stderr.must_include "Origin: #{path}:3:13"
  end
end
