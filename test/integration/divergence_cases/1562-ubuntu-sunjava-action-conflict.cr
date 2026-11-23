describe "divergence corpus" do
  it "replays 1562-ubuntu-sunjava-action-conflict" do
    expected, actual, report = divergence_transcripts(1562, "ubuntu-sunjava-action-conflict")
    assert_equal(expected, actual, report)
  end
end
