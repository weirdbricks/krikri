require "../minitest_helper"
require "file_utils"

# An until:/retries: task that runs out of retries on a module that
# SUCCEEDED is the retry runner's own failure, not a module failure: real
# ansible-core 2.21 registers changed/failed/msg/attempts and NO
# `exception` (live-verified with `command: /bin/true` and with `debug:`),
# while an until on a FAILING module still carries the controller's
# `exception: "(traceback unavailable)"` placeholder. krikri used to add the
# placeholder to both.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "until retries exhausted on a successful module" do
  it "registers attempts without the controller exception placeholder" do
    tempdir = File.tempname("until-success-exhausted").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - command: /bin/true
            until: false
            retries: 2
            delay: 0
            register: c
            ignore_errors: true
          - debug:
              msg: "KEYS={{ c.keys() | list }}"
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include(%(KEYS=['changed', 'failed', 'msg', 'rc', 'attempts'))
    text.wont_include("'exception'")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "keeps the exception placeholder when the module itself failed" do
    tempdir = File.tempname("until-failure-exhausted").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - command: /bin/false
            until: false
            retries: 2
            delay: 0
            register: c
            ignore_errors: true
          - debug:
              msg: "KEYS={{ c.keys() | list }}"
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include(%(KEYS=['changed', 'failed', 'exception', 'msg', 'rc', 'attempts'))
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
