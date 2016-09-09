require 'aws-sdk-core'

load File.expand_path("../tasks/s3_archive.rake", __FILE__)

require "capistrano/s3_archive/version"
require 'capistrano/scm'

set_if_empty :rsync_options, ['-az --delete']
set_if_empty :rsync_ssh_options, []
set_if_empty :rsync_copy, "rsync --archive --acls --xattrs"
set_if_empty :rsync_cache, "shared/deploy"
set_if_empty :local_cache, "tmp/deploy"
set_if_empty :s3_archive, "tmp/archives"
set_if_empty :sort_proc, ->(a,b) { b.key <=> a.key }
set_if_empty :archive_release_runner_concurrency, 20
set_if_empty :archive_release_runner_options, { in: :groups, limit: fetch(:archive_release_runner_concurrency) }

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
        opts = { bucket: bucket, key: archive_object_key }
        opts[:version_id] = fetch(:version_id) if fetch(:version_id)
        s3_client.get_object(opts, target: target)
      end

      def get_object_metadata
        s3_client.list_object_versions(bucket: bucket, prefix: archive_object_key).versions.find do |v|
          if fetch(:version_id) then v.version_id == fetch(:version_id)
          else v.is_latest
          end
        end
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
          case fetch(:branch).to_sym
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

        def local_check
          list_objects(false)
        end

        def check
          return if context.class == SSHKit::Backend::Local
          ssh_key  = ssh_key_for(context.host)
          if ssh_key.nil?
            fail MissingSSHKyesError, "#{RsyncStrategy} only supports publickey authentication. Please set #{context.host.hostname}.keys or ssh_options."
          end
        end

        def stage
          stage_lock do
            archive_dir = File.join(fetch(:s3_archive), fetch(:stage).to_s)
            archive_file = File.join(archive_dir, File.basename(archive_object_key))
            tmp_file = "#{archive_file}.part"
            etag_file = File.join(archive_dir, ".#{File.basename(archive_object_key)}.etag")
            fail "#{tmp_file} is found. Another process is running?" if File.exist?(tmp_file)

            etag = get_object_metadata.tap { |it| fail "No such object: #{current_revision}" if it.nil? }.etag
            if [archive_file, etag_file].all? { |f| File.exist?(f) } && File.read(etag_file) == etag
              context.info "#{archive_file} (etag:#{etag}) is found. download skipped."
            else
              context.info "Download #{current_revision} to #{archive_file}"
              mkdir_p(File.dirname(archive_file))
              File.open(tmp_file, 'w') do |f|
                get_object(f)
              end
              move(tmp_file, archive_file)
              File.write(etag_file, etag)
            end

            remove_entry_secure(fetch(:local_cache_dir)) if File.exist? fetch(:local_cache_dir)
            mkdir_p(fetch(:local_cache_dir))
            case archive_file
            when /\.zip\Z/
              cmd = "unzip -q -d #{fetch(:local_cache_dir)} #{archive_file}"
            when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
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
            user = user_for(server) + '@' unless user_for(server).nil?
            key  = ssh_key_for(server)
            ssh_port_option = server.port.nil? ? '' : "-p #{server.port}"
          end
          rsync = ['rsync']
          rsync.concat fetch(:rsync_options)
          rsync << fetch(:local_cache_dir) + '/'
          unless context.class == SSHKit::Backend::Local
            rsync << "-e 'ssh -i #{key} #{ssh_port_option} #{fetch(:rsync_ssh_options).join(' ')}'"
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
            link_option = if fetch(:hardlink) && test("[ `readlink #{current_path}` != #{release_path} ]")
                            "--link-dest `readlink #{current_path}`"
                          end
            copy = %(#{fetch(:rsync_copy)} #{link_option} "#{cache}/" "#{release_path}/")
            context.execute copy
          end
        end

        def current_revision
          fetch(:version_id) ? "#{archive_object_key}?versionid=#{fetch(:version_id)}" : archive_object_key
        end

        def ssh_key_for(host)
          if not host.keys.empty?
            host.keys.first
          elsif host.ssh_options && host.ssh_options.has_key?(:keys)
            Array(host.ssh_options[:keys]).first
          elsif fetch(:ssh_options, nil) && fetch(:ssh_options).has_key?(:keys)
            fetch(:ssh_options)[:keys].first
          end
        end

        def user_for(host)
          if host.user
            host.user
          elsif host.ssh_options && host.ssh_options.has_key?(:user)
            host.ssh_options[:user]
          elsif fetch(:ssh_options, nil) && fetch(:ssh_options).has_key?(:user)
            fetch(:ssh_options)[:user]
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
