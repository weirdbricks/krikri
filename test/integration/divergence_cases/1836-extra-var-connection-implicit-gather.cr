describe "divergence corpus" do
  it "replays 1836-extra-var-connection-implicit-gather" do
    expected, actual, report = divergence_transcripts(1836, "extra-var-connection-implicit-gather")
    assert_equal(expected, actual, report)
  end
end
