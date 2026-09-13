require "../spec_helper"

# trombik.redhat_repo's "Install extra packages" task (round 601447,
# batch 601000-601999): `name: "{{ redhat_repo_extra_packages }}"` with
# the var defaulting to `[]` templates to the literal string "[]", which
# parses down to an empty package list. A `name:`/`pkg:` KEY that IS
# present (so the "no name: at all" branch never fires) but resolves to
# nothing is exactly as "nothing to install" as no name: at all - real
# ansible-core's yum/dnf module reports ok/changed: false for it, not a
# missing-parameter failure. Mirrors apt.cr's identical fix for the same
# bug class (round 84000, see apt_cache_updated_spec.cr).
describe "yum: empty name: list (name: key present, resolves to [])" do
  it "is a no-op, not a missing-parameter failure" do
    result = PluginSpecHelper.run("yum", {"name" => "[]"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
  end

  it "still fails when name:/pkg: is missing entirely" do
    result = PluginSpecHelper.run("yum", {"state" => "present"})

    result["failed"].as_bool.should be_true
  end
end
