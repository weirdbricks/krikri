describe "divergence corpus" do
  it "replays 1609-jedimt-haproxy-check-hostvars-fact" do
    expected, actual, report = divergence_transcripts(1609, "jedimt-haproxy-check-hostvars-fact")
    assert_equal(expected, actual, report)
  end
end
