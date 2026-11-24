describe "divergence corpus" do
  it "replays 1769-pgkehle-hosts-ensure-the-hosts-block-exists-in-etc-hosts-remote" do
    expected, actual, report = divergence_transcripts(1769, "pgkehle-hosts-ensure-the-hosts-block-exists-in-etc-hosts-remote")
    assert_equal(expected, actual, report)
  end
end
