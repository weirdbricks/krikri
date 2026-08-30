require "../spec_helper"

# A YAML syntax error is reported in real ansible-playbook's own shape.
# Each expected block below is the VERBATIM output of a real ansible-core
# 2.19.4 run on the same input - byte-compared, because the point of the
# change was matching it exactly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def syntax_check(content : String)
  playbook = File.tempname("yaml-syntax", ".yml")
  File.write(playbook, content)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "--syntax-check", playbook],
    output: stdout_io, error: stdout_io)
  {status, stdout_io.to_s.gsub(File.expand_path(playbook), "PB")}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "YAML syntax error reporting" do
  # An unquoted value containing ": " - the most common playbook YAML
  # mistake. Real Ansible rewords libyaml's "mapping values are not
  # allowed in this context" and appends a worked example.
  it "matches real Ansible for a colons-in-unquoted-value error" do
    status, output = syntax_check("this: is: bad: [\n")
    status.exit_code.should eq(4)
    output.should eq(<<-OUT + "\n\n")
      [ERROR]: YAML parsing failed: Colons in unquoted values must be followed by a non-space character.
      Origin: PB:1:9

      1 this: is: bad: [
                ^ column 9


      For example:

          raw: echo 'name: ansible'

      Should be:

          raw: "echo 'name: ansible'"
      OUT
  end

  # The reported position is past EOF for an unterminated flow sequence,
  # where real Ansible prints a truncation note instead of a source echo.
  it "matches real Ansible for an unterminated flow sequence" do
    status, output = syntax_check("- name: unclosed\n  hosts: [localhost\n")
    status.exit_code.should eq(4)
    output.should eq(<<-OUT + "\n\n")
      [ERROR]: YAML parsing failed: While parsing a flow sequence did not find expected ',' or ']'.
      Origin: PB:3:1

      (source not shown: file truncated)
      OUT
  end

  # A tab indent: real Ansible substitutes its own hint for libyaml's
  # wording, echoes the PRECEDING line as context, and renders the tab as
  # a single space.
  it "matches real Ansible for a tab-indented line" do
    status, output = syntax_check("- name: tabbed\n\thosts: localhost\n")
    status.exit_code.should eq(4)
    output.should eq(<<-OUT + "\n\n")
      [ERROR]: YAML parsing failed: Tabs are usually invalid in YAML.
      Origin: PB:2:1

      1 - name: tabbed
      2  hosts: localhost
        ^ column 1
      OUT
  end
end
