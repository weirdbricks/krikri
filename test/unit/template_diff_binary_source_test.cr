require "../minitest_helper"
require "file_utils"

# `template:` --diff/--check with a SOURCE that is not text. Real's
# ActionBase#_get_diff_data replaces the after side with a `src_binary`
# marker when the staged source holds a NUL byte, and the callback then
# prints only "diff skipped: source file appears to be binary" - no
# before/after content at all (live-verified vs ansible-core 2.21.6:
# a binary.bin template beside an ordinary dest, issue #1619).
# The plugin used to emit the raw source bytes as a diff instead.
describe "template: --diff with a binary source" do
  it "reports the source-binary skip marker instead of a byte diff" do
    dir = File.tempname("template-diff-binary-source")
    Dir.mkdir_p(dir)
    begin
      dest = File.join(dir, "dest.txt")
      File.write(dest, "kpg locked dest\nsecond line\n")

      result = PluginSpecHelper.run("template", {
        "_ansible_check_mode" => "true",
        "_ansible_diff"       => "true",
        "dest"                => dest,
        # The action plugin's twin-escaped render of a non-UTF-8 source
        # (see SurrogateEscape); 0xff becomes U+F7FF.
        "content"                    => "\u0000\u0001kpg\u0000binary\u{F7FF}\n",
        "_rendered_from_template"    => File.join(dir, "binary.bin"),
        "_template_surrogate_escape" => "1",
      })

      result["changed"].as_bool.must_equal(true)
      # template's diff payload is a one-entry LIST (copy's action builds
      # it), like real ansible's.
      entry = result["diff"].as_a.first.as_h
      entry["src_binary"].as_i.must_equal(1)
      entry.has_key?("after").must_equal(false)
      entry.has_key?("after_header").must_equal(false)
      entry["before_header"].as_s.must_equal(dest)
      entry["before"].as_s.must_equal("kpg locked dest\nsecond line\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
