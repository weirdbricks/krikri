require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# `to_uuid`'s optional namespace: real Ansible's filter plugin takes a
# plain second parameter, positional or `namespace=` keyword; a UUID5
# over the caller's namespace (live-verified vs 2.19.11: the standard
# DNS namespace 6ba7b810-9dad-11d1-80b4-00c04fd430c8 over "config"
# yields cfba30b9-539e-5ea9-ae35-13d14fbbc589). The default stays
# Ansible's own 361E6D51-... namespace, not the DNS one.
describe "Krikri::VarSubstitutor::FilterCore.to_uuid namespace" do
  it "defaults to Ansible's own namespace" do
    VariableSubstitutor::FilterCore.to_uuid("config").must_equal("cd614808-c587-5d03-92aa-bb1d36ab1795")
  end

  it "accepts an explicit namespace (keyword or positional)" do
    dns = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
    VariableSubstitutor::FilterCore.to_uuid("config", dns).must_equal("cfba30b9-539e-5ea9-ae35-13d14fbbc589")
  end
end
