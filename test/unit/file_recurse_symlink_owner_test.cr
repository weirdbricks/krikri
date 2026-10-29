require "../minitest_helper"
require "file_utils"

# `file: recurse: yes` walks the tree with basic.py's set_owner_if_different/
# set_group_if_different, which read every entry with os.lstat and change it
# with os.lchown - for a symlink entry that is the LINK ITSELF, not its
# target. The follow:-driven os.path.realpath resolution lives only in
# load_file_common_arguments, which the recursive walk never re-calls per
# entry (it swaps each entry's path into the top-level file_args).
#
# Found benchmarking bmeme.mule (issue #432): install.yml deletes and
# recreates the version symlink /opt/mule/mule on every run, so at recurse
# time the link's own owner is still root while its target already belongs
# to mule - ansible-playbook reports changed on the
# "Ensure mule home has right permissions" task forever, while this engine
# stat-followed the link, saw the already-correct target and reported ok.
# Verified against ansible-playbook 2.19.11 before being encoded here: a
# tree where everything already matches except a symlink's OWN group
# reports changed (and converges the link), on the first AND every rerun
# until the link itself is corrected.

# A group the running user belongs to beyond its primary one - needed to
# give a freshly created symlink a group different from the requested one
# without root. When running as root, any existing group other than the
# primary works instead (root can chgrp anything).
RECURSE_LINK_GROUP = begin
  primary = `id -gn`.strip
  if PluginSpecHelper.running_as_root?
    File.read_lines("/etc/group")
      .compact_map { |line| line.split(":").first? }
      .find { |group| !group.empty? && group != primary }
  else
    `id -Gn`.split.find { |group| group != primary }
  end
end

# A symlink created inside a setgid directory inherits the DIRECTORY's
# group - the only way a non-root test can make a symlink's own group
# differ from its creator's primary group.
private def gid_of_group(group : String) : Int32
  `getent group #{group} | cut -d: -f3`.strip.to_i
end

private def build_recurse_link_tree(tree : String, link_group : String, primary_group : String) : String
  inner = File.join(tree, "inner")
  FileUtils.mkdir_p(inner)
  target = File.join(inner, "target.txt")
  File.write(target, "payload")
  File.chown(inner, gid: gid_of_group(link_group))
  File.chmod(inner, 0o2775)
  link = File.join(inner, "link")
  File.symlink("target.txt", link)
  File.chown(inner, gid: gid_of_group(primary_group))
  link
end

private def recurse_link_gid(path : String) : UInt32
  s = uninitialized LibC::Stat
  LibC.lstat(path, pointerof(s))
  s.st_gid
end

private def recurse_target_gid(path : String) : UInt32
  s = uninitialized LibC::Stat
  LibC.stat(path, pointerof(s))
  s.st_gid
end

describe "file recurse symlink own attributes (file_recurse_symlink_owner_test.cr)" do
  it "recurse reports changed and lchowns a symlink whose own group differs from the target's" do
    skip "needs a group distinct from the primary one" unless grp = RECURSE_LINK_GROUP
    user = `id -un`.strip
    primary_group = `id -gn`.strip
    tree = PluginSpecHelper.tmp_path("file-recurse-link", Random::Secure.hex(4))
    link = build_recurse_link_tree(tree, grp, primary_group)
    # The whole premise: only the LINK's own group is wrong; its target and
    # every other entry already match, so stat-following the link must NOT
    # be what decides `changed`.
    recurse_link_gid(link).must_equal(`getent group #{grp} | cut -d: -f3`.strip.to_u32)
    recurse_target_gid(link).must_equal(`getent group #{primary_group} | cut -d: -f3`.strip.to_u32)

    result = PluginSpecHelper.run("file", {
      "path"    => tree,
      "recurse" => "true",
      "owner"   => user,
      "group"   => primary_group,
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    recurse_link_gid(link).must_equal(`getent group #{primary_group} | cut -d: -f3`.strip.to_u32)
  ensure
    FileUtils.rm_rf(tree) if tree
  end

  it "recurse is idempotent once the symlink's own group is corrected" do
    skip "needs a group distinct from the primary one" unless grp = RECURSE_LINK_GROUP
    user = `id -un`.strip
    primary_group = `id -gn`.strip
    tree = PluginSpecHelper.tmp_path("file-recurse-link-idem", Random::Secure.hex(4))
    link = build_recurse_link_tree(tree, grp, primary_group)

    PluginSpecHelper.run("file", {
      "path"    => tree,
      "recurse" => "true",
      "owner"   => user,
      "group"   => primary_group,
    })

    result = PluginSpecHelper.run("file", {
      "path"    => tree,
      "recurse" => "true",
      "owner"   => user,
      "group"   => primary_group,
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
    recurse_link_gid(link).must_equal(`getent group #{primary_group} | cut -d: -f3`.strip.to_u32)
  ensure
    FileUtils.rm_rf(tree) if tree
  end

  it "recurse in check mode reports changed for a mismatched symlink without touching it" do
    skip "needs a group distinct from the primary one" unless grp = RECURSE_LINK_GROUP
    user = `id -un`.strip
    primary_group = `id -gn`.strip
    tree = PluginSpecHelper.tmp_path("file-recurse-link-check", Random::Secure.hex(4))
    link = build_recurse_link_tree(tree, grp, primary_group)

    result = PluginSpecHelper.run("file", {
      "path"                => tree,
      "recurse"             => "true",
      "owner"               => user,
      "group"               => primary_group,
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    recurse_link_gid(link).must_equal(`getent group #{grp} | cut -d: -f3`.strip.to_u32)
  ensure
    FileUtils.rm_rf(tree) if tree
  end
end
