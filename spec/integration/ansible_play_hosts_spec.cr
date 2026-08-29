require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-two-local-hosts.ini")

describe "ansible_play_hosts / ansible_play_hosts_all magic vars" do
  it "list every host currently in the play, not an empty list" do
    # Real bug found benchmarking xanmanning.k3s (round 158): neither
    # ansible_play_hosts nor ansible_play_hosts_all was populated
    # anywhere at all. The role's own "Ensure ansible_facts['host'] is
    # mapped to inventory_hostname" task (`blockinfile:` with a `{% for
    # host in ansible_play_hosts %}` block, writing a peer-list file
    # used later to look up the cluster's control node) silently
    # iterated ZERO times instead of erroring, so the block content -
    # and the resulting file - ended up empty rather than listing the
    # real hosts. A LATER task's `grep ... <that file>` then failed
    # (no match in an empty file) - while real ansible-playbook, which
    # has always populated this var, succeeded.
    src = File.tempname("play-hosts-src", ".j2")
    dest = File.tempname("play-hosts-dest")
    playbook = File.tempname("play-hosts", ".yml")
    File.write(src, "{% for host in ansible_play_hosts %}HOST:{{ host }}\n{% endfor %}")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
          - name: render_all
            ansible.builtin.debug:
              msg: "{{ ansible_play_hosts_all | join(',') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    rendered = File.read(dest)
    rendered.should_not eq("")
    rendered.lines.count { |l| !l.empty? }.should eq(2)
    output.to_s.should_not contain("msg\": \"\"")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
