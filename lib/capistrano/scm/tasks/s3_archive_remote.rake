plugin = self

namespace :s3_archive_remote do
  desc 'Check that the S3 buckets are reachable'
  task :check do
    run_locally do
      plugin.local_check
    end
    on release_roles :all do
      plugin.remote_check
    end
  end

  desc 'Download the S3 archive'
  task :download do
    on release_roles(:all) do
      plugin.download
    end
  end

  desc 'Extract files from archive to releases'
  task create_release: :download do
    on release_roles(:all) do
      execute :mkdir, '-p', release_path
      plugin.release
    end
  end

  after :create_release, :cleanup_downloads do
    on release_roles(:all) do
      plugin.cleanup_downloads
    end
  end

  desc 'Determine the revision that will be deployed'
  task :set_current_revision do
    set :current_revision, plugin.current_revision
  end
end unless Rake::Task.task_defined?("s3_archive_remote:check")
