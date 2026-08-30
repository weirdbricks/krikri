require "../spec_helper"

# Runs the compiled binary against a real playbook (real .j2 template
# rendering via CrinjaRenderer/TemplateActionPlugin), since this bug is
# specifically about the vendored Crinja fork's evaluator, not the
# hand-rolled plain {{ }} evaluator.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a real Jinja2 default() fallback that chains through an undefined value" do
  it "doesn't crash the whole template render when the fallback branch is never actually needed" do
    # Real bug found benchmarking robertdebock.haproxy (round 41,
    # krikri-playbook 0.9.386 / crinja crystal-play-0.9.8). Its own
    # haproxy.cfg.j2 template has `server.address | default(hostvars
    # [server.name]['ansible_facts']['default_ipv4']['address'])` -
    # server.address is defined, so the hostvars(...) fallback chain
    # (walking through 'web1', a backend-server label, not a real
    # inventory host) is never supposed to matter. Crinja's evaluator
    # used to raise as soon as ANY link in a MemberExpression/
    # IndexExpression chain hit an undefined base - even inside a
    # default() fallback that never got used - crashing the entire
    # template render instead of just quietly discarding the unused
    # fallback value, unlike real ansible-playbook. See crinja's
    # PATCHES.md 0.9.8 entry for the fix (chained access on an
    # undefined base now self-propagates as Undefined instead of
    # raising, matching real Ansible's own Marker class).
    src = File.tempname("undefined-chain-default-src", ".j2")
    dest = File.tempname("undefined-chain-default-dest")
    playbook = File.tempname("undefined-chain-default", ".yml")
    File.write(src, "server {{ server.address | default(hostvars[server.name]['ansible_facts']['default_ipv4']['address']) }}\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          server:
            name: web1
            address: 127.0.0.1
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    File.read(dest).should eq("server 127.0.0.1\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
