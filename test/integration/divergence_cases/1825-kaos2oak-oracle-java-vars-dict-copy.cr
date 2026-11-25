describe "divergence corpus" do
  it "replays 1825-kaos2oak-oracle-java-vars-dict-copy" do
    expected, actual, report = divergence_transcripts(1825, "kaos2oak-oracle-java-vars-dict-copy")
    assert_equal(expected, actual, report)
  end
end
