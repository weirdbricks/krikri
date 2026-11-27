require "../minitest_helper"
require "../../src/krikri/argspec_validator"
require "../../src/krikri/builtin_module_names_data"
require "../../src/krikri/collection_runtime_data"

# ArgspecValidator indexes data/argspecs.json by line layout instead of
# parsing it whole (startup cost), so a writer that changes the file's
# json.dump(indent=1) shape must fail here rather than silently drop
# modules from validation.
describe "ArgspecValidator lazy argspec table index" do
  it "indexes exactly the modules a full parse sees, with identical entries" do
    full = JSON.parse(Krikri::ArgspecValidator::ARGSPECS_JSON).as_h
    spans = Krikri::ArgspecValidator.entry_spans
    spans.keys.must_equal full.keys
    full.each do |name, entry|
      Krikri::ArgspecValidator.entry(name).must_equal entry
    end
  end

  it "answers nil for a module the table does not carry" do
    Krikri::ArgspecValidator.entry("no.such.module_xyz").must_be_nil
  end
end

# The baked ansible-core / collection tables are line records now (decoded
# by every krikri-playbook process); these pin the decoded shapes the
# lookups rely on.
describe "baked runtime tables line-format decode" do
  it "decodes the builtin name sets and redirect tables" do
    names = Krikri.builtin_module_names
    names.size.must_equal 3824
    names.includes?("copy").must_equal true
    names.none?(&.empty?).must_equal true
    Krikri.builtin_lookup_names.includes?("file").must_equal true
    modules, action, lookups = Krikri.builtin_runtime_redirects
    modules["docker_service"]?.must_equal "community.general.docker_service"
    action["yum"]?.must_equal "ansible.builtin.dnf"
    lookups.has_key?("redis").must_equal true
  end

  it "decodes the collection records" do
    data = Krikri::CollectionRuntimeData
    data.ansible_core_version.must_equal "2.21.6"
    data.known_collections.includes?("community.general").must_equal true
    mysql = data.collection("community.mysql")
    mysql.try(&.redirects.keys.sort!).must_equal ["action", "lookup", "modules"]
    data.collections.values.any?(&.paths).must_equal true
    data.module_versions.each_value { |(collection, _)| collection.empty?.must_equal false }
    data.action_plugins["ansible.builtin"].has_key?("copy").must_equal true
  end
end
