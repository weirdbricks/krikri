describe "divergence corpus" do
  it "replays 1610-juju4-vivisect-pip-check-executable" do
    expected, actual, report = divergence_transcripts(1610, "juju4-vivisect-pip-check-executable")
    assert_equal(expected, actual, report)
  end
end
