require "capistrano/scm/plugin"

module Capistrano
  class SCM
    class S3Archive < Capistrano::SCM::Plugin
    end
  end
end

require "capistrano/scm/s3_archive/archive_object"
require "capistrano/scm/s3_archive/local_cache"
require "capistrano/scm/s3_archive/remote_cache"

module Capistrano
  class SCM
    class S3Archive

      def define_tasks
        eval_rakefile File.expand_path("tasks/s3_archive.rake", __dir__)
      end

      def register_hooks
        after "deploy:new_release_path", "s3_archive:create_release"
        before "deploy:check", "s3_archive:check"
        before "deploy:set_current_revision", "s3_archive:set_current_revision"
      end

      def set_defaults
        set_if_empty :s3_archive_client_options, {}
        set_if_empty(:s3_archive_sort_proc, ->(new, old) { old.key <=> new.key })
        set_if_empty :s3_archive_strategy, :rsync
        set_if_empty :s3_archive_object_version_id, nil

        # strategy direct
        set_if_empty :s3_archive_remote_cache_dir, -> { File.join(shared_path, "archives") }

        # strategy rsync
        set_if_empty :s3_archive_skip_download, nil
        set_if_empty :s3_archive_local_download_dir, "tmp/archives"
        set_if_empty :s3_archive_local_cache_dir, "tmp/deploy"
        set_if_empty :s3_archive_remote_rsync_options, ['-az', '--delete']
        set_if_empty :s3_archive_remote_rsync_ssh_options, []
        set_if_empty :s3_archive_remote_rsync_runner_options, {}
        set_if_empty :s3_archive_rsync_cache_dir, "shared/deploy"
        set_if_empty :s3_archive_hardlink_release, false
        set_if_empty :s3_archive_remote_rsync_copy_option, "--archive --acls --xattrs"
      end

      ######
      def local_check
        archive_object.check_access!
      end

      def remote_check
        case strategy
        when :direct
          backend.execute :aws, "s3", "ls", ["s3:/", archive_object.bucket, archive_object.key].join("/")
        when :rsync
          backend.execute :echo, "ssh connected"
        end
      end

      def strategy
        @strategy ||= fetch(:s3_archive_strategy)
      end

      def current_revision
        archive_object.current_revision
      end

      def deploy_to_release_path
        case strategy
        when :direct
          archive_dir = File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s)
          archive_file = File.join(archive_dir, File.basename(archive_object.key))
          case archive_file
          when /\.zip\Z/
            backend.execute :unzip, "-q -d", release_path, archive_file
          when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
            backend.execute :tar, "xf", archive_file, "-C", release_path
          end
        when :rsync
          link_option = if fetch(:s3_archive_hardlink_release) && backend.test("[ `readlink #{current_path}` != #{release_path} ]")
                          "--link-dest `readlink #{current_path}`"
                        end
          create_release = %[rsync #{fetch(:s3_archive_remote_rsync_copy_option)} #{link_option} "#{rsync_cache_dir}/" "#{release_path}/"]
          backend.execute create_release
        end
      end

      # for rsync
      def download_to_local_cache
        local_cache.download
        local_cache.extract
      end

      def cleanup_local_cache
        local_cache.cleanup(keep: fetch(:keep_releases))
      end

      def transfer_sources(dest)
        rsync_options = []
        rsync_options.concat fetch(:s3_archive_remote_rsync_options, [])
        rsync_options << local_cache.cache_dir + "/"

        if dest.local?
          rsync_options << ('--no-compress')
          rsync_options << rsync_cache_dir
        else
          rsync_ssh_options = []
          rsync_ssh_options << dest.ssh_key_option unless dest.ssh_key_option.empty?
          rsync_ssh_options.concat fetch(:s3_archive_remote_rsync_ssh_options)
          rsync_options << "-e 'ssh #{rsync_ssh_options}'" unless rsync_ssh_options.empty?
          rsync_options << "#{dest.login_user_at}#{dest.hostname}:#{rsync_cache_dir}"
        end

        backend.execute :rsync, *rsync_options
      end

      def rsync_cache_dir
        File.join(deploy_to, fetch(:s3_archive_rsync_cache_dir))
      end


      # for direct
      def download_to_shared_path
        remote_cache.download
      end

      def cleanup_shared_path
        remote_cache.cleanup(keep: fetch(:keep_releases))
      end

      def archive_object
        @archive_object ||= ArchiveObject.new(repo_url: fetch(:repo_url),
                                              version_id: fetch(:s3_archive_object_version_id),
                                              sort_proc: fetch(:s3_archive_sort_proc),
                                              branch: fetch(:branch),
                                              client_options: fetch(:s3_archive_client_options))
      end

      def remote_cache
        @remote_cache ||= RemoteCache.new(
          backend,
          File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s),
          archive_object
        )
      end

      def local_cache
        @local_cache ||= LocalCache.new(
          backend,
          File.join(fetch(:s3_archive_local_download_dir), fetch(:stage).to_s),
          File.join(fetch(:s3_archive_local_cache_dir), fetch(:stage).to_s),
          archive_object
        )
      end
    end
  end

  class Configuration
    class Server
      def login_user_at
        user = [user, ssh_options[:user]].compact.first
        user ? "#{user}@" : ''
      end

      def ssh_key_option
        key = [keys, ssh_options[:keys]].flatten.compact.first
        key ? "-i #{key}" : ''
      end

      def ssh_port_option
        port ? "-p #{port}" : ''
      end
    end
  end
end
