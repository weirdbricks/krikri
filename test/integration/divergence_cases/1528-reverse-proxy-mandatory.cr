describe "divergence corpus" do
  it "replays 1528-reverse-proxy-mandatory" do
    expected, actual, report = divergence_transcripts(1528, "reverse-proxy-mandatory")
    assert_equal(expected, actual, report)
  end
end
