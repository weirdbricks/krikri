describe "divergence corpus" do
  it "replays 1521-k8sworker-yaml-parse-case" do
    expected, actual, report = divergence_transcripts(1521, "k8sworker-yaml-parse-case")
    assert_equal(expected, actual, report)
  end
end
