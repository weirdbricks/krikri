describe "divergence corpus" do
  it "replays 1851-mjcramer-java-shell-profile-check-mode" do
    expected, actual, report = divergence_transcripts(1851, "mjcramer-java-shell-profile-check-mode")
    assert_equal(expected, actual, report)
  end
end
