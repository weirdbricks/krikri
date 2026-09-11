require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"
require "../../src/krikri/variable_substitutor/crinja_renderer"
require "../../src/krikri/jinja_filters"

# Real Ansible's ansible_mounts entries carry the space/inode stats
# (size_total, size_available, block_*, inode_*) as INTEGERS. This
# codebase's facts gatherer used to store them all as STRINGS, so any
# role doing real arithmetic on them in a .j2 template failed with
# Crinja's "Both operators need to be numeric" - mullholland.motd's
# motd.j2 does exactly that (`{{ (mnt.size_total / 1024 / 1024 /
# 1024) | round(1) }}`, round 300197): real ansible-playbook rendered
# the template fine, krikri failed the whole task.
describe "ansible_mounts stat types" do
  it "stores the space/inode stats as integers, like real Ansible" do
    facts = Krikri::FactsGatherer.gather_facts(["mounts"])

    mounts = facts["ansible_mounts"]?
    pending! "no mounts on this host" unless mounts.is_a?(Array(Hash(String, Int64 | String)))

    mounts.each do |mount|
      # Some kernel pseudo-filesystems (cgroup2, proc, ...) reject `stat -f`;
      # those entries legitimately carry only the string fields.
      next unless mount.has_key?("size_total")

      %w[size_total size_available block_size block_total block_available
         block_used inode_total inode_available inode_used].each do |key|
        value = mount[key]?
        value.should be_a(Int64), "#{key} should be an integer, got #{value.class} (#{value})"
      end
      %w[mount device fstype opts].each do |key|
        value = mount[key]?
        value.should be_a(String), "#{key} should be a string, got #{value.class}"
      end
    end
  end

  it "renders the mullholland.motd arithmetic template shape" do
    mounts_json = JSON.parse(%([
      {"device": "nvme0n1p1", "mount": "/", "fstype": "ext4", "opts": "rw",
       "size_total": 412316860416, "size_available": 300000000000,
       "block_size": 4096, "block_total": 100000000, "block_available": 73000000,
       "block_used": 27000000, "inode_total": 25000000, "inode_available": 19000000,
       "inode_used": 6000000},
      {"device": "vda2", "mount": "/boot", "fstype": "xfs", "opts": "rw",
       "size_total": 1024000000, "size_available": 500000000,
       "block_size": 4096, "block_total": 250000, "block_available": 122000,
       "block_used": 128000, "inode_total": 125000, "inode_available": 120000,
       "inode_used": 5000}
    ]))

    vars = {"ansible_mounts" => mounts_json}
    renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(vars)

    template = <<-TPL
      {% for mnt in ansible_mounts | sort(attribute='device') %}
      Mount: {{ mnt.device }}({{ mnt.mount }})({{ (mnt.size_total / 1024 / 1024 / 1024)| round(1) }}GB)
      {% endfor %}
      TPL

    rendered = renderer.render(template)
    rendered.should contain("nvme0n1p1")
    rendered.should contain("384.0GB")
    # sort(attribute='device'): 'n' < 'v', so nvme0n1p1 sorts first
    vda_pos = rendered.index("vda2").not_nil!
    nvme_pos = rendered.index("nvme0n1p1").not_nil!
    vda_pos.should be > nvme_pos
  end
end
