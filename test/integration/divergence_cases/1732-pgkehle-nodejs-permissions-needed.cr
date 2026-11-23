describe "divergence corpus" do
  it "replays 1732-pgkehle-nodejs-permissions-needed" do
    expected, actual, report = divergence_transcripts(1732, "pgkehle-nodejs-permissions-needed")
    assert_equal(expected, actual, report)
  end
end
