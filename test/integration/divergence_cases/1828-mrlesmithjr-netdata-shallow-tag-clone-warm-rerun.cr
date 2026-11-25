describe "divergence corpus" do
  it "replays 1828-mrlesmithjr-netdata-shallow-tag-clone-warm-rerun" do
    expected, actual, report = divergence_transcripts(1828, "mrlesmithjr-netdata-shallow-tag-clone-warm-rerun")
    assert_equal(expected, actual, report)
  end
end
