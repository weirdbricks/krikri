describe "divergence corpus" do
  it "replays 1762-basecomponent-docker-yum-install-failure" do
    expected, actual, report = divergence_transcripts(1762, "basecomponent-docker-yum-install-failure")
    assert_equal(expected, actual, report)
  end
end
