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
          @prefix = uri.path.sub(%r{/?\Z}, '/').slice(1..-1) # normalize path
          @version_id = version_id
          @sort_proc = sort_proc
          @branch = branch
          @client = Aws::S3::Client.new(client_options)
        end

        def check_access!
          client.list_objects(bucket: bucket, prefix: prefix)
        end

        def key
          @key ||= case branch.to_sym
                   when :master, :latest
                     latest_key
                   else
                     prefix + branch.to_s
                   end
        end

        def key_basename
          File.basename(key)
        end

        def latest_key
          list_all_objects.min(&sort_proc).key
        end

        def list_all_objects
          response = client.list_objects(bucket: bucket, prefix: prefix)
          response.inject([]) do |objects, page|
            objects + page.contents
          end
        end

        def etag
          metadata.tap { |it| raise "No such object: #{current_revision}" if it.nil? }.etag
        end

        def current_revision
          if version_id
            "#{key}?versionid=#{version_id}"
          else
            key
          end
        end

        def metadata
          client.list_object_versions(bucket: bucket, prefix: key).versions.find do |v|
            if version_id then v.version_id == version_id
            else v.is_latest
            end
          end
        end

        def get_object(io)
          options = { bucket: bucket, key: key }
          options[:version_id] = version_id if version_id
          client.get_object(options, target: io)
        end
      end
    end
  end
end
