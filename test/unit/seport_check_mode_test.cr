require "../minitest_helper"

# community.general.seport under --check must answer "changed" from the
# same read-only queries real seport.py uses and never run the mutating
# `semanage port -a/-m/-d` call (issue #757): an already-mapped port 22
# reported changed, and an unassigned port 4999 failed outright because
# the plugin's containment-based lookup sent it to `semanage port -m`,
# which real semanage rejects with "ValueError: Port tcp/4999 is not
# defined". The fake getenforce/semanage on PATH stand in for a real
# SELinux host; the journal records every mutation the plugin attempts.
describe "seport check mode and port-ownership semantics" do
  LISTING = <<-LISTING
    SELinux Port Type              Proto    Port Number
    reserved_port_t                tcp      1-511
    ssh_port_t                     tcp      22
    unreserved_port_t              tcp      1024-32767
    LISTING

  def with_fake_selinux
    bin = PluginSpecHelper.tmp_path("bin")
    Dir.mkdir_p(bin)
    listing = PluginSpecHelper.tmp_path("listing")
    File.write(listing, LISTING)
    File.write(File.join(bin, "getenforce"), "#!/bin/bash\necho Enforcing\n")
    File.write(File.join(bin, "semanage"), <<-SH)
      #!/bin/bash
      if [ "$1 $2" = "port -l" ]; then
        cat "$KRIKRI_SEPORT_FAKE_LISTING"
        exit 0
      fi
      echo "$*" >> "$KRIKRI_SEPORT_FAKE_JOURNAL"
      exit 0
      SH
    File.chmod(File.join(bin, "getenforce"), 0o755)
    File.chmod(File.join(bin, "semanage"), 0o755)
    {bin: bin, listing: listing}
  end

  def run_seport(params, fake, journal)
    PluginSpecHelper.run("seport", params, env: {
      "PATH"                       => "#{fake[:bin]}:#{ENV["PATH"]}",
      "KRIKRI_SEPORT_FAKE_JOURNAL" => journal,
      "KRIKRI_SEPORT_FAKE_LISTING" => fake[:listing],
    })
  end

  it "reports ok for an already-mapped port under --check without mutating" do
    fake = with_fake_selinux
    journal = PluginSpecHelper.tmp_path("journal_mapped")
    result = run_seport({
      "ports"               => "22",
      "proto"               => "tcp",
      "setype"              => "ssh_port_t",
      "state"               => "present",
      "_ansible_check_mode" => "true",
    }, fake, journal)

    result["changed"].as_bool.must_equal(false)
    File.exists?(journal).must_equal(false)
  end

  it "reports changed for an unassigned port inside another type's range under --check without mutating" do
    fake = with_fake_selinux
    journal = PluginSpecHelper.tmp_path("journal_unassigned")
    result = run_seport({
      "ports"               => "4999",
      "proto"               => "tcp",
      "setype"              => "ssh_port_t",
      "state"               => "present",
      "_ansible_check_mode" => "true",
    }, fake, journal)

    result["changed"].as_bool.must_equal(true)
    File.exists?(journal).must_equal(false)
  end

  it "reports changed for an exact-entry absent under --check without mutating" do
    fake = with_fake_selinux
    journal = PluginSpecHelper.tmp_path("journal_absent")
    result = run_seport({
      "ports"               => "22",
      "proto"               => "tcp",
      "setype"              => "ssh_port_t",
      "state"               => "absent",
      "_ansible_check_mode" => "true",
    }, fake, journal)

    result["changed"].as_bool.must_equal(true)
    File.exists?(journal).must_equal(false)
  end

  it "takes the add path (not modify) for an unassigned port on a real run" do
    fake = with_fake_selinux
    journal = PluginSpecHelper.tmp_path("journal_add")
    result = run_seport({
      "ports"  => "4999",
      "proto"  => "tcp",
      "setype" => "ssh_port_t",
      "state"  => "present",
    }, fake, journal)

    result["changed"].as_bool.must_equal(true)
    journal_text = File.read(journal)
    journal_text.includes?("-a -t").must_equal(true)
    journal_text.includes?("-m -t").must_equal(false)
  end

  it "reports ok for a port covered by the target type's own range on a real run" do
    fake = with_fake_selinux
    journal = PluginSpecHelper.tmp_path("journal_covered")
    result = run_seport({
      "ports"  => "22",
      "proto"  => "tcp",
      "setype" => "reserved_port_t",
      "state"  => "present",
    }, fake, journal)

    result["changed"].as_bool.must_equal(false)
    File.exists?(journal).must_equal(false)
  end
end
