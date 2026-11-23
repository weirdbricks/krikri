describe "divergence corpus" do
  it "replays 1575-amtega-gitlab-fork-get-projects-info" do
    expected, actual, report = divergence_transcripts(1575, "amtega-gitlab-fork-get-projects-info")
    assert_equal(expected, actual, report)
  end
end
