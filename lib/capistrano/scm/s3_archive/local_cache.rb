module Capistrano
  class SCM
    class S3Archive
      class LocalCache
        attr_reader :backend, :download_dir, :cache_dir, :archive_object
        include FileUtils
        class ResourceBusyError < StandardError; end

        def initialize(backend, download_dir, cache_dir, archive_object)
          @backend = backend
          @download_dir = download_dir
          @cache_dir = cache_dir
          @archive_object = archive_object
        end

        def download
          download_lock do
            tmp_file = "#{target_file}.part"
            etag_file = File.join(download_dir, ".#{archive_object.key_basename}.etag")
            raise "#{tmp_file} is found. Another process is running?" if File.exist?(tmp_file)

            if all_file_exist?([target_file, etag_file]) && File.read(etag_file) == archive_object.etag
              backend.info "#{target_file} (etag:#{archive_object.etag}) is found. download skipped."
            else
              backend.info "Download s3://#{archive_object.bucket}/#{archive_object.key} to #{target_file}"
              mkdir_p(File.dirname(target_file))
              File.open(tmp_file, 'w') do |file|
                archive_object.get_object(file)
              end
              move(tmp_file, target_file)
              File.write(etag_file, archive_object.etag)
            end
          end
        end

        def extract
          remove_entry_secure(cache_dir) if File.exist?(cache_dir)
          mkdir_p(cache_dir)
          case target_file
          when /\.zip\?.*\Z/
            cmd = "unzip -q -d #{cache_dir} #{target_file}"
          when /\.tar\.gz\?.*\Z|\.tar\.bz2\?.*\Z|\.tgz\?.*\Z/
            cmd = "tar xf #{target_file} -C #{cache_dir}"
          end

          backend.execute cmd # should I use `execute`?
        end

        def cleanup(keep: 0)
          downloaded_files = Dir.glob(File.join(download_dir, '*')).sort_by(&File.method(:mtime))
          return if downloaded_files.count <= keep

          remove_keys = (downloaded_files - downloaded_files.last(keep)).map { |f| File.basename(f, '.*') }.flat_map { |f| ["#{f}*", ".#{f}*"] }
          to_be_removes = Dir.glob(remove_keys, base: download_dir)

          remove(to_be_removes, force: true, verbose: true)
        end

        def target_file
          basename = [archive_object.key_basename, archive_object.version_id].join('?')
          File.join(download_dir, basename)
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
