module Krikri
  # Provenance for a templating failure raised while expanding ONE
  # `{{ }}` span: the span's own inner text, so a display site can point
  # at the source line that authored it. ansible-core 2.19 gives every
  # template-origin failure its own Origin (the failing span's value
  # token), which a container-valued task param renders as a fourth
  # "caused by" stanza chained under the container's own position
  # (issues #265/#323/#803). Only classes whose errors ansible chains
  # this way mix this in; a lookup/filter-plugin runtime failure does
  # NOT (live-captured 2.19.11: it keeps the three-stanza block), and
  # those exceptions therefore leave #span nil.
  module TemplatedOriginSpan
    property span : String?
  end
end
