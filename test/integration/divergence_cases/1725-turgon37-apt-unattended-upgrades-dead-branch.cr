describe "divergence corpus" do
  it "replays 1725-turgon37-apt-unattended-upgrades-dead-branch" do
    expected, actual, report = divergence_transcripts(1725, "turgon37-apt-unattended-upgrades-dead-branch")
    assert_equal(expected, actual, report)
  end
end
