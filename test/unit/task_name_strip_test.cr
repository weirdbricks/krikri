require "../minitest_helper"

# Real ansible-playbook strips the displayed task name at BOTH ends
# before printing the TASK banner (probed against 2.19.11 - do not
# re-derive): `name: "configure daemon "` prints `TASK [configure
# daemon]`, `name: "  lead and trail  "` prints `TASK [lead and
# trail]`, and a template that renders to whitespace at either end is
# trimmed the same way (`"{{ v }} lead tmpl"` with v="" -> `TASK [lead
# tmpl]`, `"Install thing {{ v }}"` with v="" -> `TASK [Install
# thing]`). krikri printed the raw name verbatim, so a trailing space
# showed up in the banner and diverged byte for byte (issue #87).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_binary(pb : String) : {Process::Status, String, String}
  playbook = File.tempname("name-strip", ".yml")
  File.write(playbook, pb)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: out_io, error: err_io)
  {status, out_io.to_s, err_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "TASK banner name whitespace stripping (issue #87)" do
  it "strips a literal trailing space from the banner name" do
    status, stdout, _stderr = run_playbook_binary(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: "configure daemon "
            ansible.builtin.debug: msg=hi
      YAML
    status.exit_code.must_equal(0, "stdout:\n#{stdout}\nstderr:\n#{_stderr}")
    stdout.must_include("TASK [configure daemon]")
    # The banner pads stars right after the closing bracket, so real's
    # trim means no space can survive between the name and `]`.
    stdout.wont_include("daemon ]")
  end

  it "strips leading and trailing spaces from a literal banner name" do
    status, stdout, _stderr = run_playbook_binary(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: "  lead and trail  "
            ansible.builtin.debug: msg=hi
      YAML
    status.exit_code.must_equal(0, "stdout:\n#{stdout}\nstderr:\n#{_stderr}")
    stdout.must_include("TASK [lead and trail]")
    stdout.wont_include("TASK [  lead and trail")
    stdout.wont_include("TASK [lead and trail ]")
  end

  it "strips a templated name whose variable renders empty at the end" do
    status, stdout, _stderr = run_playbook_binary(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          v: ""
        tasks:
          - name: "Install thing {{ v }}"
            ansible.builtin.debug: msg=hi
      YAML
    status.exit_code.must_equal(0, "stdout:\n#{stdout}\nstderr:\n#{_stderr}")
    stdout.must_include("TASK [Install thing]")
    stdout.wont_include("TASK [Install thing ]")
  end

  it "strips a templated name whose variable renders empty at the start" do
    status, stdout, _stderr = run_playbook_binary(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          v: ""
        tasks:
          - name: "{{ v }} lead tmpl"
            ansible.builtin.debug: msg=hi
      YAML
    status.exit_code.must_equal(0, "stdout:\n#{stdout}\nstderr:\n#{_stderr}")
    stdout.must_include("TASK [lead tmpl]")
    stdout.wont_include("TASK [ lead tmpl]")
  end
end
