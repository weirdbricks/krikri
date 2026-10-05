require "file_utils"
require "../minitest_helper"

# Generic legacy `with_<lookup>:` loop sources (with_url:, with_lines:, ...).
# Ansible treats ANY with_-prefixed task key as a loop keyword
# equivalent to `loop: "{{ lookup('<plugin>', <terms>, wantlist=True) }}"`
# with the terms templated first; the parser previously recognized only a
# fixed set of with_* keywords, so with_url:/with_lines: fell through as
# unrecognized task keys and the task ran exactly ONCE with the loop
# variable unbound ("'sha_url_item' is undefined" - round 981054,
# lean_delivery.solr_standalone's sha512-checksum fetch).
#
# with_url is exercised through file:// URLs (controller-local reads,
# the same scheme Ansible's url lookup accepts) so the spec needs no
# network. Every expected value matches an ansible-core 2.19 run of the
# same playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_play(playbook : String, extra_files : Hash(String, String) = {} of String => String) : {Int32, String}
  dir = File.tempname("generic-with-lookup")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)
  extra_files.each { |name, content| File.write(File.join(dir, name), content) }

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "generic with_<lookup> loop sources" do
  it "loops set_fact over with_url with a custom loop_var (round 981054)" do
    code, output = run_play(<<-YAML, {"notes.txt" => "alpha checksum line\n"})
      - hosts: all
        gather_facts: false
        tasks:
          - set_fact:
              sha_value: '{{ sha_url_item }}'
            with_url: 'file://notes.txt'
            loop_control:
              loop_var: sha_url_item
          - debug: var=sha_value
      YAML

    code.must_equal(0)
    output.must_include(%("sha_value": "alpha checksum line"))
    output.wont_include("sha_url_item' is undefined")
  end

  it "loops set_fact over with_url with the default item name" do
    code, output = run_play(<<-YAML, {"notes.txt" => "body text\n"})
      - hosts: all
        gather_facts: false
        tasks:
          - set_fact:
              fetched: '{{ item }}'
            with_url: 'file://notes.txt'
          - debug: var=fetched
      YAML

    code.must_equal(0)
    output.must_include(%("fetched": "body text"))
  end

  it "loops a regular module over with_url with a custom loop_var" do
    code, output = run_play(<<-YAML, {"notes.txt" => "module item body\n"})
      - hosts: all
        gather_facts: false
        tasks:
          - debug:
              msg: "got {{ wu }}"
            with_url: 'file://notes.txt'
            loop_control:
              loop_var: wu
      YAML

    code.must_equal(0)
    output.must_include("item=module item body")
    output.must_include("got module item body")
  end

  it "loops set_fact over with_lines with a custom loop_var" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - set_fact:
              line_value: '{{ it }}'
            with_lines: 'echo gamma'
            loop_control:
              loop_var: it
          - debug: var=line_value
      YAML

    code.must_equal(0)
    output.must_include(%("line_value": "gamma"))
  end

  it "splices a list-valued with_lines term into one command per element" do
    # Ansible's listify_lookup_plugin_terms templates the term first
    # and splices the resolved LIST one level into the lookup's terms, so
    # each element runs as its own command (ansible-core 2.19: two items,
    # alpha and beta).
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        vars:
          cmd_list: ["echo alpha", "echo beta"]
        tasks:
          - set_fact:
              line_value: '{{ item }}'
            with_lines: '{{ cmd_list }}'
          - debug: var=line_value
      YAML

    code.must_equal(0)
    output.must_include("item=alpha")
    output.must_include("item=beta")
  end

  it "loops include_tasks over with_url exposing the custom loop_var inside" do
    code, output = run_play(
      <<-YAML,
      - hosts: all
        gather_facts: false
        tasks:
          - include_tasks: inc_target.yml
            with_url: 'file://notes.txt'
            loop_control:
              loop_var: inc_item
      YAML
      {
        "notes.txt"      => "first line\nsecond line\n",
        "inc_target.yml" => "- debug:\n    msg: \"included with {{ inc_item }}\"\n",
      }
    )

    code.must_equal(0)
    output.must_include("included with first line")
    output.must_include("included with second line")
  end

  it "fails the task like Ansible when the with_url file:// target is missing" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - set_fact:
              fetched: '{{ item }}'
            with_url: 'file://definitely_missing.txt'
      YAML

    code.wont_equal(0)
    output.must_include("failed")
  end

  # Security: terms and results of a generic lookup loop are DATA. Each
  # case below used to run the hostile `lookup('pipe', ...)` on the
  # controller (live canary); ansible-playbook 2.19.11 prints the
  # text verbatim and never executes it.
  it "never executes Jinja carried by host-derived text in a lookup term" do
    canary = File.tempname("krikri-lookup-term-canary")
    code, _ = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - command: echo "{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}"
            register: c
          - debug: msg="x"
            with_env: "{{ c.stdout }}"
      YAML

    code.must_equal(0)
    File.exists?(canary).must_equal(false)
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "never renders a with_lines command's output as a template" do
    canary = File.tempname("krikri-lookup-item-canary")
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - debug: msg="{{ item }}"
            with_lines: 'echo ''{{ "{{" }} lookup("pipe", "touch #{canary}") {{ "}}" }}'''
      YAML

    code.must_equal(0)
    File.exists?(canary).must_equal(false)
    output.must_include(%(item={{ lookup("pipe", "touch #{canary}") }}))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "fails the task, not the whole run, when a with_url lookup fails" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - debug: msg="{{ item }}"
            with_url: 'file:///nonexistent/krikri-missing.txt'
            ignore_errors: true
          - debug: msg="after"
      YAML

    code.must_equal(0)
    output.wont_include("Unhandled exception")
    output.must_include("...ignoring")
    output.must_include("after")
  end
end
