require "../minitest_helper"
require "file_utils"
require "../../src/krikri/role_loader"

# Issue #81: a role meta/main.yml with an unknown top-level key must be
# refused at role load, before any task runs - ansible-core's
# RoleMetadata._validate_attributes raises
#   "'X' is not a valid attribute for a RoleMetadata"
# with an Origin at the offending key, aborting the whole run (rc=4).
# krikri previously read only `dependencies` out of the file and accepted
# anything else silently, so the role's tasks ran where Ansible never
# started.
describe "RoleLoader meta/main.yml RoleMetadata key validation (issue 81)" do
  serial! # mutates process-global state (ENV / engine settings)

  include RaisesAssertion

  @roles_root : String = PluginSpecHelper.tmp_path("role_meta_unknown_keys_spec")

  before_each do
    @roles_root = PluginSpecHelper.tmp_path("role_meta_unknown_keys_spec")
    FileUtils.rm_rf(@roles_root) if Dir.exists?(@roles_root)
    Dir.mkdir_p(@roles_root)
  end

  def build_role(name : String, meta : String) : Nil
    role_dir = File.join(@roles_root, "roles", name)
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "main.yml"),
      "- name: hello\n  ansible.builtin.debug:\n    msg: hi\n")
    Dir.mkdir_p(File.join(role_dir, "meta"))
    File.write(File.join(role_dir, "meta", "main.yml"), meta)
  end

  def roles_yaml(source : String) : Array(YAML::Any)
    YAML.parse(source).as_a
  end

  def fresh_play : Krikri::Play
    Krikri::Play.new("test play", "all")
  end

  it "rejects an unknown top-level key with Ansible's RoleMetadata message and Origin" do
    # The exact shape ansible-core refuses (rc=4, no tasks run):
    # documentation_url is not one of RoleMetadata's field attributes.
    build_role("bad_meta", <<-YAML)
      galaxy_info:
        author: a
        description: d
        license: MIT
        min_ansible_version: "2.9"
      dependencies: []
      documentation_url: https://example.com
      YAML

    ex = assert_raises(Krikri::PlaybookParser::InvalidIncludeAttributeError) do
      Krikri::RoleLoader.load_roles(roles_yaml("- bad_meta"), fresh_play, @roles_root)
    end
    ex.message.to_s.must_equal("'documentation_url' is not a valid attribute for a RoleMetadata")
    ex.kind.must_equal("RoleMetadata")
    render = ex.render
    render.wont_be_nil
    render.to_s.lines.first.must_equal(
      "[ERROR]: 'documentation_url' is not a valid attribute for a RoleMetadata")
    # The Origin points at the KEY's own column (1), not the value's.
    render.to_s.must_include("meta/main.yml:7:1")
    render.to_s.must_include("^ column 1")
  end

  it "raises on the first unknown key in document order" do
    # Ansible validates each attribute in document order and raises for
    # the FIRST offending one, not the last.
    build_role("two_bad_keys", "dependencies: []\nfirst_bad: 1\nsecond_bad: 2\n")

    ex = assert_raises(Krikri::PlaybookParser::InvalidIncludeAttributeError) do
      Krikri::RoleLoader.load_roles(roles_yaml("- two_bad_keys"), fresh_play, @roles_root)
    end
    ex.key.must_equal("first_bad")
    ex.message.to_s.must_equal("'first_bad' is not a valid attribute for a RoleMetadata")
  end

  it "points a block-mapping unknown key's Origin at its own line, not its first child's" do
    # Ansible points the Origin at the unknown KEY itself, but a block
    # value makes the source map record the first CHILD's position, so
    # the same-line walk-back never sees the key - ansigenome_info's
    # shape (issue #208) reported meta/main.yml:27:3 instead of 26:1.
    build_role("block_bad_meta", <<-YAML)
      galaxy_info:
        author: a
      ansigenome_info:
        galaxy_id: ''
      YAML

    ex = assert_raises(Krikri::PlaybookParser::InvalidIncludeAttributeError) do
      Krikri::RoleLoader.load_roles(roles_yaml("- block_bad_meta"), fresh_play, @roles_root)
    end
    ex.key.must_equal("ansigenome_info")
    render = ex.render
    render.wont_be_nil
    # ansigenome_info: is the 3rd line of the heredoc's meta content.
    render.to_s.must_include("meta/main.yml:3:1")
    render.to_s.must_include("^ column 1")
  end

  it "still loads a meta/main.yml using only RoleMetadata's allowed keys" do
    # galaxy_info, dependencies, collections, argument_specs and
    # allow_duplicates are all on RoleMetadata's fattributes - the new
    # validation must not break the common shapes.
    build_role("good_meta", <<-YAML)
      galaxy_info:
        author: a
        description: d
        license: MIT
        min_ansible_version: "2.9"
      dependencies: []
      collections:
        - community.general
      argument_specs:
        main:
          short_description: do things
      allow_duplicates: false
      YAML

    tasks, _ = Krikri::RoleLoader.load_roles(roles_yaml("- good_meta"), fresh_play, @roles_root)
    tasks.map(&.name).must_equal(["hello"])
  end
end
