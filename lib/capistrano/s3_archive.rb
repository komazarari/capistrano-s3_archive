require 'aws-sdk-core'

load File.expand_path("../tasks/s3_archive.rake", __FILE__)

require "capistrano/s3_archive/version"
require 'capistrano/scm'

set_if_empty :rsync_options, ['-az --delete']
set_if_empty :rsync_copy, "rsync --archive --acls --xattrs"
set_if_empty :rsync_cache, "shared/deploy"
set_if_empty :local_cache, "tmp/deploy"
set_if_empty :s3_archive, "tmp/archives"
set_if_empty :sort_proc, ->(a,b) { b.key <=> a.key }

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

      def get_object(target)
        s3_client.get_object({ bucket: bucket, key: archive_object_key }, target: target)
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
        class MissingSSHKyesError < StandardError; end
        class ResourceBusyError < StandardError; end

        def check
          list_objects(false)
          return if context.class == SSHKit::Backend::Local
          ssh_key  = ssh_key_for(context.host)
          if ssh_key.nil?
            fail MissingSSHKyesError, "#{RsyncStrategy} only supports publickey authentication. Please set #{context.host.hostname}.keys or ssh_options."
          end
        end

        def stage
          stage_lock do
            archive_file = File.join(fetch(:s3_archive), fetch(:stage).to_s, File.basename(archive_object_key))
            tmp_file = "#{archive_file}.part"
            fail "#{tmp_file} is found. Another process is running?" if File.exist?(tmp_file)
            if not File.exist?(archive_file)
              mkdir_p(File.dirname(archive_file))
              File.open(tmp_file, 'w') do |f|
                get_object(f)
              end
              move(tmp_file, archive_file)
            else
              context.info "#{archive_file} is found."
            end

            remove_entry_secure(fetch(:local_cache_dir)) if File.exist? fetch(:local_cache_dir)
            mkdir_p(fetch(:local_cache_dir))
            case archive_file
            when /\.zip\Z/
              cmd = "unzip -q -d #{fetch(:local_cache_dir)} #{archive_file}"
            when /\.tar\.gz\Z|\.tar\.bz2\Z/
              cmd = "tar xf #{archive_file} -C #{fetch(:local_cache_dir)}"
            end

            release_lock(true) do
              run_locally do
                execute cmd
              end
            end
          end
        end

        def cleanup
          run_locally do
            archives_dir = File.join(fetch(:s3_archive), fetch(:stage).to_s)
            archives = capture(:ls, '-xtr', archives_dir).split
            if archives.count >= fetch(:keep_releases)
              tobe_removes = (archives - archives.last(fetch(:keep_releases)))
              if tobe_removes.any?
                tobe_removes_str = tobe_removes.map do |file|
                  File.join(archives_dir, file)
                end.join(' ')
                execute :rm, tobe_removes_str
              end
            end
          end
        end

        def release(server = context.host)
          unless context.class == SSHKit::Backend::Local
            user = server.user + '@' unless server.user.nil?
            key  = ssh_key_for(server)
            ssh_port_option = server.port.nil? ? '' : "-p #{server.port}"
          end
          rsync = ['rsync']
          rsync.concat fetch(:rsync_options)
          rsync << fetch(:local_cache_dir) + '/'
          unless context.class == SSHKit::Backend::Local
            rsync << "-e 'ssh -i #{key} #{ssh_port_option}'"
            rsync << "#{user}#{server.hostname}:#{rsync_cache || release_path}"
          else
            rsync << '--no-compress'
            rsync << "#{rsync_cache || release_path}"
          end
          release_lock do
            run_locally do
              execute *rsync
            end
          end

          unless fetch(:rsync_cache).nil?
            cache = rsync_cache
            on [server] do
              link_option = if fetch(:hardlink) && test("[ `readlink #{current_path}` != #{release_path} ]")
                              "--link-dest `readlink #{current_path}`"
                            end
              copy = %(#{fetch(:rsync_copy)} #{link_option} "#{cache}/" "#{release_path}/")
              execute copy
            end
          end
        end

        def current_revision
          archive_object_key
        end

        def ssh_key_for(host)
          if not host.keys.empty?
            host.keys.first
          elsif host.ssh_options && host.ssh_options.has_key?(:keys)
            Array(host.ssh_options[:keys]).first
          else fetch(:ssh_options, nil) && fetch(:ssh_options).has_key?(:keys)
            fetch(:ssh_options)[:keys].first
          end
        end

        private
        def rsync_cache
          cache = fetch(:rsync_cache)
          cache = deploy_to + "/" + cache if cache && cache !~ /^\//
          cache
        end

        def stage_lock(&block)
          mkdir_p(File.dirname(fetch(:local_cache)))
          lockfile = "#{fetch(:local_cache)}.#{fetch(:stage)}.lock"
          File.open(lockfile, "w") do |f|
            if f.flock(File::LOCK_EX | File::LOCK_NB)
              block.call
            else
              fail ResourceBusyError, "Could not get #{lockfile}"
            end
          end
        ensure
          rm lockfile if File.exist? lockfile
        end

        def release_lock(exclusive = false, &block)
          mkdir_p(File.dirname(fetch(:local_cache)))
          lockfile = "#{fetch(:local_cache)}.#{fetch(:stage)}.release.lock"
          File.open(lockfile, File::RDONLY|File::CREAT) do |f|
            mode = if exclusive
                     File::LOCK_EX | File::LOCK_NB
                   else
                     File::LOCK_SH
                   end
            if f.flock(mode)
              block.call
            else
              fail ResourceBusyError, "Could not get #{fetch(:lockfile)}"
            end
          end
        end
      end
    end
  end
end
