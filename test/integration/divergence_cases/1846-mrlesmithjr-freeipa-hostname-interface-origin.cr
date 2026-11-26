describe "divergence corpus" do
  it "replays 1846-mrlesmithjr-freeipa-hostname-interface-origin" do
    expected, actual, report = divergence_transcripts(1846, "mrlesmithjr-freeipa-hostname-interface-origin")
    assert_equal(expected, actual, report)
  end
end
