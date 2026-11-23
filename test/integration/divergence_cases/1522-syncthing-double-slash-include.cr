describe "divergence corpus" do
  it "replays 1522-syncthing-double-slash-include" do
    expected, actual, report = divergence_transcripts(1522, "syncthing-double-slash-include")
    assert_equal(expected, actual, report)
  end
end
