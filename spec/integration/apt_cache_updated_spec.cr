require "../spec_helper"
require "../../src/krikri/conditional_evaluator"
require "file_utils"

# Regression spec for the `apt` module's `cache_updated` result key
# (0.9.862). Real Ansible's apt module ALWAYS includes `cache_updated` in
# exit_json - true only when its get_updated_cache_time() before/after
# mtime diff shows the cache was genuinely refreshed - and the very
# common `changed_when: apt_cache.cache_updated` idiom (hifis.gitlab's
# own cache-refresh task) hard-fails with "object of type 'dict' has no
# attribute 'cache_updated'" the moment a registered result lacks the
# key, which is exactly how krikri-playbook failed that role.

# Builds a stub PATH dir whose `apt-get` always exits 0 and whose `stat`
# reports a lists-dir mtime that moves on the call AFTER the first one
# (when KRIKRI_FAKE_MOVE is set) or never moves otherwise - simulating,
# without touching the real /var/lib/apt or needing root, exactly the
# before/after mtime pair the plugin diffs to decide cache_updated.
# Yields the PATH value to embed in the plugin's `environment:` param.
private def with_stub_path(move : Bool, &) : Nil
  dir = File.join(Dir.tempdir, "krikri-apt-cache-updated-#{Random.rand(1_000_000)}")
  stamp = File.join(dir, "fake-stamp")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\nexit 0\n")
  stat_shim = if move
                "#!/bin/sh\nif [ -f \"$KRIKRI_FAKE_STAMP\" ]; then echo 200; else echo 100; touch \"$KRIKRI_FAKE_STAMP\"; fi\n"
              else
                "#!/bin/sh\necho 100\n"
              end
  File.write(File.join(dir, "stat"), stat_shim)
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  yield "#{dir}:/usr/bin:/bin", stamp
ensure
  FileUtils.rm_rf(dir) if dir
end

private def env_param(path : String, stamp : String) : String
  {"PATH" => path, "KRIKRI_FAKE_STAMP" => stamp}.to_json
end

describe "apt plugin cache_updated result key" do
  it "reports cache_updated: false when update_cache is not requested" do
    result = PluginSpecHelper.run("apt", {"update_cache" => "false", "check_mode" => "true"})

    result["cache_updated"]?.should_not be_nil
    result["cache_updated"].as_bool.should be_false
  end

  it "reports cache_updated: false when the cache is already fresh (cache_valid_time not exceeded)" do
    result = PluginSpecHelper.run("apt", {
      "update_cache"     => "true",
      "cache_valid_time" => "999999999",
      "check_mode"       => "true",
    })

    result["cache_updated"]?.should_not be_nil
    result["cache_updated"].as_bool.should be_false
  end

  it "reports cache_updated: false in check mode (the update never actually ran)" do
    result = PluginSpecHelper.run("apt", {"update_cache" => "true", "check_mode" => "true"})

    result["cache_updated"]?.should_not be_nil
    result["cache_updated"].as_bool.should be_false
  end

  it "reports cache_updated: true when the update genuinely moved the cache mtime" do
    with_stub_path(move: true) do |path, stamp|
      result = PluginSpecHelper.run("apt", {
        "update_cache" => "true",
        "_environment" => env_param(path, stamp),
      })

      result["cache_updated"]?.should_not be_nil
      result["cache_updated"].as_bool.should be_true
    end
  end

  it "reports cache_updated: false when the update ran but the mtime did not move (already-fresh mirror)" do
    with_stub_path(move: false) do |path, stamp|
      result = PluginSpecHelper.run("apt", {
        "update_cache" => "true",
        "_environment" => env_param(path, stamp),
      })

      result["cache_updated"]?.should_not be_nil
      result["cache_updated"].as_bool.should be_false
      result["changed"].as_bool.should be_false
    end
  end

  # 0ta2.php_role's "Install extra package." (round 84000): `name: '{{
  # php_packages_extra }}'` with the var defaulting to `[]` templates to
  # the literal string "[]" - a `name:` KEY that IS present (so the "no
  # name: at all" branch never fired) but parses down to an empty package
  # list. Real Ansible's apt module folds a genuine cache refresh's own
  # changed: into this case exactly the same as no name: given at all;
  # this engine fell through into the packages-present install path with
  # an empty list and lost the cache-update changed: entirely, reporting
  # ok when real Ansible reported changed.
  it "folds a genuine cache refresh's changed: into an empty (not absent) name: list" do
    with_stub_path(move: true) do |path, stamp|
      result = PluginSpecHelper.run("apt", {
        "name"         => "[]",
        "update_cache" => "true",
        "_environment" => env_param(path, stamp),
      })

      result["changed"].as_bool.should be_true
      result["cache_updated"].as_bool.should be_true
    end
  end

  it "is a no-op for an empty name: list with no update_cache:" do
    result = PluginSpecHelper.run("apt", {"name" => "[]"})

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should be_falsey
  end
end

describe "changed_when: apt_cache.cache_updated on a registered apt result" do
  # The exact hifis.gitlab failure shape: a strict (changed_when:)
  # evaluation of a registered result dict. Before 0.9.862 the key was
  # missing from the plugin's JSON entirely and every one of these
  # raised "object of type 'dict' has no attribute 'cache_updated'".
  it "evaluates to the cache-refresh state without raising" do
    fresh = Hash(String, JSON::Any).new
    fresh["apt_cache"] = JSON.parse({
      "changed" => true, "failed" => false, "msg" => "APT cache updated",
      "cache_updated" => true,
    }.to_json)
    Krikri::ConditionalEvaluator.evaluate(
      "apt_cache.cache_updated", fresh, strict: true, raise_undefined: true
    ).should be_true

    unchanged = Hash(String, JSON::Any).new
    unchanged["apt_cache"] = JSON.parse({
      "changed" => false, "failed" => false, "msg" => "Cache up to date",
      "cache_updated" => false,
    }.to_json)
    Krikri::ConditionalEvaluator.evaluate(
      "apt_cache.cache_updated", unchanged, strict: true, raise_undefined: true
    ).should be_false
  end

  it "still raises the real-Ansible-style error for a result dict that genuinely lacks the key" do
    v = Hash(String, JSON::Any).new
    v["apt_cache"] = JSON.parse({"changed" => false, "failed" => false, "msg" => "x"}.to_json)
    ex = expect_raises(Krikri::ConditionalEvaluator::UndefinedVariableError) do
      Krikri::ConditionalEvaluator.evaluate(
        "apt_cache.cache_updated", v, strict: true, raise_undefined: true
      )
    end
    ex.message.should eq("object of type 'dict' has no attribute 'cache_updated'")
  end
end
