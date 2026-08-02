require "../spec_helper"
require "file_utils"
require "../../src/crystal_play/role_loader"

private ROLES_ROOT = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "role_loader_spec")

private def write(path : String, content : String)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
end

private def build_role(name : String, root : String = ROLES_ROOT, & : RoleBuilder ->)
  role_dir = File.join(root, "roles", name)
  Dir.mkdir_p(role_dir)
  yield RoleBuilder.new(role_dir)
end

private class RoleBuilder
  def initialize(@role_dir : String)
  end

  def tasks(content : String)
    write(File.join(@role_dir, "tasks", "main.yml"), content)
  end

  def handlers(content : String)
    write(File.join(@role_dir, "handlers", "main.yml"), content)
  end

  def defaults(content : String)
    write(File.join(@role_dir, "defaults", "main.yml"), content)
  end

  def vars(content : String)
    write(File.join(@role_dir, "vars", "main.yml"), content)
  end

  def meta(content : String)
    write(File.join(@role_dir, "meta", "main.yml"), content)
  end

  def file(name : String, content : String)
    write(File.join(@role_dir, "files", name), content)
  end

  def template_dir
    Dir.mkdir_p(File.join(@role_dir, "templates"))
  end
end

private def roles_yaml(source : String) : Array(YAML::Any)
  YAML.parse(source).as_a
end

private def fresh_play : CrystalPlay::Play
  CrystalPlay::Play.new("test play", "all")
end

describe CrystalPlay::RoleLoader do
  before_each do
    FileUtils.rm_rf(ROLES_ROOT) if Dir.exists?(ROLES_ROOT)
    Dir.mkdir_p(ROLES_ROOT)
  end

  it "loads tasks/main.yml for a bare role name" do
    build_role("simple") { |role| role.tasks(<<-YAML) }
      - name: hello
        ansible.builtin.debug:
          msg: hi
      YAML

    tasks, handlers = CrystalPlay::RoleLoader.load_roles(roles_yaml("- simple"), fresh_play, ROLES_ROOT)

    tasks.map(&.name).should eq(["hello"])
    handlers.should be_empty
  end

  it "loads handlers/main.yml alongside tasks" do
    build_role("with_handler") do |role|
      role.tasks(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hi
        YAML
      role.handlers(<<-YAML)
        - name: restart thing
          ansible.builtin.debug:
            msg: restarted
        YAML
    end

    _, handlers = CrystalPlay::RoleLoader.load_roles(roles_yaml("- with_handler"), fresh_play, ROLES_ROOT)

    handlers.map(&.name).should eq(["restart thing"])
  end

  it "sets role_defaults from defaults/main.yml on every task" do
    build_role("defaulted") do |role|
      role.tasks(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hi
        YAML
      role.defaults("port: 8080\n")
    end

    tasks, _ = CrystalPlay::RoleLoader.load_roles(roles_yaml("- defaulted"), fresh_play, ROLES_ROOT)

    tasks[0].role_defaults.as(Hash(String, JSON::Any))["port"].as_i.should eq(8080)
  end

  it "sets role_vars from vars/main.yml, and invocation vars win over it" do
    build_role("varred") do |role|
      role.tasks(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hi
        YAML
      role.vars("env: from-vars-file\nregion: us-east\n")
    end

    tasks, _ = CrystalPlay::RoleLoader.load_roles(
      roles_yaml("- role: varred\n  vars:\n    env: from-invocation\n"),
      fresh_play,
      ROLES_ROOT
    )

    role_vars = tasks[0].role_vars.as(Hash(String, JSON::Any))
    role_vars["env"].as_s.should eq("from-invocation")
    role_vars["region"].as_s.should eq("us-east")
  end

  it "treats inline keys on a role entry as vars too (besides role/name/vars/tags)" do
    build_role("inline_vars") { |role| role.tasks(<<-YAML) }
      - name: t
        ansible.builtin.debug:
          msg: hi
      YAML

    tasks, _ = CrystalPlay::RoleLoader.load_roles(
      roles_yaml("- role: inline_vars\n  port: 9090\n"),
      fresh_play,
      ROLES_ROOT
    )

    tasks[0].role_vars.as(Hash(String, JSON::Any))["port"].as_i.should eq(9090)
  end

  it "sets role_files_dir/role_templates_dir only when those directories exist" do
    build_role("with_files") do |role|
      role.tasks(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hi
        YAML
      role.file("hello.txt", "hi\n")
    end

    tasks, _ = CrystalPlay::RoleLoader.load_roles(roles_yaml("- with_files"), fresh_play, ROLES_ROOT)

    tasks[0].role_files_dir.should eq(File.join(ROLES_ROOT, "roles", "with_files", "files"))
    tasks[0].role_templates_dir.should be_nil
  end

  it "runs meta/main.yml dependencies before the role's own tasks" do
    build_role("base") { |role| role.tasks(<<-YAML) }
      - name: base task
        ansible.builtin.debug:
          msg: base
      YAML

    build_role("dependent") do |role|
      role.tasks(<<-YAML)
        - name: dependent task
          ansible.builtin.debug:
            msg: dependent
        YAML
      role.meta("dependencies:\n  - base\n")
    end

    tasks, _ = CrystalPlay::RoleLoader.load_roles(roles_yaml("- dependent"), fresh_play, ROLES_ROOT)

    tasks.map(&.name).should eq(["base task", "dependent task"])
  end

  it "loads each role only once, even if listed directly and pulled in as a dependency" do
    build_role("shared") { |role| role.tasks(<<-YAML) }
      - name: shared task
        ansible.builtin.debug:
          msg: shared
      YAML

    build_role("depends_on_shared") do |role|
      role.tasks(<<-YAML)
        - name: dependent task
          ansible.builtin.debug:
            msg: dependent
        YAML
      role.meta("dependencies:\n  - shared\n")
    end

    tasks, _ = CrystalPlay::RoleLoader.load_roles(roles_yaml("- shared\n- depends_on_shared\n"), fresh_play, ROLES_ROOT)

    tasks.map(&.name).should eq(["shared task", "dependent task"])
  end

  it "raises with a clear message when the role directory can't be found" do
    expect_raises(Exception, /Role not found: nonexistent/) do
      CrystalPlay::RoleLoader.load_roles(roles_yaml("- nonexistent"), fresh_play, ROLES_ROOT)
    end
  end

  it "applies the role invocation's tags: to every task the role contributes" do
    build_role("tagged") { |role| role.tasks(<<-YAML) }
      - name: t
        ansible.builtin.debug:
          msg: hi
      YAML

    tasks, _ = CrystalPlay::RoleLoader.load_roles(
      roles_yaml("- role: tagged\n  tags: [deploy]\n"),
      fresh_play,
      ROLES_ROOT
    )

    tasks[0].tags.should eq(["deploy"])
  end
end
