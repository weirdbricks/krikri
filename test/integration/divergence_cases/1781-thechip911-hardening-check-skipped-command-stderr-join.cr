describe "divergence corpus" do
  it "replays 1781-thechip911-hardening-check-skipped-command-stderr-join" do
    expected, actual, report = divergence_transcripts(1781, "thechip911-hardening-check-skipped-command-stderr-join")
    assert_equal(expected, actual, report)
  end
end
