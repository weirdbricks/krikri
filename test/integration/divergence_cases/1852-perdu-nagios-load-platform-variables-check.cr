describe "divergence corpus" do
  it "replays 1852-perdu-nagios-load-platform-variables-check" do
    expected, actual, report = divergence_transcripts(1852, "perdu-nagios-load-platform-variables-check")
    assert_equal(expected, actual, report)
  end
end
