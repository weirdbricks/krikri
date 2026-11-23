describe "divergence corpus" do
  it "replays 1593-dorancemc-ansible-nagioscore-install-rrdtool-packages" do
    expected, actual, report = divergence_transcripts(1593, "dorancemc-ansible-nagioscore-install-rrdtool-packages")
    assert_equal(expected, actual, report)
  end
end
