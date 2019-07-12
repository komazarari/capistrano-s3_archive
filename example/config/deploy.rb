# config valid for current version and patch releases of Capistrano
lock "~> 3.11.0"

set :application, "my_app_name"
set :repo_url, "s3://komazarari-public-01/capistrano-s3_archive/test-archives/"

# set :branch, '20190711_my_app.zip'
# set :branch, :master # same as :latest
set :branch, :latest

set :s3_archive_client_options, { region: 'us-east-1' }
set :s3_archive_strategy, :direct
# set :s3_archive_object_version_id, 'QUC.zh2MUXf7_ZCkFa7IZJN5CJKYlLKy'
