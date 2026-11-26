describe "divergence corpus" do
  it "replays 1850-billyrayvalentine-susefirewall-zypper-check" do
    expected, actual, report = divergence_transcripts(1850, "billyrayvalentine-susefirewall-zypper-check")
    assert_equal(expected, actual, report)
  end
end
