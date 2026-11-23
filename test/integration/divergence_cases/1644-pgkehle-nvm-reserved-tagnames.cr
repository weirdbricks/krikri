describe "divergence corpus" do
  it "replays 1644-pgkehle-nvm-reserved-tagnames" do
    expected, actual, report = divergence_transcripts(1644, "pgkehle-nvm-reserved-tagnames")
    assert_equal(expected, actual, report)
  end
end
