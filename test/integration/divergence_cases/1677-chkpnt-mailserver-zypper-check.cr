describe "divergence corpus" do
  it "replays 1677-chkpnt-mailserver-zypper-check" do
    expected, actual, report = divergence_transcripts(1677, "chkpnt-mailserver-zypper-check")
    assert_equal(expected, actual, report)
  end
end
