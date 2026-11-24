describe "divergence corpus" do
  it "replays 1752-rabbitmq-plugin-enable-failure" do
    expected, actual, report = divergence_transcripts(1752, "rabbitmq-plugin-enable-failure")
    assert_equal(expected, actual, report)
  end
end
