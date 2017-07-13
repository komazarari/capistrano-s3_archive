plugin = self

namespace :s3_archive do
  desc 'Check that the S3 buckets are reachable'
  task :check do
    run_locally do
      plugin.local_check
    end

    on release_roles :all do
      plugin.remote_check
    end
  end

  desc 'Extruct and stage the S3 archive in a stage directory'
  task :stage do
    if fetch(:skip_staging, false)
      info "Skip extracting and staging."
      next
    end

    run_locally do
      plugin.stage
    end
  end

  after :stage, :cleanup_stage_dir do
    run_locally do
      plugin.cleanup_stage_dir
    end
  end

  desc 'Copy repo to releases'
  task create_release: :stage do
    on release_roles(:all), fetch(:s3_archive_remote_rsync_runner_options) do |server|
      test "[ -e #{plugin.rsync_cache_dir} ]" # implicit initialize for 'server'
      run_locally do
        plugin.transfer_sources(server)
      end
    end

    on release_roles(:all) do
      execute :mkdir, '-p', release_path
      plugin.release
    end
  end

  desc 'Determine the revision that will be deployed'
  task :set_current_revision do
    set :current_revision, plugin.current_revision
  end
end unless Rake::Task.task_defined?("s3_archive:check")

task :deploy_only do
  set :skip_staging, true
  invoke :deploy
end
