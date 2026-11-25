describe "divergence corpus" do
  it "replays 1827-consul-config-dict-fact-blocks" do
    expected, actual, report = divergence_transcripts(1827, "consul-config-dict-fact-blocks")
    assert_equal(expected, actual, report)
  end
end
