require "../minitest_helper"
require "../../src/krikri/role_loader"

# ansible-core's Role._load_role_data refuses the whole run (rc=4, single
# "[ERROR]:" line on STDERR, no play output, no Origin block) when a role's
# vars/main.yml or defaults/main.yml parses to anything but a mapping -
# CSCfi.sssd ships an INI-shaped defaults/main.yml that YAML folds into one
# long string (issue #1129), and this engine silently loaded it as an empty
# defaults hash and ran the role to completion instead (rc=2).
describe "role vars/defaults file not a dictionary (role_vars_not_dict_test.cr)" do
  # exclusive!, not serial! alone: the FQCN case re-points
  # ANSIBLE_COLLECTIONS_PATH, process-wide state every test in the suite
  # can see (the collection index consults it).
  exclusive!

  it "raises RoleVarsNotDictError for an INI-shaped defaults/main.yml" do
    root = PluginSpecHelper.tmp_path("role_vars_not_dict_spec")
    role_dir = File.join(root, "roles", "ini_defaults")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(role_dir, "defaults"))
    File.write(File.join(role_dir, "tasks", "main.yml"), "- name: noop\n  debug:\n    msg: hi\n")
    # Same shape CSCfi.sssd ships: key = value lines YAML folds into a
    # single multi-line plain scalar, not a mapping.
    File.write(File.join(role_dir, "defaults", "main.yml"), "---\n# defaults file\nldap_uri = \"ldaps://host1.example.com/\"\nldap_backup_uri = \"ldaps://host3.example.com\"\n")

    play = Krikri::Play.new("test play", "all")
    roles = YAML.parse("- ini_defaults").as_a
    ex = assert_raises(Krikri::RoleVarsNotDictError) do
      Krikri::RoleLoader.load_roles(roles, play, root)
    end
    # The <subdir>/main.yml wording is hardcoded in ansible-core, and no
    # Origin block is printed even though the file it read is known
    # (live-verified vs 2.21.6, issue #1129).
    ex.render.must_equal("[ERROR]: The defaults/main.yml file for role 'ini_defaults' must contain a dictionary of variables\n")
    ex.message.must_equal("The defaults/main.yml file for role 'ini_defaults' must contain a dictionary of variables")
  end

  it "checks vars/ before defaults/ and reports the vars file first" do
    root = PluginSpecHelper.tmp_path("role_vars_not_dict_spec_vars_first")
    role_dir = File.join(root, "roles", "both_bad")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(role_dir, "vars"))
    Dir.mkdir_p(File.join(role_dir, "defaults"))
    File.write(File.join(role_dir, "tasks", "main.yml"), "- name: noop\n  debug:\n    msg: hi\n")
    File.write(File.join(role_dir, "vars", "main.yml"), "- a\n- b\n")
    File.write(File.join(role_dir, "defaults", "main.yml"), "also a string\n")

    play = Krikri::Play.new("test play", "all")
    roles = YAML.parse("- both_bad").as_a
    ex = assert_raises(Krikri::RoleVarsNotDictError) do
      Krikri::RoleLoader.load_roles(roles, play, root)
    end
    # real validates vars/ first in _load_role_data (live-verified vs
    # 2.21.6), so the defaults file never gets reported.
    ex.render.must_equal("[ERROR]: The vars/main.yml file for role 'both_bad' must contain a dictionary of variables\n")
  end

  it "reports the short role name for a collection (FQCN) role" do
    root = PluginSpecHelper.tmp_path("role_vars_not_dict_spec_fqcn")
    # A collection-layout role under the collections path: real splits the
    # FQCN at resolution and the refusal names only the short role.
    coll_root = File.join(root, "colls")
    role_dir = File.join(coll_root, "ansible_collections", "testcoll", "coll", "roles", "badr")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(role_dir, "defaults"))
    File.write(File.join(role_dir, "tasks", "main.yml"), "- name: noop\n  debug:\n    msg: hi\n")
    File.write(File.join(role_dir, "defaults", "main.yml"), "not a mapping\n")

    saved_path = ENV["ANSIBLE_COLLECTIONS_PATH"]?
    ENV["ANSIBLE_COLLECTIONS_PATH"] = coll_root
    begin
      play = Krikri::Play.new("test play", "all")
      roles = YAML.parse("- testcoll.coll.badr").as_a
      ex = assert_raises(Krikri::RoleVarsNotDictError) do
        Krikri::RoleLoader.load_roles(roles, play, root)
      end
      ex.render.must_equal("[ERROR]: The defaults/main.yml file for role 'badr' must contain a dictionary of variables\n")
    ensure
      if saved_path
        ENV["ANSIBLE_COLLECTIONS_PATH"] = saved_path
      else
        ENV.delete("ANSIBLE_COLLECTIONS_PATH")
      end
    end
  end

  it "still loads a role whose vars files are comments-only (empty top level)" do
    root = PluginSpecHelper.tmp_path("role_vars_not_dict_spec_empty")
    role_dir = File.join(root, "roles", "empty_defaults")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(role_dir, "defaults"))
    File.write(File.join(role_dir, "tasks", "main.yml"), "- name: noop\n  debug:\n    msg: hi\n")
    # An empty file parses to nil in real, which is folded to {} - fine.
    File.write(File.join(role_dir, "defaults", "main.yml"), "---\n# nothing but a comment\n")

    play = Krikri::Play.new("test play", "all")
    roles = YAML.parse("- empty_defaults").as_a
    tasks, _ = Krikri::RoleLoader.load_roles(roles, play, root)
    tasks.size.must_equal(1)
  end
end
