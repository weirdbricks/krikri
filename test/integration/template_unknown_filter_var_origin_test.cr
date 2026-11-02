require "../minitest_helper"

# A `template:` task whose template reads a role VAR whose own value uses an
# unknown filter (`x | version_compare('9','>=')`, issue #709): real
# ansible-core 2.19 compiles the value when the template reads it, so the
# failure is the same uncaught compile-error crash shape as a template-file
# filter name (issue #335) - "Task failed: Syntax error in template: No
# filter named 'version_compare'." - but the `<<< caused by >>>` chain's
# inner Origin is the variable's DEFINITION in the role's vars/main.yml
# (caret at the value token), not the template file. Many role vars may use
# the same unknown filter; real names the one the template reads FIRST, so
# the Origin must follow the template's read order, not the vars file's.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a .j2 reading a role var whose value uses an unknown filter (#709)" do
  it "crashes like ansible with the chain Origin at the template-read var's definition" do
    dir = File.join(Dir.tempdir, "ufilter-var-origin-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(File.join(dir, "roles", "probe", "tasks"))
    Dir.mkdir_p(File.join(dir, "roles", "probe", "vars"))
    Dir.mkdir_p(File.join(dir, "roles", "probe", "templates"))
    vars_path = File.join(dir, "roles", "probe", "vars", "main.yml")
    dest = File.join(dir, "out.conf")
    playbook = File.join(dir, "playbook.yml")

    # Both vars use the unknown filter; the template reads second_var (the
    # SECOND-defined one) first, so the chain's Origin must point at its
    # line, not first_var's.
    File.write(vars_path, <<-YAML)
      ---
      first_var: "{{ '1.2.3' | version_compare('9','>=') }}"
      second_var: "{{ '2.0.0' | version_compare('9','>=') }}"
      YAML
    File.write(File.join(dir, "roles", "probe", "templates", "config.j2"), "{{ second_var }}\n{{ first_var }}\n")
    File.write(File.join(dir, "roles", "probe", "tasks", "main.yml"), <<-YAML)
      ---
      - name: render config
        ansible.builtin.template:
          src: config.j2
          dest: #{dest}
      YAML
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        roles:
          - probe
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Syntax error in template: No filter named 'version_compare'.")
    text.must_include("<<< caused by >>>")
    # The inner Origin is second_var's definition (line 3, the value token
    # at column 13 - the opening quote), NOT first_var's line 2.
    text.must_include("No filter named 'version_compare'.\nOrigin: #{vars_path}:3:13")
    text.wont_include("Origin: #{vars_path}:2:12")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Syntax error in template: No filter named 'version_compare'."}))
    text.wont_include("Failed to render template")
    File.exists?(dest).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir && File.exists?(dir)
  end
end
