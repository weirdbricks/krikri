describe "divergence corpus" do
  it "replays 1675-kami911-wildfly-configure-include-removed-check" do
    expected, actual, report = divergence_transcripts(1675, "kami911-wildfly-configure-include-removed-check")
    assert_equal(expected, actual, report)
  end
end
