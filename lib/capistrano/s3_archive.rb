load File.expand_path("../tasks/s3_archive.rake", __FILE__)

require "capistrano/s3_archive/version"
require 'capistrano/scm'
require 'aws-sdk-core'

set :rsync_options, ['-az --delete']
set :rsync_copy, "rsync --archive --acls --xattrs"
set :rsync_cache, "shared/deploy"
set :local_cache, "tmp/deploy"
set :s3_archive, "tmp/archives"
set :sort_proc, ->(a,b) { b.key <=> a.key }

module Capistrano
  module S3Archive
    class SCM < Capistrano::SCM
      include FileUtils
      attr_accessor :bucket, :object_prefix

      def initialize(*args)
        super
        @bucket, @object_prefix = parse_s3_uri(repo_url)
        set :local_cache_dir, "#{fetch(:local_cache)}/#{fetch(:stage)}"
      end

      def get_object
        s3_client.get_object(bucket: bucket, key: archive_object_key)
      end

      def list_objects(all_page = true)
        response = s3_client.list_objects(bucket: bucket, prefix: object_prefix)
        if all_page
          response.inject([]) do |objects, page|
            objects += page.contents
          end
        else
          response
        end
      end

      def archive_object_key
        @archive_object_key ||=
          case fetch(:branch)
          when :master, :latest, nil
            latest_object_key
          else
            [object_prefix, fetch(:branch)].join('/')
          end
      end

      private
      def s3_client
        @s3_client ||= Aws::S3::Client.new(fetch(:s3_client_options))
      end

      def latest_object_key
        list_objects.sort(&fetch(:sort_proc)).first.key
      end

      def parse_s3_uri(uri)
        pathes = uri.split('://')[1].split('/')
        [pathes.first, pathes.drop(1).join('/')]
      end

      ### Default strategy
      private
      module RsyncStrategy
        def check
          list_objects(false)
        end

        def stage
          archive_file = File.join(fetch(:s3_archive), fetch(:stage).to_s, File.basename(archive_object_key))
          if not File.exist?(archive_file)
            mkdir_p(File.dirname(archive_file))
            content = get_object.body.read
            File.open(archive_file, 'w') do |f|
              f.write(content)
            end
          else
            context.info "#{archive_file} is found."
          end

          remove_entry_secure(fetch(:local_cache_dir)) if File.exist? fetch(:local_cache_dir)
          mkdir_p(fetch(:local_cache_dir))
          case archive_file
          when /\.zip\Z/
            dir = archive_file.gsub(/\.zip\Z/, '')
            cmd = "unzip -q -d #{fetch(:local_cache_dir)} #{archive_file}"
          when /\.tar\.gz\Z|\.tar\.bz2\Z/
            dir = archive_file.gsub(/\.tar\.gz\Z|\.tar\.bz2\Z/, '')
            cmd = "tar xf #{archive_file} -C #{fetch(:local_cache_dir)}"
          end

          run_locally do
            execute cmd
          end
        end

        def release(server = context.host)
          user = server.user + '@' unless server.user.nil?
          key  = server.keys.first || Array(server.ssh_options[:keys]).first

          rsync = ['rsync']
          rsync.concat fetch(:rsync_options)
          rsync << fetch(:local_cache_dir) + '/'
          rsync << "-e 'ssh -i #{key}'"
          rsync << "#{user}#{server.hostname}:#{rsync_cache || release_path}"

          run_locally do
            execute *rsync
          end

          unless fetch(:rsync_cache).nil?
            cache = rsync_cache
            on server do
              copy = %(#{fetch(:rsync_copy)} "#{cache}/" "#{release_path}/")
              execute copy
            end
          end
        end

        def current_revision
          archive_object_key
        end

        private
        def rsync_cache
          cache = fetch(:rsync_cache)
          cache = deploy_to + "/" + cache if cache && cache !~ /^\//
          cache
        end
      end
    end
  end
end
