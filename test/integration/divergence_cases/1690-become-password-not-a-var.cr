describe "divergence corpus" do
  it "replays 1690-become-password-not-a-var" do
    expected, actual, report = divergence_transcripts(1690, "become-password-not-a-var")
    assert_equal(expected, actual, report)
  end
end
