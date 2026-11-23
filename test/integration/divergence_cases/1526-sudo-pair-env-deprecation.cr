describe "divergence corpus" do
  it "replays 1526-sudo-pair-env-deprecation" do
    expected, actual, report = divergence_transcripts(1526, "sudo-pair-env-deprecation")
    assert_equal(expected, actual, report)
  end
end
