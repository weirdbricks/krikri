require "../spec_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_loop_flattened, a private method not reachable
# from a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("with-flattened-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "with_community.general.flattened:" do
  it "keeps literal string sources, not just a templated {{ var }} source" do
    # Real bug found regression-testing geerlingguy... no, found running
    # dev-sec.os-hardening's own "find files with write-permissions for
    # group" task: `with_flattened: ['/usr/local/sbin', '/usr/local/bin',
    # ..., "{{ os_env_extra_user_paths }}"]` (os_env_extra_user_paths
    # defaults to `[]`). #resolve_loop_flattened's own #resolve_template_
    # value only understands a bare `{{ var }}` reference - for every
    # literal path string (not template-shaped at all) it returned nil,
    # and `next unless value` silently DROPPED the literal source
    # entirely instead of contributing it as one item. The whole loop
    # produced ZERO items instead of the literal paths, and the task
    # (which real ansible-playbook runs against all 6 real directories)
    # failed outright with "find: 'undefined': No such file or
    # directory" - LoopResolver's own (dead, never-called) with_flattened
    # module method got this right, misleadingly making the bug look
    # already-fixed on a first read of the code.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          extra_paths: []
        tasks:
          - name: flattened loop
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_community.general.flattened:
              - '/usr/local/sbin'
              - '/usr/local/bin'
              - "{{ extra_paths }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 2
                - result.results[0].msg == "/usr/local/sbin"
                - result.results[1].msg == "/usr/local/bin"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "recognizes the with_flattened: short alias, not just the FQCN form" do
    # Real bug found on the SAME dev-sec.os-hardening task as the one
    # above - the role actually writes the short lookup-plugin-name
    # alias `with_flattened:`, not the FQCN `with_community.general.
    # flattened:` this spec file's other example uses. The parser only
    # ever recognized the FQCN spelling (in both the loop_flattened
    # extraction AND the special_keys allowlist that decides "is this a
    # loop keyword or the module name") - `with_flattened:` fell through
    # entirely unrecognized, so the task ran exactly ONCE, not looped at
    # all, with `item` completely unbound (`{{ item }}` rendered the
    # literal string "undefined").
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          extra_paths: []
        tasks:
          - name: flattened loop
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_flattened:
              - '/usr/local/sbin'
              - '/usr/local/bin'
              - "{{ extra_paths }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 2
                - result.results[0].msg == "/usr/local/sbin"
                - result.results[1].msg == "/usr/local/bin"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "evaluates a filter-chain source, not just a bare {{ var }} reference" do
    # Real bug found on a SIBLING dev-sec.os-hardening task: "change
    # system accounts not on the user provided ignore-list" writes
    # `with_flattened: - '{{ sys_accs_cond | default([]) |
    # difference(os_ignore_users) | list }}'` - a filter chain, not a
    # bare variable. #resolve_template_value only understands a bare
    # `{{ var }}`/`{{ var.dotted }}` shape, so it returned nil, and
    # (even after the literal-source fix above) the whole filter-chain
    # TEXT got substituted and pushed as ONE STRING item instead of
    # being evaluated and flattened - `user: name={{ item }}` then
    # tried to useradd a single literal string containing every
    # username joined by commas inside brackets, which real useradd
    # rejects outright as an invalid username.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          sys_accs_cond: ["a", "b", "c", "d"]
          os_ignore_users: ["b"]
        tasks:
          - name: filter-chain flattened source
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_flattened:
              - '{{ sys_accs_cond | default([]) | difference(os_ignore_users) | list }}'
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 3
                - result.results[0].msg == "a"
                - result.results[1].msg == "c"
                - result.results[2].msg == "d"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "still flattens a non-empty templated list source into the result (no regression)" do
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          extra_paths: ["/opt/a", "/opt/b"]
        tasks:
          - name: flattened loop
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_community.general.flattened:
              - '/usr/local/sbin'
              - "{{ extra_paths }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 3
                - result.results[0].msg == "/usr/local/sbin"
                - result.results[1].msg == "/opt/a"
                - result.results[2].msg == "/opt/b"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end
end
