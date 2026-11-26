describe "divergence corpus" do
  it "replays 1847-perdu-nagios-load-platform-variables" do
    expected, actual, report = divergence_transcripts(1847, "perdu-nagios-load-platform-variables")
    assert_equal(expected, actual, report)
  end
end
