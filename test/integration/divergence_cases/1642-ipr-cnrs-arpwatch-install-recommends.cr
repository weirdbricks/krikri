describe "divergence corpus" do
  it "replays 1642-ipr-cnrs-arpwatch-install-recommends" do
    expected, actual, report = divergence_transcripts(1642, "ipr-cnrs-arpwatch-install-recommends")
    assert_equal(expected, actual, report)
  end
end
