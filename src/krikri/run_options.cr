module Krikri
  # Command-line facts exposed to playbooks as magic vars
  # (ansible_run_tags, ansible_skip_tags, ansible_forks).
  module RunOptions
    class_property run_tags : Array(String) = [] of String
    class_property skip_tags : Array(String) = [] of String
    class_property play_name : String = ""
    class_property inventory_sources : Array(String) = [] of String
    # The effective fork count: seeded from ANSIBLE_FORKS (DEFAULT_FORKS)
    # at startup and overridden by -f/--forks. Ansible's own default is 5.
    class_property forks : Int32? = nil
    # Numeric -v/-vv/... verbosity, readable from output paths that don't
    # carry the executor (HandlerRunner, ResultDisplay).
    class_property verbosity : Int32 = 0
  end
end
