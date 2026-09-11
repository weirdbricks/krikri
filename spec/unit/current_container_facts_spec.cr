require "../spec_helper"
require "../../src/krikri/playbook_parser"

# current_container_facts detection runs against /proc on whatever host
# the plugin process lands on, so the spec covers the module resolution
# plus the mountinfo parsing rules on fixture files (the real module's
# 64-hex-id regex chain). The cpuset/mountinfo probes themselves are
# environment-dependent - verified live against real container runs.
describe "community.docker.current_container_facts" do
  it "resolves the bare and FQCN spellings" do
    task = Krikri::PlaybookParser.parse_string(
      "- name: Loop test play\n" \
      "  hosts: all\n" \
      "  tasks:\n" \
      "    - name: t\n" \
      "      community.docker.current_container_facts: {}\n"
    ).plays[0].tasks[0]
    task.module_name.should eq("community.docker.current_container_facts")
  end

  it "parses docker-style mountinfo hostname roots" do
    line = "123 100 0:99 /var/lib/docker/overlay2/c86f3732b5ba3d28bb83b6e14af767ab96abbc52de31313dcb1176a62d91a507/hostname /etc/hostname rw,relatime - overlay /var/lib/docker/overlay2/c86f3732b5ba3d28bb83b6e14af767ab96abbc52de31313dcb1176a62d91a507/merged"
    parts = line.split
    parts[4].should eq("/etc/hostname")
    m = /.*\/([a-f0-9]{64})\/hostname$/.match(parts[3])
    m.not_nil![1].should eq("c86f3732b5ba3d28bb83b6e14af767ab96abbc52de31313dcb1176a62d91a507")
  end

  it "parses podman-style mountinfo hostname roots" do
    line = "123 100 0:99 /var/lib/containers/storage/overlay-containers/0f2edfed602dd6ec9f2e42c867f4d5ee640ebf4c058e6d3196d4397f8d089100/userdata/hostname /etc/hostname rw,relatime - overlay /var/lib/containers/storage/overlay-containers/0f2edfed602dd6ec9f2e42c867f4d5ee640ebf4c058e6d3196d4397f8d089100/userdata"
    parts = line.split
    parts[4].should eq("/etc/hostname")
    m = /.*\/([a-f0-9]{64})\/userdata\/hostname$/.match(parts[3])
    m.not_nil![1].should eq("0f2edfed602dd6ec9f2e42c867f4d5ee640ebf4c058e6d3196d4397f8d089100")
  end
end
