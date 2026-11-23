describe "divergence corpus" do
  it "replays 1573-freebsd-ports-default-fact" do
    expected, actual, report = divergence_transcripts(1573, "freebsd-ports-default-fact")
    assert_equal(expected, actual, report)
  end
end
