require "./playbook_parser"

module CrystalPlay
  # `serial:` - real Ansible runs the WHOLE play against one batch of
  # hosts at a time instead of every host at once, which is what makes a
  # rolling restart rolling. This engine previously ignored the keyword
  # entirely, so `serial: 1` still hit every host simultaneously.
  module SerialBatches
    # `order:` - how hosts are sequenced before serial: batches them.
    # Verified against ansible-core 2.19.4 over an inventory listing
    # h3, h1, h2: inventory keeps that order, sorted gives h1 h2 h3,
    # reverse_sorted h3 h2 h1, and reverse_inventory h2 h1 h3 (the
    # inventory order reversed, NOT a sort).
    def self.order(hosts : Array(Host), order : String?) : Array(Host)
      case order
      when nil, "", "inventory" then hosts
      when "reverse_inventory"  then hosts.reverse
      when "sorted"             then hosts.sort_by(&.name)
      when "reverse_sorted"     then hosts.sort_by(&.name).reverse!
      when "shuffle"            then hosts.shuffle
      else                           hosts
      end
    end

    # Splits *hosts* according to the play's serial tokens. Each token is
    # either a count ("2") or a percentage of the TOTAL host count
    # ("50%", rounded up); the last token sizes every remaining batch.
    # Verified against ansible-core 2.19.4 for `1`, `2`, `"50%"` and
    # `[1, 2]` over four hosts.
    def self.split(hosts : Array(Host), serial : Array(String)) : Array(Array(Host))
      return [hosts] if serial.empty? || hosts.empty?

      total = hosts.size
      batches = [] of Array(Host)
      index = 0
      token_index = 0

      while index < total
        token = serial[token_index]? || serial.last
        size = batch_size(token, total)
        batches << hosts[index, size]
        index += size
        token_index += 1
      end

      batches
    end

    private def self.batch_size(token : String, total : Int32) : Int32
      size =
        if token.ends_with?('%')
          percent = token.rchop('%').to_f? || 100.0
          (total * percent / 100.0).ceil.to_i
        else
          token.to_i? || total
        end

      # A zero or negative batch would loop forever; real Ansible treats
      # anything under one host per batch as one.
      size < 1 ? 1 : size
    end
  end
end
