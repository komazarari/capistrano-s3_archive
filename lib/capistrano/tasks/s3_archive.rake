namespace :s3_archive do

  def strategy
    @strategy ||= Capistrano::S3Archive::SCM.new(self, fetch(:s3_archive_strategy, Capistrano::S3Archive::SCM::RsyncStrategy))
  end

  desc 'Check that the S3 buckets are reachable'
  task :check do
    run_locally do
      strategy.local_check
    end

    on release_roles :all do
      strategy.check
    end
  end

  desc 'Extruct and stage the S3 archive in a stage directory'
  task :stage do
    run_locally do
      
      # No need to deploy to the remote node if it already has the same
      # revision as it's current.
      if strategy.current_revision == fetch(:previous_revision)
        raise "Release #{fetch(:previous_revision)} already exist on this node."
      end

      if fetch(:skip_staging, false)
        info "Skip extructing and staging."
      else
        strategy.stage
      end
    end
  end

  after :stage, :cleanup do
    run_locally do
      strategy.cleanup
    end
  end

  desc 'Copy repo to releases'
  task :create_release => :stage do
    on release_roles(:all), fetch(:archive_release_runner_options) do |server|
      execute :mkdir, '-p', release_path
      strategy.release(server)
    end
  end

  desc 'Determine the revision that will be deployed'
  task :set_current_revision do
    set :current_revision, strategy.current_revision
  end
end unless Rake::Task.task_defined?("s3_archive:check")

task :deploy_only do
  set :skip_staging, true
  invoke :deploy
end
