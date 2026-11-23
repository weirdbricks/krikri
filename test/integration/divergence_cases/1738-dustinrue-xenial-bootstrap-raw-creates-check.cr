describe "divergence corpus" do
  it "replays 1738-dustinrue-xenial-bootstrap-raw-creates-check" do
    expected, actual, report = divergence_transcripts(1738, "dustinrue-xenial-bootstrap-raw-creates-check")
    assert_equal(expected, actual, report)
  end
end
