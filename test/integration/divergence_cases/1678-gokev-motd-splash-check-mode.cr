describe "divergence corpus" do
  it "replays 1678-gokev-motd-splash-check-mode" do
    expected, actual, report = divergence_transcripts(1678, "gokev-motd-splash-check-mode")
    assert_equal(expected, actual, report)
  end
end
