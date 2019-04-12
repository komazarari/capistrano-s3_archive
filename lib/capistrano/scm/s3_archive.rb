require "capistrano/scm/plugin"
require "aws-sdk-s3"
require "uri"

module Capistrano
  class SCM
    class S3Archive < Capistrano::SCM::Plugin
      # attr_reader :release_agent

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
        set_if_empty :s3_archive_remote_cache_dir, -> { File.join(shared_path, "archives") }
        set_if_empty :s3_archive_strategy, :rsync
        set_if_empty :s3_archive_object_version_id, nil
      end

      ######
      def local_check
        s3_client.list_objects(bucket: s3params.bucket, prefix: s3params.object_prefix)
      end

      def remote_check
        case strategy
        when :direct
          backend.execute :aws, "s3", "ls", ["s3:/", s3params.bucket, archive_object_key].join("/")
        when :rsync
          backend.execute :echo, "ssh connected"
        end
      end

      # def release_agent
      #   @release_agent ||= case strategy
      #                      when :direct then DirectReleaseAgent.new
      #                      when :rsync then RsyncReleaseAgent.new
      #                      end
      # end

      def strategy
        @strategy ||= fetch(:s3_archive_strategy)
      end

      def current_revision
        if fetch(:s3_archive_object_version_id)
          "#{archive_object_key}?versionid=#{fetch(:s3_archive_object_version_id)}"
        else
          archive_object_key
        end
      end

      def deploy_to_release_path
        case strategy
        when :direct
          archive_dir = File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s)
          archive_file = File.join(archive_dir, File.basename(archive_object_key))
          case archive_file
          when /\.zip\Z/
            backend.execute :unzip, "-q -d", release_path, archive_file
          when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
            backend.execute :tar, "xf", archive_file, "-C", release_path
          end
        end
      end

