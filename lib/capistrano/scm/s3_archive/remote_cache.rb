module Capistrano
  class SCM
    class S3Archive
      class RemoteCache
        attr_reader :backend, :download_dir, :archive_object

        def initialize(backend, download_dir, archive_object)
          @backend = backend
          @download_dir = download_dir
          @archive_object = archive_object
        end

        def download
          tmp_file = "#{target_file}.part"
          etag_file = File.join(download_dir, ".#{archive_object.key_basename}.etag")
          if backend.test("[ -f #{target_file} -a -f #{etag_file} ]") &&
             backend.capture(:cat, etag_file) == archive_object.etag
            backend.info "#{target_file} (etag:#{archive_object.etag}) is found. download skipped."
          else
            backend.info "Download s3://#{archive_object.bucket}/#{archive_object.key} to #{target_file}"
            backend.execute(:mkdir, "-p", download_dir)
            backend.execute(:aws, *['s3api', 'get-object', "--bucket #{archive_object.bucket}", "--key #{archive_object.key}", archive_object.version_id ? "--version-id #{archive_object.version_id}" : nil, tmp_file].compact)
            backend.execute(:mv, tmp_file, target_file)
            backend.execute(:echo, "-n", "'#{archive_object.etag}'", "|tee", etag_file)
          end
        end

        def cleanup(keep: 0)
          downloaded_files = backend.capture(:ls, "-xtr", download_dir).split
          return if downloaded_files.count <= keep

          to_be_removes = (downloaded_files - downloaded_files.last(keep)).flat_map do |file|
            [File.join(download_dir, file), File.join(download_dir, ".#{f}.etag")]
          end
          backend.execute(:rm, '-f', *to_be_removes)
        end

        def target_file
          basename = [archive_object.key_basename, archive_object.version_id].join('?')
          File.join(download_dir, basename)
        end
      end
    end
  end
end
