describe "divergence corpus" do
  it "replays 1775-babisk-kubectl-install-kubectl-from-snap" do
    expected, actual, report = divergence_transcripts(1775, "babisk-kubectl-install-kubectl-from-snap")
    assert_equal(expected, actual, report)
  end
end
