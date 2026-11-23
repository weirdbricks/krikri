describe "divergence corpus" do
  it "replays 1724-package-facts-rpm-cli" do
    expected, actual, report = divergence_transcripts(1724, "package-facts-rpm-cli")
    assert_equal(expected, actual, report)
  end
end
