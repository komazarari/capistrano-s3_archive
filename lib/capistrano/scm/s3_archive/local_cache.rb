module Capistrano
  class SCM
    class S3Archive
      class LocalCache
        attr_reader :backend, :download_dir, :cache_dir, :s3_client
        include FileUtils
        class ResourceBusyError < StandardError; end

        def initialize(backend, download_dir, cache_dir, s3_client)
          @backend = backend
          @s3_client = s3_client
          @download_dir = download_dir
          @cache_dir = cache_dir
        end

        def download_and_extract(bucket, object_key, version_id, etag = nil)
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
            extract(target_file, cache_dir)
          end
        end

        def extract(file, target_dir)
          remove_entry_secure(target_dir) if File.exist?(target_dir)
          mkdir_p(target_dir)
          case file
          when /\.zip\Z/
            cmd = "unzip -q -d #{target_dir} #{file}"
          when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
            cmd = "tar xf #{file} -C #{target_dir}"
          end

          backend.execute cmd
        end

        def cleanup(keep: 0)
          downloaded_files = Dir.glob(download_dir).sort_by(&File.method(:mtime))
          return if downloaded_files.count <= keep

          remove(downloaded_files - downloaded_files.last(keep))
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
