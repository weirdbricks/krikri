#!/usr/bin/env crystal

# Facts Plugin - Fast system facts gathering
# Runs locally on target host and returns all facts in one JSON response
#
# The gathering itself lives in
# `src/krikri/plugin_helpers/facts_gatherer.cr` so the fat plugin
# binary can link it too (OPUS_PERFORMANCE_IMPROVEMENTS.md item 2) -
# this file is now only the standalone driver, kept so `facts` still
# builds and runs as its own binary for a `crystal build plugins/facts.cr`
# or any caller that wants one.

require "json"
require "../src/krikri/plugin_helpers/facts_gatherer"

# Plugin entry point
input = STDIN.gets_to_end
config = input.strip.empty? ? nil : (JSON.parse(input) rescue nil)

puts Krikri::FactsGatherer.run(config)
