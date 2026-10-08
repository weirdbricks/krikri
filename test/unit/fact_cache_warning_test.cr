require "../minitest_helper"
require "../../src/krikri/fact_cache"

# ansible-core 2.19.11 (live-verified 2026-10-07) warns at startup when a
# fact-cache plugin whose required `_uri` config (fact_caching_connection)
# is CONFIGURED without a connection - even when no play gathers facts
# (the plugin load is not gated on gathering):
#
#   [WARNING]: Required config '_uri' for 'jsonfile' cache plugin not provided.
#
# A collection plugin renders fully qualified in the warning
# (community.general.pickle -> ansible_collections.community.general.plugins.cache.pickle).
describe "Krikri::FactCache.warn_missing_connection (fact_cache_warning_test.cr)" do
  serial! # mutates process-global state (ENV)

  after_each do
    Krikri::FactCache.reset_connection_warning
    ENV.delete("ANSIBLE_CACHE_PLUGIN")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_CONNECTION")
  end

  it "warns for jsonfile with no connection, matching ansible's wording" do
    ENV.delete("ANSIBLE_CACHE_PLUGIN_CONNECTION")
    ENV["ANSIBLE_CACHE_PLUGIN"] = "jsonfile"
    Krikri::FactCache.reset_connection_warning
    io = IO::Memory.new
    Krikri::FactCache.warn_missing_connection(io)
    io.to_s.must_equal("[WARNING]: Required config '_uri' for 'jsonfile' cache plugin not provided.\n")
  end

  it "renders a collection plugin fully qualified in the warning" do
    ENV.delete("ANSIBLE_CACHE_PLUGIN_CONNECTION")
    ENV["ANSIBLE_CACHE_PLUGIN"] = "community.general.pickle"
    Krikri::FactCache.reset_connection_warning
    io = IO::Memory.new
    Krikri::FactCache.warn_missing_connection(io)
    io.to_s.must_equal("[WARNING]: Required config '_uri' for 'ansible_collections.community.general.plugins.cache.pickle' cache plugin not provided.\n")
  end

  it "stays silent when the connection is configured" do
    ENV["ANSIBLE_CACHE_PLUGIN"] = "jsonfile"
    ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = "/tmp/krikri-spec-cache"
    Krikri::FactCache.reset_connection_warning
    io = IO::Memory.new
    Krikri::FactCache.warn_missing_connection(io)
    io.to_s.must_equal("")
  end

  it "stays silent when no cache plugin is configured" do
    ENV.delete("ANSIBLE_CACHE_PLUGIN")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_CONNECTION")
    Krikri::FactCache.reset_connection_warning
    io = IO::Memory.new
    Krikri::FactCache.warn_missing_connection(io)
    io.to_s.must_equal("")
  end

  it "emits at most once per process" do
    ENV.delete("ANSIBLE_CACHE_PLUGIN_CONNECTION")
    ENV["ANSIBLE_CACHE_PLUGIN"] = "jsonfile"
    Krikri::FactCache.reset_connection_warning
    io = IO::Memory.new
    Krikri::FactCache.warn_missing_connection(io)
    Krikri::FactCache.warn_missing_connection(io)
    io.to_s.count('\n').must_equal(1)
  end
end
