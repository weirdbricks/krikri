module Krikri
  module PluginHelpers
    # DockerRef - pure logic for splitting/comparing Docker image
    # references (name[:tag], optionally registry-qualified). No I/O -
    # docker_image/docker_container do the actual API calls.
    module DockerRef
      # Splits "name[:tag]" into {name, tag}, defaulting tag to "latest"
      # when omitted. Registry-qualified refs may contain a colon before
      # the first "/" (e.g. "myregistry:5000/app") that is NOT a tag
      # separator, so only a colon *after* the last "/" counts.
      #
      #   split("nginx")                        => {"nginx", "latest"}
      #   split("nginx:1.25")                    => {"nginx", "1.25"}
      #   split("myregistry:5000/app")           => {"myregistry:5000/app", "latest"}
      #   split("myregistry:5000/app:latest")    => {"myregistry:5000/app", "latest"}
      def self.split(ref : String) : {String, String}
        slash_index = ref.rindex('/')
        search_from = slash_index ? slash_index + 1 : 0
        colon_index = ref.index(':', search_from)

        return {ref, "latest"} unless colon_index

        {ref[0...colon_index], ref[(colon_index + 1)..]}
      end

      # Joins a {name, tag} pair back into "name:tag" the way most Docker
      # API responses/params expect it.
      def self.join(name : String, tag : String) : String
        "#{name}:#{tag}"
      end

      # Compares two image references leniently: real daemons don't agree
      # on how "fully qualified" a locally-known image ref is (Podman
      # reports a container created from "nginx:latest" as
      # "docker.io/library/nginx:latest" in its own API responses, verified
      # empirically - real Docker typically doesn't add that prefix back).
      # Exact match, or one ref ending in "/" + the other, both count as
      # the same image; this is a documented simplification, not full
      # canonical-reference-normalization.
      def self.same?(a : String, b : String) : Bool
        return true if a == b

        a.ends_with?("/#{b}") || b.ends_with?("/#{a}")
      end
    end
  end
end
