require "../minitest_helper"

# Issue #421 (ansibleguy.infra_mariadb, round29883511) - a literal loop:
# list whose bare `{{ VAR.attr }}` item references a variable whose OWN
# value is still unrendered Jinja (`MARIADB_CONFIG: "{{ default_mariadb |
# combine(mariadb, recursive=true) }}"` with `mariadb` set nowhere) ran
# where ansible-playbook fails the task: ansible templates the loop list
# with module-arg strict-undefined semantics BEFORE iterating, so the
# nested combine() argument read raises "'mariadb' is undefined" at the
# FIRST looping task (live-verified vs ansible 2.19 on the real role and
# on a local minimal repro). deep_render_item's bare-span native branch
# resolved the reference through the lenient VariableLookup, which
# collapsed the undefined combine argument to null and handed back the
# unmerged default, running the whole role past Ansible's hard stop.
# A `| default(...)`-tolerated nested template must still render fine
# (the dev-sec os_hardening `combine(x | default({}))` idiom, same bare
# loop item).
# Second divergence (driver re-run): the caused-by Origin must pin the
# defining var's OWN site even when that var's value nests a template
# that reads a GATHERED FACT (the real role's default_mariadb nests
# `{{ 'syslog' if ansible_distribution_version == '10' else 'journal' }}`
# one combine() below MARIADB_CONFIG). Ansible resolves the defining
# value in the task's own context, facts included, so the origin scan's
# probe render fails on the undefined combine argument - not on the
# fact name - and the true defining site survives the message-equality
# gate (live-verified vs ansible 2.19: Origin lands on 9_merge.yml, not
# on the loop item).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "loop bare-span strict re-templating of combine arguments" do
  it "fails the task when a looped item reads a combine() with an undefined argument" do
    src_dir = PluginSpecHelper.tmp_path("loop-combine-undefined", "fail")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          base_config:
            path: /tmp
          MERGED: "{{ base_config | combine(user_overrides, recursive=true) }}"
        tasks:
          - name: Creating directories
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ MERGED.path }}"
              - plain_second_item
          - name: Should not run
            ansible.builtin.debug:
              msg: reached second task
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("'user_overrides' is undefined")
    text.must_include("failed=1")
    text.wont_include("reached second task")
  end

  it "keeps a default()-tolerated combine() override rendering in a looped task param" do
    src_dir = PluginSpecHelper.tmp_path("loop-combine-undefined", "tolerated")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          base_config:
            path: /tmp
          MERGED: "{{ base_config | combine(user_overrides | default({}, true), recursive=true) }}"
        tasks:
          - name: Showing merged path
            ansible.builtin.debug:
              msg: "merged={{ MERGED.path }}"
            loop: [1, 2]
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("merged=/tmp")
    text.wont_include("user_overrides' is undefined")
    text.must_include("failed=0")
  end

  it "pins the caused-by Origin at the defining var when its value nests a gathered fact" do
    src_dir = PluginSpecHelper.tmp_path("loop-combine-undefined", "factnested")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        vars:
          base_config:
            path: "{{ ansible_hostname }}"
          MERGED: "{{ base_config | combine(user_overrides, recursive=true) }}"
        tasks:
          - name: Creating directories
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ MERGED.path }}"
              - plain_second_item
      YAML

    merged_line = File.read_lines(playbook).index! { |line| line.includes?("combine(user_overrides") } + 1

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("'user_overrides' is undefined")
    # The cause stanza's Origin lands on the MERGED def (the combine()
    # argument's defining site), NOT the loop item or the base_config fact
    # line - only reachable once the probe render sees the gathered
    # ansible_hostname fact.
    text.must_include("#{playbook}:#{merged_line}:")
    text.must_include("failed=1")
  end
end
