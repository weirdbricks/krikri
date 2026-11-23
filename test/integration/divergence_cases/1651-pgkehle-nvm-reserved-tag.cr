describe "divergence corpus" do
  it "replays 1651-pgkehle-nvm-reserved-tag" do
    expected, actual, report = divergence_transcripts(1651, "pgkehle-nvm-reserved-tag")
    assert_equal(expected, actual, report)
  end
end
