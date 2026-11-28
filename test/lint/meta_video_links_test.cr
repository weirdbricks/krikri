require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe MetaVideoLinksRule do
    private def rule
      MetaVideoLinksRule.new
    end

    # Upstream only classifies `<role>/meta/main.yml` as kind meta, so the
    # rule's early return is driven by the path as well as FileType.
    private def meta_violations(yaml : String, path : String? = nil) : Array(Violation)
      # A fresh unique DIRECTORY, not File.tempname's dirname: with the
      # default tempdir that dirname is /tmp itself, and the rm_rf in the
      # ensure would delete the whole /tmp mid-suite.
      dir = File.tempname("metavideolinksspec")
      Dir.mkdir(dir)
      meta_dir = File.join(dir, "meta")
      Dir.mkdir(meta_dir)
      meta_path = File.join(meta_dir, "main.yml")
      File.write(meta_path, yaml)
      target = path || meta_path
      file = PositionedFile.new(target, FileType::META,
        YAML::Nodes.parse(yaml).nodes.first?, nil)
      violations = [] of Violation
      rule.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "flags each bad URL at the url value's line and column" do
      v = meta_violations(
        "galaxy_info:\n  author: triage\n" \
        "  description: fixture for meta-video-links URL format checks\n" \
        "  license: MIT\n  min_ansible_version: \"2.9\"\n  video_links:\n" \
        "    - url: https://www.youtube.com/watch?v=aWmRepTSFKs&feature=youtu.be\n" \
        "      title: Not a shared link\n" \
        "    - url: www.acme.com/vid\n      title: Not a URL at all\n" \
        "dependencies: []\n")
      v.size.must_equal(2)
      v.map(&.message).must_equal([
        "URL format 'https://www.youtube.com/watch?v=aWmRepTSFKs&feature=youtu.be' " \
        "is not recognized. Expected it be a shared link from Vimeo, YouTube, or Google Drive.",
        "URL format 'www.acme.com/vid' is not recognized. " \
        "Expected it be a shared link from Vimeo, YouTube, or Google Drive.",
      ])
      v.map { |violation| {violation.line, violation.column} }.must_equal([{7, 12}, {9, 12}])
      v.each do |violation|
        violation.rule_id.must_equal("meta-video-links")
        violation.severity.must_equal(Severity::LOW)
      end
    end

    it "accepts each provider's shared-link form" do
      meta_violations(
        "galaxy_info:\n  video_links:\n" \
        "    - url: https://youtu.be/aWmRepTSFKs\n" \
        "    - url: https://vimeo.com/76979871\n" \
        "    - url: https://drive.google.com/file/d/abcDEF_-123/view?usp=sharing\n" \
        "dependencies: []\n").must_be_empty
    end

    it "accepts links upstream's prefix match accepts" do
      meta_violations(
        "galaxy_info:\n  video_links:\n" \
        "    - url: https://vimeo.com/76979871/extra\n" \
        "    - url: https://youtu.be/aWmRepTSFKs?t=42\n").must_be_empty
    end

    it "ignores an empty or missing video_links" do
      meta_violations("galaxy_info:\n  video_links: []\n").must_be_empty
      meta_violations("galaxy_info:\n  author: me\n").must_be_empty
    end

    it "ignores a non-list video_links" do
      meta_violations("galaxy_info:\n  video_links: https://youtu.be/aWmRepTSFKs\n").must_be_empty
    end

    it "ignores files that are not meta/main.yml" do
      meta_violations("galaxy_info:\n  video_links:\n    - url: www.acme.com/vid\n",
        path: "/tmp/role/meta/other.yml").must_be_empty
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("meta-video-links").wont_be_nil
      Profile.of("meta-video-links").must_equal("shared")
      rule.severity.must_equal(Severity::LOW)
      rule.tags.must_equal(["metadata"])
    end
  end
end
