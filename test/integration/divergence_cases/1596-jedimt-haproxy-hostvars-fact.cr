describe "divergence corpus" do
  it "replays 1596-jedimt-haproxy-hostvars-fact" do
    expected, actual, report = divergence_transcripts(1596, "jedimt-haproxy-hostvars-fact")
    assert_equal(expected, actual, report)
  end
end
