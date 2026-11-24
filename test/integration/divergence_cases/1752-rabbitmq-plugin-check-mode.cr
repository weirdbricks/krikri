describe "divergence corpus" do
  it "replays 1752-rabbitmq-plugin-check-mode" do
    expected, actual, report = divergence_transcripts(1752, "rabbitmq-plugin-check-mode")
    assert_equal(expected, actual, report)
  end
end