#       def release
#         if fetch(:s3_archive_extract_to) == :local
#           link_option = if fetch(:s3_archive_hardlink_release) && backend.test("[ `readlink #{current_path}` != #{release_path} ]")
#                           "--link-dest `readlink #{current_path}`"
#                         end
#           create_release = %[#{fetch(:s3_archive_rsync_copy)} #{link_option} "#{rsync_cache_dir}/" "#{release_path}/"]
#         else
#           archive_file = File.basename(archive_object_key)
#           archive_path = File.join(fetch(:s3_archive_remote_cache_dir), archive_file)
#           case archive_file
#           when /\.zip\Z/
#             create_release = "unzip -q -d #{release_path} #{archive_path}"
#           when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
#             create_release = "tar xf #{archive_path} -C #{release_path}"
#           end
#         end
#         backend.execute create_release
#       end

      # for rsync
      def download_to_local_cache
        local_cache.download(s3params.bucket,
                             archive_object_key,
                             fetch(:s3_archive_object_version_id))
      end

      def cleanup_local_cache
        local_cache.cleanup(keep: fetch(:keep_releases))
      end

      def transfer_sources(server)
      end

      # for direct
      def download_to_shared_path
        archive_dir = File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s)
        archive_file = File.join(archive_dir, File.basename(archive_object_key))
        tmp_file = "#{archive_file}.part"
        etag_file = File.join(archive_dir, ".#{File.basename(archive_object_key)}.etag")
        etag = get_object_metadata.tap { |it| fail "No such object: #{current_revision}" if it.nil? }.etag
        if backend.test("[ -f #{archive_file} -a -f #{etag_file} ]") &&
           backend.capture(:cat, etag_file) == etag
          backend.info "#{archive_file} (etag:#{etag}) is found. download skipped."
        else
          backend.info "Download #{current_revision} to #{archive_file}"
          backend.execute(:mkdir, "-p", archive_dir)
          version_id = fetch(:s3_archive_object_version_id)
          backend.execute(:aws, *['s3api', 'get-object', "--bucket #{s3params.bucket}", "--key #{archive_object_key}", version_id ? "--version-id #{version_id}" : nil, tmp_file].compact)
          backend.execute(:mv, tmp_file, archive_file)
          backend.execute(:echo, "-n", "'#{etag}'", "|tee", etag_file)
        end
      end

      def cleanup_shared_path
        archives_dir = File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s)
        archives = backend.capture(:ls, "-xtr", archives_dir).split
        if archives.count >= fetch(:keep_releases)
          to_be_removes = (archives - archives.last(fetch(:keep_releases)))
          if to_be_removes.any?
            backend.execute(:rm, *to_be_removes.map { |file| File.join(archives_dir, file) })
            backend.execute(:rm, '-f', *to_be_removes.map { |file| File.join(archives_dir, ".#{file}.etag" ) })
          end
        end
      end

      # include FileUtils

      # class ResourceBusyError < StandardError; end

      def s3params
        @s3params ||= S3Params.new(fetch(:repo_url))
      end

      def list_all_objects
        response = s3_client.list_objects(bucket: s3params.bucket, prefix: s3params.object_prefix)
        response.inject([]) do |objects, page|
          objects + page.contents
        end
      end

      def latest_object_key
        list_all_objects.sort(&fetch(:s3_archive_sort_proc)).first.key
      end

      def archive_object_key
        @archive_object_key ||=
          case fetch(:branch, :latest).to_sym
          when :master, :latest
            latest_object_key
          else
            s3params.object_prefix + fetch(:branch).to_s
          end
      end

      def current_revision
        if fetch(:s3_archive_object_version_id)
          "#{archive_object_key}?versionid=#{fetch(:s3_archive_object_version_id)}"
        else
          archive_object_key
        end
      end

      def get_object_metadata
        s3_client.list_object_versions(bucket: s3params.bucket, prefix: archive_object_key).versions.find do |v|
          if fetch(:s3_archive_object_version_id) then v.version_id == fetch(:s3_archive_object_version_id)
          else v.is_latest
          end
        end
      end

      private

      def s3_client
        @s3_client ||= Aws::S3::Client.new(fetch(:s3_archive_client_options))
      end

      def local_cache
        @local_cache ||= LocalChache.new(
          File.join(fetch(:s3_archive_local_download_dir), fetch(:stage).to_s),
          File.join(fetch(:s3_archive_local_cache_dir), fetch(:stage).to_s),
          s3_client
        )
      end


      class S3Params
        attr_reader :bucket, :object_prefix

        def initialize(repo_url)
          uri = URI.parse(repo_url)
          @bucket = uri.host
          @object_prefix = uri.path.sub(/\/?\Z/, '/').slice(1..-1) # normalize path
        end
      end

      class LocalChache
        attr_reader :downlowd_dir, :cache_dir, :s3_client
        include FileUtils
        class ResourceBusyError < StandardError; end

        def initialize(downlowd_dir, cache_dir, s3_client)
          @s3_client = s3_client
          @download_dir = download_dir
          @cache_dir = cache_dir
        end

        def download(bucket, object_key, version_id, etag = nil)
          download_lock do
            target_file = File.join(download_dir, File.basename(object_key))
            tmp_file = "#{target_file}.part"
            etag_file = File.join(download_dir, ".#{File.basename(object_key)}.etag")
            raise "#{tmp_file} is found. Another process is running?" if File.exist?(tmp_file)

            if all_file_exist?([target_file, etag_file]) && File.read(etag_file) == etag
              backend.info "#{target_file} (etag:#{etag}) is found. download skipped."
            else
              backend.info "Download #{object_key} to #{target_file}"
              mkdir_p(File.dirname(target_file))
              File.open(tmp_file, 'w') do |file|
                opts = { bucket: bucket, key: object_key }
                opts[:version_id] = version_id if version_id
                s3_client.get_object(opts, target: file)
              end
              move(tmp_file, target_file)
              File.write(etag_file, etag)
            end
          end
        end

        def cleanup(keep: 0)
          downloaded_files = Dir.glob(download_dir).sort_by(&File.method(:mtime))
        end

        def all_file_exist?(arr)
          arr.all?(&File.method(:exist?))
        end

        def download_lock(&block)
          mkdir_p(File.dirname(download_dir))
          lockfile = "#{download_dir}.lock"
          begin
            File.open(lockfile, "w") do |file|
              raise ResourceBusyError, "Could not get #{lockfile}" unless file.flock(File::LOCK_EX | File::LOCK_NB)
              block.call
            end
          ensure
            rm lockfile if File.exist? lockfile
          end
        end
      end
    end
  end
