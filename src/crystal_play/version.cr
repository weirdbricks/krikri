module CrystalPlay
  VERSION = "0.9.643"

  def self.version_info
    String.build do |str|
      str << "Crystal Ansible #{VERSION}\n"
      str << "Fast, Ansible-compatible automation tool written in Crystal\n"
      str << "\n"
      str << "Crystal: #{Crystal::VERSION}"
    end
  end

  def self.banner
    String.build do |str|
      str << "CRYSTAL PLAY v#{VERSION}"
    end
  end
end
