plugin = self

namespace :s3_archive do
  desc 'Check that the S3 buckets are reachable'
  task :check do
    run_locally do
      plugin.local_check
    end

    on release_roles(:all) do
      plugin.remote_check
    end
  end

  desc 'Deploy to release_path'
  task create_release: :stage do
    on release_roles(:all) do
      execute :mkdir, '-p', release_path
      plugin.deploy_to_release_path
    end
  end

  desc 'Determine the revision that will be deployed'
  task :set_current_revision do
    set :current_revision, plugin.current_revision
  end

  desc 'Stage the S3 archive to cache directory'
  task :stage do
    case plugin.strategy
    when :direct
      on release_roles(:all) do
        plugin.download_to_shared_path
      end
    when :rsync
      run_locally do
        plugin.download_to_local_cache unless fetch(:s3_archive_skip_download)
      end
      on release_roles(:all), fetch(:s3_archive_remote_rsync_runner_options) do |server|
        test "[ -e #{plugin.rsync_cache_dir} ]" # implicit initialize for 'server'
        run_locally { plugin.transfer_sources(server) }
      end
    else
      error "Invalid stragegy #{plugin.strategy} of SCM::S3Archive"
      exit 1
    end
  end

  after :stage, :cleanup_stage_dir do
    case plugin.strategy
    when :direct
      on release_roles(:all) do
        plugin.cleanup_shared_path
      end
    when :rsync
      run_locally do
        plugin.cleanup_local_cache
      end
    end
  end
end unless Rake::Task.task_defined?("s3_archive:check")
