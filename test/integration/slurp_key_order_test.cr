require "../minitest_helper"
require "file_utils"

# ansible-core 2.19.11's registered slurp result key order -
# live-verified via `{{ r | to_json }}` on a registered slurp: task:
# content, source, encoding, failed, changed - `failed: false` present
# and `changed` LAST (unlike every other module here, where failed
# trails). krikri's plugin emits failed: false explicitly (the
# failed_flag opt-in) so the reorder can place it before changed
# instead of the executor's missing-failed backfill appending it after.
describe "slurp plugin result key order" do
  it "serializes a successful read as content-source-encoding-failed-changed" do
    src = PluginSpecHelper.tmp_path("slurp-order.txt")
    File.write(src, "slurp me\n")

    result = PluginSpecHelper.run("slurp", {"src" => src})

    result["changed"].as_bool.must_equal(false)
    result["failed"].as_bool.must_equal(false)
    result["encoding"].as_s.must_equal("base64")
    result["content"].as_s.must_equal(Base64.strict_encode("slurp me\n"))
    result.as_h.keys.must_equal(["content", "source", "encoding", "failed", "changed"])
  ensure
    File.delete(src) if src && File.exists?(src)
  end
end
