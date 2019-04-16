require "aws-sdk-s3"
require "uri"

module Capistrano
  class SCM
    class S3Archive
      class ArchiveObject
        attr_reader :bucket, :prefix, :version_id, :sort_proc, :branch, :client

        def initialize(repo_url: nil, version_id: nil, sort_proc: nil, branch: :latest, client_options: {})
          uri = URI.parse(repo_url)
          @bucket = uri.host
          @prefix = uri.path.sub(/\/?\Z/, '/').slice(1..-1) # normalize path
          @version_id = version_id
          @sort_proc = sort_proc
          @branch = branch
          @client = Aws::S3::Client.new(client_options)
        end

        def check_access!
          client.list_objects(bucket: bucket, prefix: prefix)
        end

        def
      end
    end
  end
end
