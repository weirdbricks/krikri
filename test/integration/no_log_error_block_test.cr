require "file_utils"
require "../minitest_helper"

# Ansible 2.19 prints its [ERROR]: Task failed: block for a failed no_log
# task too - with the raw, uncensored msg (an upstream leak), before the
# censored fatal dump. This engine replicates that block only where the
# msg is one of copy's fixed controller-side required-argument texts,
# which ansible composes itself and so can never carry the secret a
# no_log task is protecting (issue #271); every other failure keeps the
# censored-only fatal line. Shapes captured from ansible-playbook 2.19.11
# (live-verified there: no_log copy with no src/content prints the block
# and the censored fatal, a no_log fail with a data-carrying msg prints
# neither the msg nor any block).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(tasks : String) : String
  scratch = PluginSpecHelper.tmp_path("no-log-error-block")
  FileUtils.mkdir_p(scratch)
  playbook = File.join(scratch, "play.yml")
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n" + tasks)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
  output.to_s
end

# The [ERROR] block must sit between the module's own noise (nothing for
# these failures) and the host's fatal line - ansible's callback emits it
# while rendering the result, before that fatal dump.
private def block_precedes_fatal?(output : String) : Bool
  block_at = output.index("[ERROR]: Task failed:")
  fatal_at = output.index("fatal: [localhost]: FAILED! => {\"censored\"")
  !!(block_at && fatal_at && block_at < fatal_at)
end

describe "failed no_log copy's [ERROR] block" do
  it "prints the block above the censored fatal for copy with no src/content" do
    output = run_playbook(<<-YAML)
          - copy:
              dest: out-no-src
            no_log: true
            ignore_errors: true
    YAML

    output.must_include("[ERROR]: Task failed: Action failed: src (or content) is required")
    output.must_include(%(fatal: [localhost]: FAILED! => {"censored": "the output has been hidden due to the fact that 'no_log: true' was specified for this result", "changed": false}))
    output.must_include("...ignoring")
    block_precedes_fatal?(output).must_equal(true, output)
  end

  it "prints the block for copy's other fixed required-argument texts too" do
    output = run_playbook(<<-YAML)
          - copy:
              src: notes.txt
            no_log: true
            ignore_errors: true
          - copy:
              src: notes.txt
              content: hi
              dest: out-both
            no_log: true
            ignore_errors: true
    YAML

    output.must_include("[ERROR]: Task failed: Action failed: dest is required")
    output.must_include("[ERROR]: Task failed: Action failed: src and content are mutually exclusive")
    output.scan(%(fatal: [localhost]: FAILED! => {"censored": "the output has been hidden due to the fact that 'no_log: true' was specified for this result", "changed": false})).size.must_equal(2)
  end

  it "keeps the block suppressed for a no_log failure with a non-copy message" do
    output = run_playbook(<<-YAML)
          - name: secret fail
            ansible.builtin.debug:
              msg: DANGER_SENTINEL
            failed_when: true
            no_log: true
            ignore_errors: true
    YAML

    output.must_include(%(fatal: [localhost]: FAILED! => {"censored": "the output has been hidden due to the fact that 'no_log: true' was specified for this result", "changed": false}))
    output.wont_include("[ERROR]: Task failed:")
    output.wont_include("DANGER_SENTINEL")
    block_precedes_fatal?(output).must_equal(false)
  end

  # debconf's vtype: password read-back fails on get_bin_path when
  # debconf-get-selections is absent (issue #578): real prints the block
  # before the censored per-item lines, once for the identical items
  # (ErrorBlock dedups them like real's own display dedup does). The
  # plugin shells to the real debconf tools, so a shim PATH holding
  # debconf-show but not debconf-get-selections puts the task on that
  # miss deterministically - the dev box may carry the real
  # debconf-utils and would mask it.
  it "prints the block above the censored loop-item lines for debconf's get_bin_path miss" do
    shim = PluginSpecHelper.tmp_path("debconf-no-log-block-shim")
    FileUtils.mkdir_p(shim)
    File.write(File.join(shim, "debconf-show"), "#!/bin/sh\nprintf '%s\\n' \"spec.pkg/roothost: seeded\"\n")
    File.chmod(File.join(shim, "debconf-show"), 0o755)

    output = run_playbook(<<-YAML)
          - name: seed password
            debconf:
              name: spec.pkg
              question: spec.pkg/roothost
              vtype: password
              value: SECRET_SENTINEL
            no_log: true
            loop:
              - item-a
              - item-b
            environment:
              PATH: #{shim}
    YAML

    block = "[ERROR]: Task failed: Module failed: Failed to find required executable \"debconf-get-selections\" in paths: "
    output.must_include(block)
    output.scan(block).size.must_equal(1)
    output.must_include("Origin: ")
    block_at = output.index(block)
    censored_at = output.index("(item=(censored due to no_log))")
    if block_at && censored_at
      (block_at < censored_at).must_equal(true, output)
    else
      flunk output
    end
    output.scan("(item=(censored due to no_log))").size.must_equal(2)
    output.wont_include("SECRET_SENTINEL")
    output.wont_include("item-a")
  end
end
