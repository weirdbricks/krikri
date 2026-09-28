require "../minitest_helper"
require "file_utils"

# Facts set by a HANDLER (set_fact:, or a fact derived inside one) must be
# visible to everything that runs after the handler has executed - tasks
# after a meta: flush_handlers, the next play, handlers later in the same
# flush, and consumers of a looped handler's per-item facts - exactly like
# real ansible-core. The handler dispatch path (#execute_handler_plugin_
# once) returned the raw plugin result without merging the action plugin's
# "ansible_facts" payload into the executor's fact stores, so every one of
# these consumers saw the fact as undefined while real ansible-playbook
# kept it visible (a handler's register: already worked - that path shared
# the regular tasks' register_result).
#
# Every example here was live-verified against ansible-core 2.19.11
# (localhost, ansible_connection=local) before being pinned.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("handler-facts", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Builds a temp playbook dir containing a two-file role whose handler sets
# a fact, so the role-handler variants (static roles: and include_role:)
# can run against a real role layout.
private def with_role(role_handlers : String, &block : String -> Nil) : Nil
  dir = File.tempname("handler-facts-role")
  FileUtils.mkdir_p(File.join(dir, "roles", "factrole", "handlers"))
  FileUtils.mkdir_p(File.join(dir, "roles", "factrole", "tasks"))
  File.write(File.join(dir, "roles", "factrole", "handlers", "main.yml"), role_handlers)
  File.write(File.join(dir, "roles", "factrole", "tasks", "main.yml"), "- ansible.builtin.command: /bin/true\n")
  block.call(dir)
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "facts set by a handler" do
  it "are visible to tasks after a meta: flush_handlers (debug + type_debug + when:)" do
    status, output = run_playbook(<<-YAML)
      - name: flush set_fact
        hosts: localhost
        gather_facts: false
        handlers:
          - name: h1
            ansible.builtin.set_fact:
              hfact: from-handler
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            notify: h1
          - name: flush
            ansible.builtin.meta: flush_handlers
          - name: read it
            ansible.builtin.debug:
              msg: "fact={{ hfact | default('MISSING') }} type={{ hfact | default('MISSING') | type_debug }}"
            when: hfact is defined
      YAML

    status.success?.must_equal(true, output)
    output.must_include("fact=from-handler type=str", output)
    output.wont_include("MISSING", output)
    output.wont_include("skipping: [localhost]", output)
  end

  it "leave a handler's register: result visible to a later task" do
    status, output = run_playbook(<<-YAML)
      - name: handler register
        hosts: localhost
        gather_facts: false
        handlers:
          - name: hreg
            ansible.builtin.command: /bin/echo hello
            register: hres
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            notify: hreg
          - name: flush
            ansible.builtin.meta: flush_handlers
          - name: read it
            ansible.builtin.debug:
              msg: "reg={{ hres.stdout | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("reg=hello", output)
  end

  it "are visible to the NEXT PLAY (direct reference and hostvars)" do
    status, output = run_playbook(<<-YAML)
      - name: play one
        hosts: localhost
        gather_facts: false
        handlers:
          - name: h2
            ansible.builtin.set_fact:
              pfact: play1-handler
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            notify: h2
      - name: play two
        hosts: localhost
        gather_facts: false
        tasks:
          - name: read it
            ansible.builtin.debug:
              msg: "direct={{ pfact | default('MISSING') }} hostvars={{ hostvars['localhost']['pfact'] | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("direct=play1-handler hostvars=play1-handler", output)
    output.wont_include("MISSING", output)
  end

  it "are visible to a LATER handler in the same flush" do
    status, output = run_playbook(<<-YAML)
      - name: handler reads handler fact
        hosts: localhost
        gather_facts: false
        handlers:
          - name: setter
            ansible.builtin.set_fact:
              chainfact: chained
          - name: reader
            ansible.builtin.debug:
              msg: "reader saw {{ chainfact | default('MISSING') }}"
        tasks:
          - name: trigger both
            ansible.builtin.command: /bin/true
            notify:
              - setter
              - reader
          - name: flush
            ansible.builtin.meta: flush_handlers
      YAML

    status.success?.must_equal(true, output)
    output.must_include("reader saw chained", output)
  end

  it "set at the implicit END-OF-PLAY flush are visible to the next play" do
    status, output = run_playbook(<<-YAML)
      - name: play one
        hosts: localhost
        gather_facts: false
        handlers:
          - name: h3
            ansible.builtin.set_fact:
              eofact: end-of-play
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            notify: h3
      - name: play two
        hosts: localhost
        gather_facts: false
        tasks:
          - name: read it
            ansible.builtin.debug:
              msg: "eofact={{ eofact | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("eofact=end-of-play", output)
    output.wont_include("MISSING", output)
  end

  it "set by a role's handler are visible after the flush" do
    with_role("- name: rh\n  ansible.builtin.set_fact:\n    rolefact: from-role-handler\n") do |dir|
      playbook = File.join(dir, "site.yml")
      File.write(playbook, <<-YAML)
        - name: role handler fact
          hosts: localhost
          gather_facts: false
          roles:
            - role: factrole
          tasks:
            - name: trigger
              ansible.builtin.command: /bin/true
              notify: rh
            - name: flush
              ansible.builtin.meta: flush_handlers
            - name: read it
              ansible.builtin.debug:
                msg: "rolefact={{ rolefact | default('MISSING') }}"
        YAML

      output = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)
      status.success?.must_equal(true, output.to_s)
      output.to_s.must_include("rolefact=from-role-handler", output.to_s)
      output.to_s.wont_include("MISSING", output.to_s)
    end
  end

  it "set by an include_role'd handler are visible after the flush" do
    with_role("- name: irh\n  ansible.builtin.set_fact:\n    irfact: from-include-role-handler\n") do |dir|
      playbook = File.join(dir, "site.yml")
      File.write(playbook, <<-YAML)
        - name: include_role handler fact
          hosts: localhost
          gather_facts: false
          tasks:
            - name: load the role
              ansible.builtin.include_role:
                name: factrole
            - name: trigger
              ansible.builtin.command: /bin/true
              notify: irh
            - name: flush
              ansible.builtin.meta: flush_handlers
            - name: read it
              ansible.builtin.debug:
                msg: "irfact={{ irfact | default('MISSING') }}"
        YAML

      output = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)
      status.success?.must_equal(true, output.to_s)
      output.to_s.must_include("irfact=from-include-role-handler", output.to_s)
      output.to_s.wont_include("MISSING", output.to_s)
    end
  end

  it "set by a LOOPED handler's per-item set_fact are all visible" do
    status, output = run_playbook(<<-YAML)
      - name: looped handler set_fact
        hosts: localhost
        gather_facts: false
        handlers:
          - name: hloop
            ansible.builtin.set_fact:
              "lf_{{ item.k }}": "{{ item.v }}"
            loop:
              - { k: a, v: va }
              - { k: b, v: vb }
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            notify: hloop
          - name: flush
            ansible.builtin.meta: flush_handlers
          - name: read them
            ansible.builtin.debug:
              msg: "a={{ lf_a | default('MISSING') }} b={{ lf_b | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("a=va b=vb", output)
    output.wont_include("MISSING", output)
  end
end
