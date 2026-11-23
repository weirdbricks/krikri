describe "divergence corpus" do
  it "replays 1641-hesidoryn-python-coreos-install-python-and-packages" do
    expected, actual, report = divergence_transcripts(1641, "hesidoryn-python-coreos-install-python-and-packages")
    assert_equal(expected, actual, report)
  end
end
