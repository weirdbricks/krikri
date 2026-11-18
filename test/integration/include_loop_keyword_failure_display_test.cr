require "file_utils"
require "../minitest_helper"

# A looped include_role:/include_tasks: whose ordinary task keywords fail
# ansible's post-validation (`any_errors_fatal: kpg-maybe` inherited from the
# play here) fails PER ITEM: real prints one
# `failed: [host] (item=X) => {"ansible_loop_var": ..., "item": X, "msg": ...}`
# line per iteration, while the whole looped task still books ONE result -
# failed=1, or ok+=1/ignored+=1 plus a single trailing `...ignoring` under
# ignore_errors: (live-verified vs ansible-core 2.21.6). krikri printed a
# plain `fatal: [host]: FAILED!` with no item per iteration and booked one
# failed per item (issue #1499).
private INCLUDE_LOOP_KEYWORD_BIN = File.join(File.expand_path("../..", __DIR__), "bin", "krikri-playbook")
private INCLUDE_LOOP_KEYWORD_INV = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_include_loop_keyword_playbook(playbook_body : String, extra_files : Hash(String, String) = {} of String => String)
  dir = File.tempname("include-loop-keyword")
  Dir.mkdir(dir)
  playbook = File.join(dir, "site.yml")
  File.write(playbook, playbook_body)
  extra_files.each do |rel, content|
    path = File.join(dir, rel)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
  output = IO::Memory.new
  status = Process.run(INCLUDE_LOOP_KEYWORD_BIN, ["-i", INCLUDE_LOOP_KEYWORD_INV, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private INCLUDE_LOOP_KEYWORD_ROLES = {
  "roles/one/tasks/main.yml" => "- ansible.builtin.debug: {msg: ROLE-RAN}\n",
  "roles/two/tasks/main.yml" => "- ansible.builtin.debug: {msg: ROLE-RAN}\n",
}

private INCLUDE_LOOP_KEYWORD_ROLE_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    any_errors_fatal: kpg-maybe
    tasks:
      - name: looped include
        ansible.builtin.include_role:
          name: '{{ item }}'
        loop:
          - one
          - two
  YAML

private INCLUDE_LOOP_KEYWORD_TASKS_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    any_errors_fatal: kpg-maybe
    tasks:
      - name: looped include
        ansible.builtin.include_tasks:
          file: inner.yml
        loop:
          - one
          - two
        ignore_errors: true
  YAML

private INCLUDE_LOOP_KEYWORD_INNER = {
  "inner.yml" => "- ansible.builtin.debug: {msg: INCLUDED-RAN}\n",
}

private INCLUDE_LOOP_KEYWORD_MSG = %("msg": "Task failed: Error processing keyword 'any_errors_fatal': The value 'kpg-maybe' could not be converted to 'bool'.")

describe "looped include keyword post-validation failure" do
  it "prints one failed line per item with the loop bindings and recaps failed=1" do
    status, output = run_include_loop_keyword_playbook(INCLUDE_LOOP_KEYWORD_ROLE_PLAYBOOK, INCLUDE_LOOP_KEYWORD_ROLES)

    status.exit_code.must_equal(2)
    output.must_include("Error processing keyword 'any_errors_fatal'")
    output.must_include(%(failed: [localhost] (item=one) => {"ansible_loop_var": "item", "changed": false, "item": "one", #{INCLUDE_LOOP_KEYWORD_MSG}}))
    output.must_include(%(failed: [localhost] (item=two) => {"ansible_loop_var": "item", "changed": false, "item": "two", #{INCLUDE_LOOP_KEYWORD_MSG}}))
    output.wont_include("fatal: [localhost]")
    output.must_match(/failed=1\b/)
    output.wont_include("ROLE-RAN")
  end

  it "prints a single trailing ...ignoring and recaps ok+ignored for an ignored loop" do
    status, output = run_include_loop_keyword_playbook(INCLUDE_LOOP_KEYWORD_TASKS_PLAYBOOK, INCLUDE_LOOP_KEYWORD_INNER)

    status.success?.must_equal(true, output)
    output.must_include("failed: [localhost] (item=one) => ")
    output.must_include("failed: [localhost] (item=two) => ")
    output.wont_include("fatal: [localhost]")
    output.scan("...ignoring").size.must_equal(1, output)
    output.must_match(/ok=1\b/)
    output.must_match(/failed=0\b/)
    output.must_match(/ignored=1\b/)
    output.wont_include("INCLUDED-RAN")
  end
end
