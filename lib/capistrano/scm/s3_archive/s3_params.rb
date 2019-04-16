require "uri"

module Capistrano
  class SCM
    class S3Archive
      class S3Params
        attr_reader :bucket, :object_prefix

        def initialize(repo_url)
          uri = URI.parse(repo_url)
          @bucket = uri.host
          @object_prefix = uri.path.sub(/\/?\Z/, '/').slice(1..-1) # normalize path
        end
      end
    end
  end
end
