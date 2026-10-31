require "../minitest_helper"

# Issue #409 (amritsingh.eye): a free-form command:/shell: task whose
# `args:` dict also templates - two parity gaps, live-captured vs
# ansible-core 2.19.11 on the role's `quit eye` / `ensure eye loads the
# config` tasks:
#
# 1. Ansible stores the free string in the task's args dict under
#    `_raw_params`, so with BOTH the free string and `chdir:` undefined
#    the alphabetical finalization order reports `_raw_params` first.
#    krikri stores the string under `cmd` (which sorts after `chdir`)
#    and reported the wrong key/variable.
# 2. The innermost Origin for a NAMED key's failure is that key's own
#    value position in the `args:` block - not the module key's line,
#    which only carries the free string's own failure.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "free-form command task finalization errors with a templated args: dict" do
  it "reports _raw_params before chdir and points a named key's Origin at its own line" do
    src_dir = PluginSpecHelper.tmp_path("free-form-finalization-origin", "role")
    Dir.mkdir_p(File.join(src_dir, "roles", "eyetest", "tasks"))
    tasks = File.join(src_dir, "roles", "eyetest", "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      ---
      - name: quit eye
        command: bash -lc "bundle exec eye quit -s"
        args:
          chdir: "{{ app_path }}"
        become: no
        ignore_errors: True

      - name: ensure eye loads the config
        command: bash -lc "bundle exec eye l {{ eye_config_path }}"
        args:
          chdir: "{{ app_path }}"
        become: no
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - eyetest
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    # Both undefined args exist on the second task; Ansible's alphabetical
    # finalization order names `_raw_params` (the free string's key)
    # before `chdir`, so the reported key/variable is the free string's.
    text.must_include("Error while resolving value for '_raw_params': 'eye_config_path' is undefined")
    # ...and its Origin is the free string's own position on the module
    # key's line (the quote of the command string, line 10 column 12).
    text.must_include("Error while resolving value for '_raw_params': 'eye_config_path' is undefined\nOrigin: #{tasks}:10:12")

    # The first task only has `chdir` undefined: the named key's innermost
    # Origin is the `chdir:` value token in the args: block (line 5,
    # column 12), not the module key's line.
    text.must_include("Error while resolving value for 'chdir': 'app_path' is undefined\nOrigin: #{tasks}:5:12")
  end
end
