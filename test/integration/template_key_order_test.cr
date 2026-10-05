require "../minitest_helper"
require "file_utils"

# ansible-core 2.19.11's registered template result key orders -
# live-verified via `{{ r | to_json }}` on registered template: tasks
# (the -v dump sorts alphabetically, so the order is only observable
# programmatically). The template ACTION plugin delegates to the copy
# module, so the orders are copy-shaped: the changed path runs diff,
# dest, src, md5sum, checksum, changed (, backup_file), then the
# add_path_info stat block and failed: false; the equal-content rerun
# (run and --check alike) runs diff, path, changed, the stat block,
# then checksum and dest; the force-false existing-dest no-op is bare
# dest/src/changed (Ansible emits no diff there - krikri's
# always-present empty-list diff trails, matching copy's own
# documented noop gap); the check-mode would-change is the action-level
# bare diff/changed. Ansible's src is its staged .source.txt tempfile
# path; krikri echoes the rendered-source path the action plugin sent
# along (_rendered_from_template). failed: false is backfilled by the
# executor after the plugin JSON, so the plugin-level pins below omit
# it - Ansible's own orders all end with failed.
describe "template plugin result key order" do
  it "serializes a fresh template success in real copy's changed key order with src leading md5sum" do
    dest = PluginSpecHelper.tmp_path("template-order-fresh.txt")

    result = PluginSpecHelper.run("template", {
      "content"                 => "rendered\n",
      "dest"                    => dest,
      "_rendered_from_template" => "/tmp/rendered-src.j2",
    })

    result["changed"].as_bool.must_equal(true)
    result["src"].as_s.must_equal("/tmp/rendered-src.j2")
    result.as_h.keys.must_equal([
      "diff", "dest", "src", "md5sum", "checksum", "changed",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes the equal-content rerun in real copy's unchanged key order (path leads, checksum/dest trail)" do
    dest = PluginSpecHelper.tmp_path("template-order-equal.txt")
    params = {
      "content"                 => "same\n",
      "dest"                    => dest,
      "_rendered_from_template" => "/tmp/rendered-src.j2",
    }
    PluginSpecHelper.run("template", params)
    result = PluginSpecHelper.run("template", params)

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "diff", "path", "changed", "uid", "gid", "owner", "group", "mode", "state", "size",
      "checksum", "dest",
    ])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes a force-false existing-dest no-op as bare dest/src/changed (krikri's always-present diff trails)" do
    dest = PluginSpecHelper.tmp_path("template-order-forcefalse.txt")
    PluginSpecHelper.run("template", {"content" => "kept\n", "dest" => dest, "_rendered_from_template" => "/tmp/a.j2"})
    result = PluginSpecHelper.run("template", {
      "content"                 => "other\n",
      "dest"                    => dest,
      "force"                   => "false",
      "_rendered_from_template" => "/tmp/b.j2",
    })

    result["changed"].as_bool.must_equal(false)
    # Ansible's result here has no msg key at all - the dropped
    # "File already exists" msg must stay gone.
    result.as_h.has_key?("msg").must_equal(false)
    result.as_h.keys.must_equal(["dest", "src", "changed", "diff"])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes a check-mode would-change result with diff leading" do
    dest = PluginSpecHelper.tmp_path("template-order-check.txt")

    result = PluginSpecHelper.run("template", {
      "content"                 => "check\n",
      "dest"                    => dest,
      "_rendered_from_template" => "/tmp/c.j2",
      "_ansible_check_mode"     => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
    result.as_h.keys.must_equal(["diff", "changed"])
  end

  it "serializes a check-mode equal-content run in the unchanged key order" do
    dest = PluginSpecHelper.tmp_path("template-order-check-equal.txt")
    params = {
      "content"                 => "same\n",
      "dest"                    => dest,
      "_rendered_from_template" => "/tmp/d.j2",
    }
    PluginSpecHelper.run("template", params)
    result = PluginSpecHelper.run("template", params.merge({"_ansible_check_mode" => "true"}))

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "diff", "path", "changed", "uid", "gid", "owner", "group", "mode", "state", "size",
      "checksum", "dest",
    ])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
