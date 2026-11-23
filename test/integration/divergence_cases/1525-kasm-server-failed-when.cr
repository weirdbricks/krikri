describe "divergence corpus" do
  it "replays 1525-kasm-server-failed-when" do
    expected, actual, report = divergence_transcripts(1525, "kasm-server-failed-when")
    assert_equal(expected, actual, report)
  end
end
