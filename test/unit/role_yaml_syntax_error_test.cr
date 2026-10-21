require "../minitest_helper"
require "../../src/krikri/role_loader"

# ansible-core 2.19 refuses the whole playbook run (rc=4, "[ERROR]: YAML
# parsing failed" + the file's Origin block) when ANY file a play loads -
# including a role's own tasks/main.yml - has a YAML syntax error, such as
# the unknown-escape `"\ldap://..."` inside a double-quoted scalar.
# role_loader's YAML.parse used to let the raw YAML::ParseException escape,
# which the per-play rescue degraded into "Warning: Failed to parse play N"
# + "No valid plays found" (rc=1) - output ansible never prints for this.
private def bad_tasks : String
  <<-YAML
    ---
    # tasks file for broken_escape
    - name: configure ldap
      block:
        - name: install packages
          apt:
            name: openldap
            state: present
        - name: configure server
          ldap_config:
            server_hostname: ldap.example.com
            server_uri: "{{server_uri|default(\\ldap://127.0.0.1)}}"
    YAML
end

describe "role file YAML syntax errors (role_yaml_syntax_error_test.cr)" do
  it "raises YamlSyntaxError for an unknown escape in a role's tasks/main.yml" do
    root = PluginSpecHelper.tmp_path("role_yaml_syntax_error_spec")
    role_dir = File.join(root, "roles", "broken_escape")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    tasks_path = File.join(role_dir, "tasks", "main.yml")
    File.write(tasks_path, bad_tasks)

    play = Krikri::Play.new("test play", "all")
    roles = YAML.parse("- broken_escape").as_a
    ex = assert_raises(Krikri::YamlSyntaxError) do
      Krikri::RoleLoader.load_roles(roles, play, root)
    end
    ex.path.must_equal(tasks_path)
    ex.detail.must_equal("While parsing a quoted scalar found unknown escape character.")
    ex.line.must_equal(12)
    ex.column.must_equal(43)
  end
end
