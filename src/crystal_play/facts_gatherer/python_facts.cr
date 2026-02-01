require "json"

module CrystalPlay
  # PythonFacts - Gathers Python-related facts
  module PythonFacts
    # Gather Python facts
    # Populates: ansible_python_version, ansible_python
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # ansible_python_version - Python version
      python_version = execute_callback.call("python3 --version 2>&1 | awk '{print $2}' || python --version 2>&1 | awk '{print $2}'")
      if python_version && !python_version.strip.empty?
        facts["ansible_python_version"] = JSON::Any.new(python_version.strip)
      end
      
      # ansible_python - Python interpreter path
      python_path = execute_callback.call("which python3 2>/dev/null || which python 2>/dev/null")
      if python_path && !python_path.strip.empty?
        facts["ansible_python"] = JSON::Any.new(python_path.strip)
      end
    end
  end
end
