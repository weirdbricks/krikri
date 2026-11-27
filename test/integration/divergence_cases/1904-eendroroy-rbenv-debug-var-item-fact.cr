describe "divergence corpus" do
  it "replays 1904-eendroroy-rbenv-debug-var-item-fact" do
    expected, actual, report = divergence_transcripts(1904, "eendroroy-rbenv-debug-var-item-fact")
    assert_equal(expected, actual, report)
  end
end
