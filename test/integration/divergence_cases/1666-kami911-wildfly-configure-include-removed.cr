describe "divergence corpus" do
  it "replays 1666-kami911-wildfly-configure-include-removed" do
    expected, actual, report = divergence_transcripts(1666, "kami911-wildfly-configure-include-removed")
    assert_equal(expected, actual, report)
  end
end
