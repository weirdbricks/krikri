require "../minitest_helper"

# Runs the compiled binary against a real playbook (real .j2 template
# rendering via TemplateActionPlugin's krikri-jinja engine), like
# template_undefined_chain_default_test.cr, because the bug lives in the
# full defer-walk -> engine-scope path, not in one evaluator.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Rounds 5300003 (wasilak.centos-hashiui) / 5300004
# (SathiyarajPeriyannan.vsphere): a variable whose own value is itself a
# template referencing a name set nowhere (`server_ip: "{{ bind_addr }}"`)
# used to survive the template action plugin's lazy re-render walk as raw
# `{{ bind_addr }}` text - the walk defers it (so a template that never
# reads it keeps working, the round-952484 laziness), but the eagerly-built
# engine scope then held the raw TEMPLATE TEXT as an ordinary string, and a
# template that actually read the variable rendered that text verbatim into
# the destination file with rc=0. ansible-core 2.19.11 hands the template
# engine an undefined value for such a chain instead: touching it fails the
# task with the chain's innermost message, `is defined` is False, and a
# `default()` fallback answers. Live-verified against 2.19.11 for every
# expectation below, not assumed.
describe "a .j2 reading a var whose chain bottoms out at an undefined name" do
  it "fails the task with the innermost message instead of rendering the raw text" do
    src = File.tempname("undef-chain-fail-src", ".j2")
    dest = File.tempname("undef-chain-fail-dest")
    playbook = File.tempname("undef-chain-fail", ".yml")
    File.write(src, "BindAddress {{ server_ip }}\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          server_ip: "{{ bind_addr }}"
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # Real's wording, naming the CHAIN'S innermost missing name, not the
    # var the template referenced ('server_ip' would be wrong: it IS
    # defined, its value just cannot resolve).
    output.to_s.must_include("'bind_addr' is undefined")
    # The silent-corruption shape: render failure means no file at all,
    # not a destination quietly holding the raw template text.
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "keeps Ansible's laziness semantics for the untouched consumers (is defined False, default fallback, defined sibling)" do
    # Live-verified against ansible-core 2.19.11 running the same
    # template: def=False / dflt=[fallback] / attrs=['present'].
    src = File.tempname("undef-chain-lazy-src", ".j2")
    dest = File.tempname("undef-chain-lazy-dest")
    playbook = File.tempname("undef-chain-lazy", ".yml")
    File.write(src, <<-J2)
      def={{ chain is defined }}
      dflt=[{{ chain | default('fallback') }}]
      exe={{ reachable }}
      untouched_named={{ list_of_things | selectattr('name', 'defined') | map(attribute='name') | list }}
      J2

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          reachable: present
          chain: "{{ missing_chain }}"
          list_of_things:
            - name: "{{ other_chain }}"
            - name: wright
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    # The render's own trailing-newline convention (see render_once) rides
    # the file, so the squiggly heredoc needs the "\n" appended.
    File.read(dest).must_equal(<<-OUT + "\n")
      def=False
      dflt=[fallback]
      exe=present
      untouched_named=['wright']
      OUT

  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "prints real's two-link [ERROR] chain (var-definition Origin) plus the prefixed fatal msg" do
    src = File.tempname("undef-chain-twolink-src", ".j2")
    dest = File.tempname("undef-chain-twolink-dest")
    playbook = File.tempname("undef-chain-twolink", ".yml")
    File.write(src, "BindAddress {{ server_ip }}\n")

    # Live-verified against ansible-core 2.19.11 byte for byte (same
    # shape as /tmp/repro-fixes/repro_bind_chain.yml): the [ERROR] block
    # is TWO chain links with the var's DEFINITION as the second Origin
    # ("Task failed." + task Origin, then "<<< caused by >>>" + the bare
    # innermost wording + the definition's file:line:col with its code
    # frame), and the fatal msg keeps the "Task failed: " prefix no
    # "Failed to render template" wrapper exists anywhere.
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          server_ip: "{{ bind_addr }}"
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.exit_code.must_equal(2)
    text = output.to_s
    text.must_include("[ERROR]: Task failed: 'bind_addr' is undefined")
    text.must_include("<<< caused by >>>")
    # The second link's Origin is the DEFINITION whose rendered value
    # fails, with its code frame and caret at the value token.
    text.must_include("'bind_addr' is undefined\nOrigin: #{playbook}:6:16")
    text.must_include("4   connection: local\n5   vars:\n6     server_ip: \"{{ bind_addr }}\"\n                 ^ column 16")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: 'bind_addr' is undefined"}))
    text.wont_include("Failed to render template")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "keeps the template file as the second link's Origin when the name has no definition" do
    src = File.tempname("undef-chain-bare-src", ".j2")
    dest = File.tempname("undef-chain-bare-dest")
    playbook = File.tempname("undef-chain-bare", ".yml")
    # Live-verified against 2.19.11 byte for byte: with no definition to
    # point at, real keeps the two links but the second Origin is the
    # TEMPLATE file (path only, no line/column, no frame).
    File.write(src, "{% for ns in missing_nameservers %}\n{% endfor %}\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.exit_code.must_equal(2)
    text = output.to_s
    text.must_include("[ERROR]: Task failed: 'missing_nameservers' is undefined")
    text.must_include("<<< caused by >>>")
    text.must_include("'missing_nameservers' is undefined\nOrigin: #{src}\n")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: 'missing_nameservers' is undefined"}))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
