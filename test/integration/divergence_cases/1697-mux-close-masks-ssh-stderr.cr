describe "divergence corpus" do
  it "replays 1697-mux-close-masks-ssh-stderr" do
    expected, actual, report = divergence_transcripts(1697, "mux-close-masks-ssh-stderr")
    assert_equal(expected, actual, report)
  end
end
