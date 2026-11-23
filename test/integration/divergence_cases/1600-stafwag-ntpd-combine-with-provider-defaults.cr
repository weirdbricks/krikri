describe "divergence corpus" do
  it "replays 1600-stafwag-ntpd-combine-with-provider-defaults" do
    expected, actual, report = divergence_transcripts(1600, "stafwag-ntpd-combine-with-provider-defaults")
    assert_equal(expected, actual, report)
  end
end
