require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against real playbooks, since the bug is in
# the executor's controller-side with_subelements: source resolution
# (resolve_loop_subelements), not reachable from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real bug found via a live 100-role confirm round: GROG.authorized-key's
# own idiom - `with_subelements: - "{{ authorized_key_list_all |
# selectattr('authorized_keys', 'defined') | list }}" - authorized_keys`
# - failed with "'item' is undefined" on an empty source list instead of
# correctly skipping (Ansible: skipped=1). resolve_template_value
# only understands a bare/dotted variable reference; a filter chain
# doesn't match its regex and returned nil immediately - not because
# the list was empty, but because it was never evaluated - which fell
# out of the whole loop-resolver chain, so the task wasn't treated as a
# loop at all and ran once with `item` unbound.
describe "with_subelements: with a filter-chain source" do
  it "skips (not fails) when the filtered source list is empty" do
    playbook = File.tempname("with-subelements-empty", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mylist: []
        tasks:
          - name: manage
            ansible.builtin.debug:
              msg: "item={{ item }}"
            with_subelements:
              - "{{ mylist | selectattr('authorized_keys', 'defined') | list }}"
              - authorized_keys
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("skipping: [localhost]")
    output.to_s.must_match(/skipped=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "iterates parent/subelement pairs correctly when the filtered source list is non-empty" do
    playbook = File.tempname("with-subelements-nonempty", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mylist:
            - name: foo
              authorized_keys:
                - key: "ssh-rsa AAA"
        tasks:
          - name: manage
            ansible.builtin.debug:
              msg: "parent={{ item.0.name }} key={{ item.1.key }}"
            with_subelements:
              - "{{ mylist | selectattr('authorized_keys', 'defined') | list }}"
              - authorized_keys
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("parent=foo key=ssh-rsa AAA")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# ansible-core's subelements lookup accepts "a dict or a list" as its first
# term and converts a dict to the list of its VALUES (subelements.py:
# `for key in terms[0]: elementlist.append(terms[0][key])`). krikri's
# bare-variable path only read the array shape, so it resolved to zero
# items and skipped the task whole - Turgon37.bind's `with_subelements: -
# "{{ bind__zones }}" - entries` over its name -> zone-config mapping
# (issue #1018: Ansible asserted 9 times, krikri `skipping`). The source
# below is the role's own shape: a dict default built by combining dicts.
describe "with_subelements: dict source" do
  it "iterates the dict's values, one pair per subelement" do
    playbook = File.tempname("with-subelements-dict", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          zones_default:
            localhost:
              type: master
              entries:
                - {name: '@', type: NS}
                - {name: '@', type: A}
            '127.in-addr.arpa':
              type: master
              entries:
                - {name: '@', type: NS}
          zones_extra: {}
          zones: '{{ zones_default | combine(zones_extra) }}'
        tasks:
          - name: manage
            ansible.builtin.debug:
              msg: "parent={{ item.0 | to_json }} entry={{ item.1.name }}"
            with_subelements:
              - '{{ zones }}'
              - entries
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.wont_include("skipping: [localhost]")
    # one item per subelement across both zone configs (2 + 1), not zero
    output.to_s.scan("ok: [localhost] => (item=[").size.must_equal(3)
    # item.0 is the parent zone config, with its subelement key removed
    output.to_s.must_include(%(parent={\\"type\\": \\"master\\"} entry=@))
    output.to_s.wont_include("skipped=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# ansible-core's subelements lookup hands the task a parent COPY with
# the subelement key REMOVED (live-verified against 2.19.11:
# `msg="{{ item.0 | to_json }}"` over {"name": "s1", "kids": [...]} prints
# the msg string `parent={"name": "s1"}`, JSON-escaped by the callback). krikri used to hand the full parent dict through, so
# item.0 exposed the whole raw subelement list where Ansible never
# shows it.
describe "with_subelements: parent dict shape" do
  it "hands item.0 a copy with the subelement key removed" do
    playbook = File.tempname("with-subelements-parent", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mylist: [{"name": "s1", "kids": ["i1", "i2"]}]
        tasks:
          - name: manage
            ansible.builtin.debug:
              msg: "parent={{ item.0 | to_json }}"
            with_subelements:
              - "{{ mylist }}"
              - kids
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    # The debug callback JSON-escapes the msg value (ansible-core
    # 2.19.11 prints `"msg": "parent={\"name\": \"s1\"}"` - the to_json
    # quotes are escaped INSIDE the msg string), so the expected substring
    # carries the backslashes. %-literals process \\ escapes, hence the
    # doubled backslashes here.
    output.to_s.must_include(%(parent={\\"name\\": \\"s1\\"}))
    output.to_s.wont_include("kids")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
