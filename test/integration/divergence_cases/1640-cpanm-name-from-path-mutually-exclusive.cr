describe "divergence corpus" do
  it "replays 1640-cpanm-name-from-path-mutually-exclusive" do
    expected, actual, report = divergence_transcripts(1640, "cpanm-name-from-path-mutually-exclusive")
    assert_equal(expected, actual, report)
  end
end
