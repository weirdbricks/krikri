require "../minitest_helper"
require "../../src/krikri/base_plugin"

# PluginResult#key_order - the optional wire-key reorder that lets a
# module's serialized result match real Ansible's own dict insertion
# order (exit_json's msg/status_code kwargs lead, then the module's
# result dict, then add_path_info's stat block) instead of
# PluginResult's engine-wide fixed leading keys
# (changed/exception/failed/msg/diff). nil (the default, and what every
# plugin that has not opted in passes) must keep the historical order
# byte-for-byte, so this test pins both halves.
#
# The real-order reference here is command-module-shaped (see the
# get_url integration test for a live-verified module order): krikri's
# command plugin wire result is changed, exception, failed, msg, then
# the module keys, while real's registered command result runs
# changed, stdout, stderr, rc, cmd, start, end, delta, failed, msg, ...
# (verified against ansible-core 2.19.11 via `{{ r | to_json }}`).
describe "PluginResult#key_order" do
  it "keeps the historical key order exactly when key_order is nil" do
    result = Krikri::PluginResult.new(changed: true, failed: false, msg: "done", dest: "/tmp/x", size: 3)
    JSON.parse(result.to_json).as_h.keys.must_equal([
      "changed", "msg", "dest", "size",
    ])
  end

  it "emits the listed keys first, in the listed order" do
    result = Krikri::PluginResult.new(
      changed: true, failed: false, msg: "OK", dest: "/tmp/x", size: 3,
      key_order: ["msg", "changed", "dest", "size"],
    )
    JSON.parse(result.to_json).as_h.keys.must_equal([
      "msg", "changed", "dest", "size",
    ])
  end

  it "skips listed keys the result does not carry" do
    result = Krikri::PluginResult.new(
      changed: true, failed: false, msg: "OK", dest: "/tmp/x",
      key_order: ["msg", "status_code", "elapsed", "changed", "dest"],
    )
    JSON.parse(result.to_json).as_h.keys.must_equal([
      "msg", "changed", "dest",
    ])
  end

  it "appends unlisted keys after the listed ones, in their current order" do
    result = Krikri::PluginResult.new(
      changed: true, failed: false, msg: "OK", dest: "/tmp/x", size: 3, url: "http://h/f",
      key_order: ["url", "changed"],
    )
    JSON.parse(result.to_json).as_h.keys.must_equal([
      "url", "changed", "msg", "dest", "size",
    ])
  end

  it "reorders a failed result's fixed keys the same way, exception included" do
    result = Krikri::PluginResult.new(changed: false, failed: true, msg: "boom", url: "http://h/f", key_order: ["msg", "url"])
    JSON.parse(result.to_json).as_h.keys.must_equal([
      "msg", "url", "changed", "exception", "failed",
    ])
  end

  it "emits real's plain fail_json order by default for a failed result without key_order" do
    # live-verified against 2.19.11 across slurp/stat/file/fail/service/
    # getent/mount plain failures: failed, msg, changed, exception
    result = Krikri::PluginResult.new(changed: false, failed: true, msg: "boom", url: "http://h/f")
    JSON.parse(result.to_json).as_h.keys.must_equal([
      "failed", "msg", "url", "changed", "exception",
    ])
  end

  it "keeps extras ahead of the trailing changed/exception in the default failed order" do
    result = Krikri::PluginResult.new(changed: false, failed: true, msg: "boom", rc: 257, elapsed: 1)
    JSON.parse(result.to_json).as_h.keys.must_equal([
      "failed", "msg", "rc", "elapsed", "changed", "exception",
    ])
  end

  it "keeps native-msg and diff results reorderable" do
    native = JSON.parse("42")
    diff = JSON.parse(%({"before": "a", "after": "b"}))
    result = Krikri::PluginResult.new(changed: true, failed: false, native_msg: native, diff: diff, key_order: ["diff", "msg", "changed"])
    parsed = JSON.parse(result.to_json).as_h
    parsed.keys.must_equal(["diff", "msg", "changed"])
    parsed["msg"].as_i.must_equal(42)
  end
end
