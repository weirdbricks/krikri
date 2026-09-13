require "../spec_helper"

# Regression spec for the ad-hoc CLI sweep (2026-09-13): with zero fact
# gathering, krikri resolved `ansible_hostname` to the inventory host name
# ("localhost"), so `ansible_hostname | default(...)` - the idiomatic
# "have facts been gathered yet" guard - silently produced the wrong value.
# Real Ansible leaves ansible_hostname undefined until setup/gather_facts
# populates it (verified live against ansible-core 2.19: the template below
# renders "host=x" without facts, the real hostname after them).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def render_with(gather_facts : String) : String
  src = File.tempname("hostname-fact-src", ".j2")
  dest = File.tempname("hostname-fact-dest")
  playbook = File.tempname("hostname-fact", ".yml")
  File.write(src, "host={{ ansible_hostname | default('x') }}\n")

  begin
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: #{gather_facts}
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    raise "playbook run failed:\n#{output}" unless status.success?
    File.read(dest)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end

describe "ansible_hostname without gathered facts" do
  it "stays undefined before fact gathering, so default() fires" do
    render_with("false").should eq("host=x\n")
  end

  it "resolves to the real hostname after gather_facts" do
    rendered = render_with("true")
    rendered.should eq("host=#{`hostname`.strip}\n")
  end
end
