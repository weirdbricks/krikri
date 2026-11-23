describe "divergence corpus" do
  it "replays 1742-siavashoutadi-virt-guest-libvirt-import" do
    expected, actual, report = divergence_transcripts(1742, "siavashoutadi-virt-guest-libvirt-import")
    assert_equal(expected, actual, report)
  end
end
