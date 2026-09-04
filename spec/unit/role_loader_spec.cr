require "../spec_helper"
require "file_utils"
require "../../src/krikri/role_loader"

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

private def fresh_play : Krikri::Play
  Krikri::Play.new("test play", "all")
end

describe Krikri::RoleLoader do
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

    tasks, handlers = Krikri::RoleLoader.load_roles(roles_yaml("- simple"), fresh_play, ROLES_ROOT)

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

    _, handlers = Krikri::RoleLoader.load_roles(roles_yaml("- with_handler"), fresh_play, ROLES_ROOT)

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

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- defaulted"), fresh_play, ROLES_ROOT)

    tasks[0].role_defaults.as(Hash(String, JSON::Any))["port"].as_i.should eq(8080)
  end

  it "loads a defaults/main.yml dict keyed by a bare YAML boolean without crashing (real Ansible/Jinja2 idiom: dict[some_bool])" do
    build_role("bool_keyed") do |role|
      role.tasks(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hi
        YAML
      role.defaults(<<-YAML)
        my_dict:
          true: "when true"
          false: "when false"
        YAML
    end

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- bool_keyed"), fresh_play, ROLES_ROOT)

    defaults = tasks[0].role_defaults.as(Hash(String, JSON::Any))
    inner = defaults["my_dict"].as_h
    inner["true"].as_s.should eq("when true")
    inner["false"].as_s.should eq("when false")
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

    tasks, _ = Krikri::RoleLoader.load_roles(
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

    tasks, _ = Krikri::RoleLoader.load_roles(
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

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- with_files"), fresh_play, ROLES_ROOT)

    tasks[0].role_files_dir.should eq(File.join(ROLES_ROOT, "roles", "with_files", "files"))
    tasks[0].role_templates_dir.should be_nil
  end

  it "sets role_path (and the derived role_files_dir/role_templates_dir/role_vars_dir) to an ABSOLUTE path even when playbook_dir is given as relative" do
    # Real bug found benchmarking linux-system-roles.timesync (round
    # 158): resolve_role_dir's own search dirs can be relative (a bare
    # "roles" search root, or a relative ANSIBLE_ROLES_PATH entry), and
    # that relative-ness leaked straight into task.role_path - but real
    # Ansible's own role_path magic var is documented as always
    # absolute. The role's own `paths: ["{{ role_path }}/vars"]`
    # first_found idiom (a real Ansible convention, since role_path is
    # supposed to always be absolute already) relies on
    # resolve_first_found_root's `return path if path.starts_with?("/")`
    # early return - with a relative role_path, that never fired, so it
    # went on to prepend role_path a SECOND time on top of the already-
    # role_path-prefixed string Jinja had just substituted, producing a
    # doubled, nonexistent path - every first_found candidate "not
    # found", silently resolving to "undefined" instead of the real
    # vars file. Only reproduced against a genuinely relative
    # playbook_dir (a real remote-host benchmark run's own working
    # directory setup) - this spec's own ROLES_ROOT fixture is already
    # absolute, which is exactly why this class of bug survived
    # undetected here until now.
    build_role("with_files") do |role|
      role.tasks(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hi
        YAML
      role.file("hello.txt", "hi\n")
    end

    relative_dir = Path.new(ROLES_ROOT).relative_to(Dir.current).to_s
    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- with_files"), fresh_play, relative_dir)

    role_path = (tasks[0].role_path || raise "unexpected nil")
    role_path.should start_with("/")
    role_path.should eq(File.join(ROLES_ROOT, "roles", "with_files"))
    (tasks[0].role_files_dir || raise "unexpected nil").should start_with("/")
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

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- dependent"), fresh_play, ROLES_ROOT)

    tasks.map(&.name).should eq(["base task", "dependent task"])
  end

  # Real bug found benchmarking andrewrothstein.github-release (0.9.622):
  # `src:` is real Ansible's own `RoleRequirement` key, used both for a
  # `requirements.yml` entry AND for a role's `meta/main.yml` dependency
  # (`- src: some.role, version: v1.0.0` - the galaxy-requirements
  # convention, copied verbatim into many real published roles' own meta
  # dependencies). Only "role"/"name" were recognized as the dependency's
  # name key - a `src:`-keyed dependency raised "Role entry missing
  # 'role' or 'name'" and aborted parsing the WHOLE PLAYBOOK (not just
  # that one dependency), even though real Ansible resolves and installs
  # it completely normally.
  it "resolves a meta dependency written with 'src:' (real Ansible's own RoleRequirement key), not just 'role:'/'name:'" do
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
      role.meta("dependencies:\n  - src: base\n    version: v1.0.0\n")
    end

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- dependent"), fresh_play, ROLES_ROOT)

    tasks.map(&.name).should eq(["base task", "dependent task"])
  end

  it "keeps a meta dependency's defaults in scope for the role that declares it" do
    # Real Ansible loads a dependency first and leaves its defaults
    # visible to the dependent role - the shape buluma.phpmyadmin uses
    # to read `mysql_root_password` out of its buluma.mysql dependency.
    # Previously a dependency's defaults were used for that dependency's
    # own tasks and then discarded.
    build_role("dep_defaults_base") do |role|
      role.tasks("- name: base task\n  ansible.builtin.debug:\n    msg: base\n")
      role.defaults("mysql_root_password: s3Cur31t4.\n")
    end

    build_role("dep_defaults_user") do |role|
      role.tasks("- name: user task\n  ansible.builtin.debug:\n    msg: user\n")
      role.defaults("pma_password: \"{{ mysql_root_password }}\"\n")
      role.meta("dependencies:\n  - dep_defaults_base\n")
    end

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- dep_defaults_user"), fresh_play, ROLES_ROOT)

    user_task = tasks.find! { |task| task.name == "user task" }
    (user_task.role_defaults || raise "unexpected nil")["mysql_root_password"].as_s.should eq("s3Cur31t4.")
  end

  it "lets the declaring role's own defaults win over a dependency's" do
    build_role("dep_defaults_base2") do |role|
      role.tasks("- name: base2 task\n  ansible.builtin.debug:\n    msg: base\n")
      role.defaults("shared_name: from_dependency\n")
    end

    build_role("dep_defaults_user2") do |role|
      role.tasks("- name: user2 task\n  ansible.builtin.debug:\n    msg: user\n")
      role.defaults("shared_name: from_self\n")
      role.meta("dependencies:\n  - dep_defaults_base2\n")
    end

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- dep_defaults_user2"), fresh_play, ROLES_ROOT)

    user_task = tasks.find! { |task| task.name == "user2 task" }
    (user_task.role_defaults || raise "unexpected nil")["shared_name"].as_s.should eq("from_self")
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

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- shared\n- depends_on_shared\n"), fresh_play, ROLES_ROOT)

    tasks.map(&.name).should eq(["shared task", "dependent task"])
  end

  it "raises with a clear message when the role directory can't be found" do
    expect_raises(Exception, /Role not found: nonexistent/) do
      Krikri::RoleLoader.load_roles(roles_yaml("- nonexistent"), fresh_play, ROLES_ROOT)
    end
  end

  it "applies the role invocation's tags: to every task the role contributes" do
    build_role("tagged") { |role| role.tasks(<<-YAML) }
      - name: t
        ansible.builtin.debug:
          msg: hi
      YAML

    tasks, _ = Krikri::RoleLoader.load_roles(
      roles_yaml("- role: tagged\n  tags: [deploy]\n"),
      fresh_play,
      ROLES_ROOT
    )

    tasks[0].tags.should eq(["deploy"])
  end

  it "resolves a namespace.collection.role FQCN via ANSIBLE_COLLECTIONS_PATH" do
    # Real bug found benchmarking prometheus.prometheus.node_exporter (a
    # real Ansible Collection, distinct from a plain Galaxy role install)
    # - resolve_role_dir only ever looked under a playbook's own roles:/
    # directory, so any collection-shipped role failed outright ("Role
    # not found"), entirely missing functionality.
    collections_root = File.join(ROLES_ROOT, "my_collections")
    role_dir = File.join(collections_root, "ansible_collections", "acme", "widgets", "roles", "installer")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
      - name: from collection
        ansible.builtin.debug:
          msg: hi
      YAML

    ENV["ANSIBLE_COLLECTIONS_PATH"] = collections_root
    begin
      tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- acme.widgets.installer"), fresh_play, ROLES_ROOT)
      tasks.map(&.name).should eq(["from collection"])
    ensure
      ENV.delete("ANSIBLE_COLLECTIONS_PATH")
    end
  end

  it "expands the default '~/.ansible/collections' collection path to the real user home, not cwd-relative literal-~" do
    # Real bug found live-verifying round 24 role 2 (dev-sec.
    # hardening.mysql_hardening FQCN, see KNOWN_MISSING.md 0.9.348):
    # the default `~/.ansible/collections` fallback in
    # collections_paths was using `File.expand_path` which does NOT
    # expand a leading `~` - it treats `~` as a literal directory
    # name and joins it to the CWD, producing `/tmp/~/.ansible/
    # collections` when the binary is run from `/tmp` (or anywhere
    # other than `$HOME`). The collection path lookup silently never
    # found anything there, the FQCN `devsec.hardening.mysql_hardening`
    # fell through to the bare-roles search (also missing), and the
    # whole role failed with a misleading "Role not found: ...
    # (looked under ./roles/... and roles/...)" error that didn't
    # mention collections at all. Same tilde-expansion bug already
    # fixed in plugin_helpers/mysql_connection.cr's
    # resolve_option_file_path (KNOWN_MISSING.md 0.9.346) and in
    # BasePlugin#expand_tilde (used by every plugin's path-type arg);
    # this test pins the role_loader's own copy.
    #
    # The fix uses System::User.find_by? to find the home dir (not
    # ENV["HOME"], which can be overridden by env stubs or
    # chrooted environments; the passwd-database lookup is the
    # canonical source of truth for the user's actual home). This
    # is why the test uses a REAL collection under a REAL home
    # directory - the dev-sec.hardening collection already installed
    # at `~/.ansible/collections/` from the round-24 devsec_mysql
    # benchmark is the natural test fixture, and anywhere it isn't
    # installed (CI) a minimal stand-in with the same FQCN is created
    # under the same path and removed afterward.
    ENV.delete("ANSIBLE_COLLECTIONS_PATH")
    ENV.delete("ANSIBLE_COLLECTIONS_PATHS")
    original_cwd = Dir.current
    Dir.cd("/tmp")

    # The loader resolves `~` through the passwd database (the real home),
    # so a temp HOME can't redirect it - the fixture has to live under the
    # actual `~/.ansible/collections/`. The devsec.hardening collection
    # installed by the round-24 devsec_mysql benchmark is the fixture when
    # present (mysql_hardening is the smallest role there); anywhere else
    # (CI), create a minimal stand-in collection with the same FQCN and
    # shape and remove it afterward.
    # NOTE: Path.home, not File.expand_path("~", ...) - expand_path does
    # NOT expand a leading tilde in Crystal, which is the very bug this
    # spec pins. The fixture has to land in the real home.
    collection_dir = File.join(Path.home.to_s, ".ansible/collections/ansible_collections/devsec/hardening")
    role_dir = File.join(collection_dir, "roles", "mysql_hardening")
    fixture_created = false
    unless Dir.exists?(role_dir)
      tasks_dir = File.join(role_dir, "tasks")
      Dir.mkdir_p(tasks_dir)
      # First task name matches the real role's arg-spec validation entry,
      # so the sanity assertion below holds for both fixture flavors.
      File.write(File.join(tasks_dir, "main.yml"),
        "---\n- name: Validating arguments (fixture)\n  ansible.builtin.debug:\n    msg: role_loader tilde-expansion fixture\n")
      fixture_created = true
    end

    begin
      tasks, _ = Krikri::RoleLoader.load_roles(
        roles_yaml("- devsec.hardening.mysql_hardening"),
        fresh_play,
        ROLES_ROOT,
      )
      tasks.should_not be_empty
      # Sanity: confirm it actually loaded the role (not a stub from
      # some other path). The role's main.yml has a "Validating
      # arguments" task as its first entry (arg-spec validation).
      tasks[0].name.should contain("Validating arguments")
    ensure
      FileUtils.rm_rf(File.join(collection_dir, "roles", "mysql_hardening")) if fixture_created
      Dir.cd(original_cwd)
    end
  end

  it "tasks_from: loads tasks/<name>.yml instead of tasks/main.yml" do
    build_role("multi_entry") do |role|
      role.tasks(<<-YAML)
        - name: main entry
          ansible.builtin.debug:
            msg: main
        YAML
      write(File.join(ROLES_ROOT, "roles", "multi_entry", "tasks", "install.yml"), <<-YAML)
        - name: install entry
          ansible.builtin.debug:
            msg: install
        YAML
    end

    tasks, _ = Krikri::RoleLoader.load_single_role(
      "multi_entry", Hash(String, JSON::Any).new, [] of String, fresh_play, ROLES_ROOT, "install.yml"
    )

    tasks.map(&.name).should eq(["install entry"])
  end

  it "tasks_from: accepts a bare name without the .yml extension too" do
    build_role("multi_entry2") do |role|
      role.tasks("- name: main\n  ansible.builtin.debug:\n    msg: hi\n")
      write(File.join(ROLES_ROOT, "roles", "multi_entry2", "tasks", "install.yml"), <<-YAML)
        - name: install entry
          ansible.builtin.debug:
            msg: install
        YAML
    end

    tasks, _ = Krikri::RoleLoader.load_single_role(
      "multi_entry2", Hash(String, JSON::Any).new, [] of String, fresh_play, ROLES_ROOT, "install"
    )

    tasks.map(&.name).should eq(["install entry"])
  end

  it "sets role_parent_names from load_single_role's own parent_names argument" do
    # ansible_parent_role_names - the ancestor role-name chain leading to
    # an include_role: call. Several real collections (prometheus.
    # prometheus's own `_common` shared-logic role) guard against direct
    # invocation with `ansible_parent_role_names is defined and
    # ansible_parent_role_names | length > 0`.
    build_role("nested") { |role| role.tasks("- name: t\n  ansible.builtin.debug:\n    msg: hi\n") }

    tasks, _ = Krikri::RoleLoader.load_single_role(
      "nested", Hash(String, JSON::Any).new, [] of String, fresh_play, ROLES_ROOT, nil, ["outer", "inner"]
    )

    tasks[0].role_parent_names.should eq(["outer", "inner"])
  end

  it "a plain roles: entry gets an empty (not nil) role_parent_names" do
    build_role("toplevel") { |role| role.tasks("- name: t\n  ansible.builtin.debug:\n    msg: hi\n") }

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- toplevel"), fresh_play, ROLES_ROOT)

    tasks[0].role_parent_names.should eq([] of String)
  end

  it "sets ansible_collection_name only when the role was invoked via its namespace.collection.role FQCN" do
    # Real bug found benchmarking prometheus.prometheus.node_exporter:
    # ansible_collection_name (the invoking role's own `namespace.
    # collection`) was entirely unimplemented - several real collections
    # use it to strip their own namespace prefix back off ansible_
    # parent_role_names (prometheus.prometheus._common's own
    # `regex_replace(ansible_collection_name ~ '.', '')`, computing a
    # short service name from the FQCN). Undefined for a plain bare-name
    # role, since that isn't a real collection role at all.
    collections_root = File.join(ROLES_ROOT, "my_collections")
    role_dir = File.join(collections_root, "ansible_collections", "acme", "widgets", "roles", "installer")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "main.yml"), "- name: t\n  ansible.builtin.debug:\n    msg: hi\n")

    ENV["ANSIBLE_COLLECTIONS_PATH"] = collections_root
    begin
      tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- acme.widgets.installer"), fresh_play, ROLES_ROOT)
      tasks[0].ansible_collection_name.should eq("acme.widgets")
    ensure
      ENV.delete("ANSIBLE_COLLECTIONS_PATH")
    end

    build_role("bare_role") { |role| role.tasks("- name: t\n  ansible.builtin.debug:\n    msg: hi\n") }
    bare_tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- bare_role"), fresh_play, ROLES_ROOT)
    bare_tasks[0].ansible_collection_name.should be_nil
  end

  it "loads defaults/main/*.yml (a directory of files) the same as a single defaults/main.yml" do
    # Real bug found benchmarking kyl191.openvpn (round 160): its own
    # `defaults/main/openvpn.yml` (no `defaults/main.yml` at all - the
    # `main/` directory form is a real, documented Ansible convention,
    # same as `tasks/main/`) was never read at all -
    # RoleLoader#load_vars_file only ever looked for exactly
    # `defaults/main.yml`, so a role using the directory form got NONE
    # of its own defaults, tripping validation checks that depend on
    # them being set.
    role_dir = File.join(ROLES_ROOT, "roles", "dir_defaults_role")
    write(File.join(role_dir, "defaults", "main", "network.yml"), "my_network: 10.9.0.0\n")
    write(File.join(role_dir, "defaults", "main", "other.yml"), "my_other: hello\n")
    write(File.join(role_dir, "tasks", "main.yml"), "- name: t\n  ansible.builtin.debug:\n    msg: hi\n")

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- dir_defaults_role"), fresh_play, ROLES_ROOT)
    defaults = (tasks[0].role_defaults || raise "unexpected nil")
    defaults["my_network"]?.try(&.as_s).should eq("10.9.0.0")
    defaults["my_other"]?.try(&.as_s).should eq("hello")
  end
end