end

#       def set_defaults




#         set_if_empty :s3_archive_client_options, {}
#         set_if_empty :s3_archive_extract_to, :local # :local or :remote
#         set_if_empty(:s3_archive_sort_proc, ->(new, old) { old.key <=> new.key })
#         set_if_empty :s3_archive_object_version_id, nil
#         set_if_empty :s3_archive_local_download_dir, "tmp/archives"
#         set_if_empty :s3_archive_local_cache_dir, "tmp/deploy"
#         set_if_empty :s3_archive_remote_rsync_options, ['-az', '--delete']
#         set_if_empty :s3_archive_remote_rsync_ssh_options, []
#         set_if_empty :s3_archive_remote_rsync_runner_options, {}
#         set_if_empty :s3_archive_rsync_cache_dir, "shared/deploy"
#         set_if_empty :s3_archive_hardlink_release, false

#         # remote
#         set_if_empty :s3_archive_remote_cache_dir, "shared/archives"
#         # internal use
#         set_if_empty :s3_archive_rsync_copy, "rsync --archive --acls --xattrs"
#       end

#       def define_tasks
# binding.pry
# #         case fetch(:s3_archive_extract_to)
# #         when :local
#         eval_rakefile File.expand_path("../tasks/s3_archive.rake", __FILE__) #
#         eval_rakefile File.expand_path("../tasks/s3_archive_remote.rake", __FILE__)
#       end


#       def local_check
#         s3_client.list_objects(bucket: s3params.bucket, prefix: s3params.object_prefix)
#       end

#       def get_object(target)
#         opts = { bucket: s3params.bucket, key: archive_object_key }
#         opts[:version_id] = fetch(:s3_archive_object_version_id) if fetch(:s3_archive_object_version_id)
#         s3_client.get_object(opts, target: target)
#       end

#       def remote_check
#         backend.execute :echo, 'check ssh'
#         # binding.pry
#         backend.execute :aws, 's3', 'ls', ['s3:/', s3params.bucket, archive_object_key].join('/')  if fetch(:s3_archive_extract_to) == :remote
#       end

#       def download
#         # sef_if_empty :s3_archive_remote_cache_dir, "shared/archives"

#         backend.execute :aws, 's3', 'cp', ['s3:/', s3params.bucket, archive_object_key].join('/'), File.join(fetch(:s3_archive_remote_cache_dir), '')
#       end

#       def stage
#         stage_lock do
#           archive_dir = File.join(fetch(:s3_archive_local_download_dir), fetch(:stage).to_s)
#           archive_file = File.join(archive_dir, File.basename(archive_object_key))
#           tmp_file = "#{archive_file}.part"
#           etag_file = File.join(archive_dir, ".#{File.basename(archive_object_key)}.etag")
#           fail "#{tmp_file} is found. Another process is running?" if File.exist?(tmp_file)
#           etag = get_object_metadata.tap { |it| fail "No such object: #{current_revision}" if it.nil? }.etag


#           if [archive_file, etag_file].all? { |f| File.exist?(f) } && File.read(etag_file) == etag
#             backend.info "#{archive_file} (etag:#{etag}) is found. download skipped."
#           else
#             backend.info "Download #{current_revision} to #{archive_file}"
#             mkdir_p(File.dirname(archive_file))
#             File.open(tmp_file, 'w') do |f|
#               get_object(f)
#             end
#             move(tmp_file, archive_file)
#             File.write(etag_file, etag)
#           end

#           remove_entry_secure(fetch(:s3_archive_local_cache_dir)) if File.exist? fetch(:s3_archive_local_cache_dir)
#           mkdir_p(fetch(:s3_archive_local_cache_dir))
#           case archive_file
#           when /\.zip\Z/
#             cmd = "unzip -q -d #{fetch(:s3_archive_local_cache_dir)} #{archive_file}"
#           when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
#             cmd = "tar xf #{archive_file} -C #{fetch(:s3_archive_local_cache_dir)}"
#           end

