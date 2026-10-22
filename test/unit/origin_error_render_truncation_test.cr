require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# Issue #233: the `[ERROR]` + Origin block for a task-level error (e.g. a
# removed `include:`) echoed an over-long context line in full, where
# ansible-core's SourceContext cuts it to 120 columns with a `...` marker.
describe "PlaybookParser.origin_error_render_at long context lines (issue 233)" do
  it "truncates a source line wider than 120 columns like ansible" do
    dir = PluginSpecHelper.tmp_path("origin_error_render_truncation")
    Dir.mkdir_p(dir)
    path = File.join(dir, "main.yml")
    long = "  get_url: dest=/usr/bin/dumb-init url=https://github.com/Yelp/dumb-init/releases/download/v1.0.2/dumb-init_1.0.2_amd64 mode=0775 validate_certs=no"
    File.write(path, "---\n- name: Install dumb init\n#{long}\n- include: x.yml\n")

    rendered = Krikri::PlaybookParser.origin_error_render_at("boom", path, nil, {4, 3})

    assert_includes rendered, "3   get_url: dest=/usr/bin/dumb-init url=https://github.com/Yelp/dumb-init/releases/download/v1.0.2/dumb-init_1.0.2_a...\n"
    refute_includes rendered, "validate_certs"
    assert_includes rendered, "    ^ column 3\n"
  end
end
