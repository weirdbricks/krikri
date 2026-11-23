describe "divergence corpus" do
  it "replays 1668-cameronbroe-nvm-check-whether-shell-profile-contains-nvm-sh" do
    expected, actual, report = divergence_transcripts(1668, "cameronbroe-nvm-check-whether-shell-profile-contains-nvm-sh")
    assert_equal(expected, actual, report)
  end
end
