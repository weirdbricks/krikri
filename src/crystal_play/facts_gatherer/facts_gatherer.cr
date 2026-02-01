# FactsGatherer - Main entry point
# This file maintains backward compatibility by importing the refactored components
# 
# The implementation has been split into:
# - facts_gatherer/gatherer.cr         - Main FactsGatherer class
# - facts_gatherer/hostname_facts.cr   - Hostname and domain facts
# - facts_gatherer/os_facts.cr         - OS and distribution facts
# - facts_gatherer/network_facts.cr    - Network facts
# - facts_gatherer/hardware_facts.cr   - Hardware facts (CPU, memory, swap)
# - facts_gatherer/python_facts.cr     - Python interpreter facts
# - facts_gatherer/user_facts.cr       - User and identity facts
# - facts_gatherer/environment_facts.cr - Environment variables
# - facts_gatherer/date_time_facts.cr  - Date and time facts

require "./gatherer"
require "./hostname_facts"
require "./os_facts"
require "./network_facts"
require "./hardware_facts"
require "./python_facts"
require "./user_facts"
require "./environment_facts"
require "./date_time_facts"
