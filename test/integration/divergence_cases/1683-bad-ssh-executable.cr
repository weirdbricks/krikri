describe "divergence corpus" do
  it "replays 1683-bad-ssh-executable" do
    expected, actual, report = divergence_transcripts(1683, "bad-ssh-executable")
    assert_equal(expected, actual, report)
  end
end