#           release_lock_on_stage do
#             run_locally do
#               execute cmd
#             end
#           end
#         end
#       end

#       def cleanup_stage_dir
#         run_locally do
#           archives_dir = File.join(fetch(:s3_archive_local_download_dir), fetch(:stage).to_s)
#           archives = capture(:ls, '-xtr', archives_dir).split
#           if archives.count >= fetch(:keep_releases)
#             to_be_removes = (archives - archives.last(fetch(:keep_releases)))
#             if to_be_removes.any?
#               to_be_removes_str = to_be_removes.map do |file|
#                 File.join(archives_dir, file)
#               end.join(' ')
#               execute :rm, to_be_removes_str
#             end
#           end
#         end
#       end

#       def transfer_sources(dest)
#         fail "#{__method__} must be called in run_locally" unless backend.is_a?(SSHKit::Backend::Local)

#         rsync = ['rsync']
#         rsync.concat fetch(:s3_archive_remote_rsync_options, [])
#         rsync << (fetch(:s3_archive_local_cache_dir) + '/')

#         if dest.local?
#           rsync << ('--no-compress')
#           rsync << rsync_cache_dir
#         else
#           rsync << "-e 'ssh #{dest.ssh_key_option} #{fetch(:s3_archive_remote_rsync_ssh_options).join(' ')}'"
#           rsync << "#{dest.login_user_at}#{dest.hostname}:#{rsync_cache_dir}"
#         end

#         release_lock_on_create do
#           backend.execute(*rsync)
#         end
#       end

#       def release
#         if fetch(:s3_archive_extract_to) == :local
#           link_option = if fetch(:s3_archive_hardlink_release) && backend.test("[ `readlink #{current_path}` != #{release_path} ]")
#                           "--link-dest `readlink #{current_path}`"
#                         end
#           create_release = %[#{fetch(:s3_archive_rsync_copy)} #{link_option} "#{rsync_cache_dir}/" "#{release_path}/"]
#         else
#           archive_file = File.basename(archive_object_key)
#           archive_path = File.join(fetch(:s3_archive_remote_cache_dir), archive_file)
#           case archive_file
#           when /\.zip\Z/
#             create_release = "unzip -q -d #{release_path} #{archive_path}"
#           when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
#             create_release = "tar xf #{archive_path} -C #{release_path}"
#           end
#         end
#         backend.execute create_release
#       end

#       def current_revision
#         if fetch(:s3_archive_object_version_id)
#           "#{archive_object_key}?versionid=#{fetch(:s3_archive_object_version_id)}"
#         else
#           archive_object_key
#         end
#       end

#       def archive_object_key
#         @archive_object_key ||=
#           case fetch(:branch, :latest).to_sym
#           when :master, :latest
#             latest_object_key
#           else
#             s3params.object_prefix + fetch(:branch).to_s
#           end
#       end

#       def rsync_cache_dir
#         File.join(deploy_to, fetch(:s3_archive_rsync_cache_dir))
#       end

#       def s3params
#         @s3params ||= S3Params.new(fetch(:repo_url))
#       end

#       def get_object_metadata
#         s3_client.list_object_versions(bucket: s3params.bucket, prefix: archive_object_key).versions.find do |v|
#           if fetch(:s3_archive_object_version_id) then v.version_id == fetch(:s3_archive_object_version_id)
#           else v.is_latest
#           end
#         end
#       end

#       def list_all_objects
#         response = s3_client.list_objects(bucket: s3params.bucket, prefix: s3params.object_prefix)
#         response.inject([]) do |objects, page|
#           objects + page.contents
#         end
#       end

#       def latest_object_key
#         list_all_objects.sort(&fetch(:s3_archive_sort_proc)).first.key
#       end

#       private

#       def release_lock_on_stage(&block)
#         release_lock((File::LOCK_EX | File::LOCK_NB), &block) # exclusive lock
#       end

#       def release_lock_on_create(&block)
#         release_lock(File::LOCK_SH, &block)
#       end

