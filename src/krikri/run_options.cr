module Krikri
  # Command-line facts exposed to playbooks as magic vars
  # (ansible_run_tags, ansible_skip_tags, ansible_forks).
  module RunOptions
    class_property run_tags : Array(String) = [] of String
    class_property skip_tags : Array(String) = [] of String
    class_property play_name : String = ""
    class_property inventory_sources : Array(String) = [] of String
    # nil = not given on the command line (real ansible's default is 5)
    class_property forks : Int32? = nil
  end
end
