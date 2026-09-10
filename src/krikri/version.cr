module Krikri
  VERSION = "0.9.904"

  def self.version_info : String
    String.build do |str|
      str << "krikri #{VERSION}\n"
      str << "Fast, Ansible-compatible automation tool written in Crystal\n"
      str << "\n"
      str << "Crystal: #{Crystal::VERSION}"
    end
  end

  def self.banner : String
    String.build do |str|
      str << "KRIKRI v#{VERSION}"
    end
  end
end