#       def release_lock(lock_mode, &block)
#         mkdir_p(File.dirname(fetch(:s3_archive_local_cache_dir)))
#         lockfile = "#{fetch(:s3_archive_local_cache_dir)}.#{fetch(:stage)}.release.lock"
#         File.open(lockfile, File::RDONLY | File::CREAT) do |file|
#           if file.flock(lock_mode)
#             block.call
#           else
#             fail ResourceBusyError, "Could not get #{lockfile}"
#           end
#         end
#       end

#       def stage_lock(&block)
#         mkdir_p(File.dirname(fetch(:s3_archive_local_cache_dir)))
#         lockfile = "#{fetch(:s3_archive_local_cache_dir)}.#{fetch(:stage)}.lock"
#         File.open(lockfile, "w") do |file|
#           fail ResourceBusyError, "Could not get #{lockfile}" unless file.flock(File::LOCK_EX | File::LOCK_NB)
#           block.call
#         end
#       ensure
#         rm lockfile if File.exist? lockfile
#       end

#       def s3_client
#         @s3_client ||= Aws::S3::Client.new(fetch(:s3_archive_client_options))
#       end

#        class LocalExtractor
#         # class ResourceBusyError < StandardError; end

#         # include FileUtils

#         def stage
#           stage_lock do
#             archive_dir = File.join(fetch(:s3_archive_local_download_dir), fetch(:stage).to_s)
#             archive_file = File.join(archive_dir, File.basename(archive_object_key))
#             tmp_file = "#{archive_file}.part"
#             etag_file = File.join(archive_dir, ".#{File.basename(archive_object_key)}.etag")
#             fail "#{tmp_file} is found. Another process is running?" if File.exist?(tmp_file)
#             etag = get_object_metadata.tap { |it| fail "No such object: #{current_revision}" if it.nil? }.etag


#             if [archive_file, etag_file].all? { |f| File.exist?(f) } && File.read(etag_file) == etag
#               context.info "#{archive_file} (etag:#{etag}) is found. download skipped."
#             else
#               context.info "Download #{current_revision} to #{archive_file}"
#               mkdir_p(File.dirname(archive_file))
#               File.open(tmp_file, 'w') do |f|
#                 get_object(f)
#               end
#               move(tmp_file, archive_file)
#               File.write(etag_file, etag)
#             end

#             remove_entry_secure(fetch(:s3_archive_local_cache_dir)) if File.exist? fetch(:s3_archive_local_cache_dir)
#             mkdir_p(fetch(:s3_archive_local_cache_dir))
#             case archive_file
#             when /\.zip\Z/
#               cmd = "unzip -q -d #{fetch(:s3_archive_local_cache_dir)} #{archive_file}"
#             when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
#               cmd = "tar xf #{archive_file} -C #{fetch(:s3_archive_local_cache_dir)}"
#             end

#             release_lock_on_stage do
#               run_locally do
#                 execute cmd
#               end
#             end
#           end
#         end

#         def stage_lock(&block)
#           mkdir_p(File.dirname(fetch(:s3_archive_local_cache_dir)))
#           lockfile = "#{fetch(:s3_archive_local_cache_dir)}.#{fetch(:stage)}.lock"
#           begin
#             File.open(lockfile, "w") do |file|
#               fail ResourceBusyError, "Could not get #{lockfile}" unless file.flock(File::LOCK_EX | File::LOCK_NB)
#               block.call
#             end
#           ensure
#             rm lockfile if File.exist? lockfile
#           end
#         end
#       end

#       class RemoteExtractor
#       end

#       class S3Params
#         attr_reader :bucket, :object_prefix

#         def initialize(repo_url)
#           uri = URI.parse(repo_url)
#           @bucket = uri.host
#           @object_prefix = uri.path.sub(/\/?\Z/, '/').slice(1..-1) # normalize path
#         end
#       end
#     end
#   end

#   class Configuration
#     class Server
#       def login_user_at
#         user = [user, ssh_options[:user]].compact.first
#         user ? "#{user}@" : ''
#       end

#       def ssh_key_option
#         key = [keys, ssh_options[:keys]].flatten.compact.first
#         key ? "-i #{key}" : ''
#       end

#       def ssh_port_option
#         port ? "-p #{port}" : ''
#       end
#     end
#   end
# end
