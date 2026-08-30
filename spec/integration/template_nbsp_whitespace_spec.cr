require "../spec_helper"

# Runs the compiled binary against a real playbook (real template
# rendering through Crinja's own lexer whitespace handling, vendored
# from the krikri-playbook fork of the crinja shard).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a {{ }} expression whose leading whitespace is a non-ASCII Unicode space" do
  it "renders correctly with a U+00A0 NO-BREAK SPACE right after {{, matching real Ansible" do
    # Real bug found benchmarking buluma.bind's own etc_named.conf.j2:
    # `dnssec-validation {{ bind_dnssec_validation }};` - a U+00A0
    # (NO-BREAK SPACE) right after `{{` instead of a regular space, a
    # common copy/paste artifact in real-world template files. Real
    # ansible-playbook (Python's `re` module, Unicode-mode by default)
    # renders this fine; Crinja's own lexer previously checked a fixed
    # ASCII-only [' ', '\t', '\n', '\r'] whitespace set (Symbol::
    # WHITESPACE), which didn't recognize the NBSP as whitespace-
    # before-token at all, corrupting the expression parse ("Not
    # implemented expression value"). Fixed in the crinja fork
    # (weirdbricks/crinja, tag crystal-play-0.9.14) by switching to
    # Char#whitespace? (Crystal's own Unicode-aware White_Space check).
    src = File.tempname("nbsp-src", ".j2")
    dest = File.tempname("nbsp-dest")
    playbook = File.tempname("nbsp", ".yml")
    File.write(src, "dnssec-validation {{ bind_dnssec_validation }};\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          bind_dnssec_validation: true
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    File.read(dest).should eq("dnssec-validation True;\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
