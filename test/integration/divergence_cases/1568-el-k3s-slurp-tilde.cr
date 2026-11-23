describe "divergence corpus" do
  it "replays 1568-el-k3s-slurp-tilde" do
    expected, actual, report = divergence_transcripts(1568, "el-k3s-slurp-tilde")
    assert_equal(expected, actual, report)
  end
end
