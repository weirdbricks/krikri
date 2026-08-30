require "file_utils"
require "../spec_helper"

# `vars_files:` was not implemented at all - the keyword parsed to
# nothing, so every name it should have defined was undefined and the
# task failed. Expectations below come from an ansible-core 2.19.4 run of
# the same playbooks.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_play(playbook : String, files : Hash(String, String))
  dir = File.tempname("vars-files")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  files.each { |name, body| File.write(File.join(dir, name), body) }
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "vars_files:" do
  # Precedence, verified live: a name set in BOTH `vars:` and a vars_file
  # resolves to the FILE's value, and a later file beats an earlier one.
  it "loads files, with later files and files-over-play-vars winning" do
    _, output = run_play(<<-YAML, {"v1.yml" => "a: from_file1\nshared: from_file1\n", "v2.yml" => "b: from_file2\nshared: from_file2\n"})
      - hosts: all
        gather_facts: false
        vars:
          playvar: from_play
          shared: from_play_vars
        vars_files:
          - v1.yml
          - v2.yml
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "a={{ a }} b={{ b }} shared={{ shared }} playvar={{ playvar }}"
      YAML

    output.should contain("a=from_file1")
    output.should contain("b=from_file2")
    output.should contain("shared=from_file2")
    output.should contain("playvar=from_play")
  end

  # A nested list is "first of these that exists".
  it "takes the first existing file of a candidate list" do
    _, output = run_play(<<-YAML, {"alt2.yml" => "alt: from_second\n"})
      - hosts: all
        gather_facts: false
        vars_files:
          - [ missing1.yml, alt2.yml ]
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "alt={{ alt }}"}
      YAML

    output.should contain("alt=from_second")
  end

  # A missing file is tolerated silently by real Ansible (rc=0), not an
  # error - verified.
  it "tolerates a missing file" do
    status, output = run_play(<<-YAML, {} of String => String)
      - hosts: all
        gather_facts: false
        vars_files:
          - nosuchfile.yml
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "RAN"}
      YAML

    status.exit_code.should eq(0)
    output.should contain("RAN")
  end

  # The path may be templated, including against a FACT - which means it
  # cannot be resolved until after gathering, and the per-host cache must
  # not be filled in from the pre-facts pass.
  it "resolves a path templated against a fact" do
    _, output = run_play(<<-YAML, {"vars-#{`. /etc/os-release 2>/dev/null; echo`.strip}.yml" => "", "os-marker.yml" => "os: loaded\n"})
      - hosts: all
        gather_facts: true
        vars_files:
          - "os-{{ 'marker' }}.yml"
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "os={{ os }}"}
      YAML

    output.should contain("os=loaded")
  end
end
