require 'yaml'
require 'net/ftp'

namespace :backup do

  namespace :creation do
    desc 'create backup dir'
    task :dir => :environment do
      execute mk_dir(@dir)
    end

    desc 'create db backup'
    task :db  => :environment do
      execute mysqldump
    end

    desc 'create cms backup '
    task :cms  => :environment do
      execute cms_backup
    end

    desc 'create zip of the backup '
    task :archive => :environment do
      execute archive
    end

    desc 'create zip of the backup '
    task :link => :environment do
      files = files_sorted_by_time("#{@folder_path}/*.zip").reverse
      execute ln_nfs(files.first)
    end

    desc 'start backup'
    task :start => [:environment, "backup:creation:dir", "backup:creation:db", "backup:creation:cms", "backup:creation:archive","backup:creation:link"]
  end

  namespace :rsync do
    desc 'sync from local to backup server'
    task :server do
      execute create_remote_dir
      execute  rsync_server
    end

    desc 'sync from backup server to local'
    task :local do
      execute rsync_local
    end

    desc 'sync latest from backup server to local'
    task :latest_from_server do
      execute rsync_latest_to_local
    end
  end

  namespace :cleanup do
    desc 'cleanup on local'
    task :local => :environment do
      puts 'cleaning up local'
      execute dir_remove(@dir)
      files = files_sorted_by_time("#{@folder_path}/*.zip").reverse
      cleanup_old_files(files)
    end

    desc 'start cleanup'
    task :start , [:env] => [:environment, "backup:cleanup:local"]
  end

  namespace :restore do

    desc 'create restore dir'
    task :mkdir => :environment do
      execute mk_dir(@backup_restore)
    end
    desc 'ceate cms backup '
    task :cms  => :environment do
      execute restore_cms
    end

    desc 'restore db backup'
    task :db  => :environment do
      @db_restore =  db_restore_file(@cms_path)
      execute restore_db
      execute file_remove(@db_restore)
    end

    desc 'after restore cleanup'
    task :cleanup  => :environment do
      execute dir_remove(@cms_restore)
    end

    desc 'restoring from local'
    task :local_backup => :environment do
      puts 'restoring from backup'
      files = files_sorted_by_time("#{@folder_dir}/*.zip")
      prepare_retsore(files.last) unless files.nil?
    end

    desc 'restoring from local'
    task :latest_restore => :environment do
      puts 'restoring from backup'
      files = files_sorted_by_time("#{@backup_restore}/*.zip")
      @cms_restore = files.last unless files.nil?
    end

    desc 'restore from local'
    task :initialize, [:env] => [:environment,  'backup:restore:local_backup', 'backup:restore:restoring']

    desc 'restore latest from server'
    task :from_server, [:env] => [:environment,'backup:restore:setup', 'backup:rsync:local', 'backup:restore:initialize']

    desc 'restore latest from server'
    task :latest_from_server, [:env] => [:environment,'backup:restore:setup', 'backup:rsync:latest_from_server', 'backup:restore:latest_available']

    desc 'start restore'
    task :start, [:env] => [:environment, 'backup:restore:setup', 'backup:restore:initialize']

    desc 'restore from local'
    task :latest_available, [:env] => [:environment,  'backup:restore:latest_restore', 'backup:restore:restoring']

    desc 'restoring and cleanup'
    task :restoring => [:environment,'backup:restore:cms', 'backup:restore:db' ,'backup:restore:cleanup']

    desc 'setup restore'
    task :setup , [:env]=> [:environment, "backup:setup", 'backup:restore:mkdir']

  end


  desc "Start Backup"
  task :start, [:env] => [:environment, "backup:create", 'backup:cleanup:start', 'backup:rsync:server']

  desc 'create backup'
  task :create, [:env] => [:environment, 'backup:setup', 'backup:creation:start']

  desc 'setup'
  task :setup, [:env] => :environment do |t,args|
    @env = args.env || 'mock'
    @backup_settings = env_based_settings[@env] || env_based_settings['mock']
    setup(@backup_settings)
  end


  def prepare_retsore(file)
    restore_file_path = (execute "readlink #{file}").chomp
    execute "cp -R #{@folder_dir}/#{restore_file_path} #{@backup_restore}/"
    @cms_restore = File.join @backup_restore, File.basename(restore_file_path)
  end

  def files_sorted_by_time(folder_path)
    Dir[folder_path].sort_by{ |f| File.mtime(f)}
  end

  def cleanup_old_files(files)
    if files.size > @backup_count
      files_to_be_deleted = files.drop(@backup_count)
      remove_cmd(files_to_be_deleted) {|cmd| execute cmd}
    else
      puts 'nothing to remove'
    end
  end

  def remove_cmd(files)
    command  = StringIO.new
    command << 'rm'
    files.each do |file|
      command << ' '
      command << file
    end
    yield command.string if block_given?
  end



  def archive
    "cd #{@dir}; zip  #{@cms_backup} #{@db_backup} --out #{@folder_path}/backup_#{@timestamp}.zip"
  end

  def mk_dir(dir)
    "mkdir -p #{dir}"
  end

  def ln_nfs(file)
    zip = File.basename file
    "cd #{@folder_dir}; ln -nfs #{@backup_folder}/#{zip} #{@latest_backup}"
  end

  def rsync_server
    "rsync -azh --delete --progress #{@folder_dir}/ #{@rsync_username}@#{@rsync_host}:#{@rsync_dir}/"
  end

  def rsync_local
    "rsync -azh --progress #{@rsync_username}@#{@rsync_host}:#{@rsync_dir}/ #{@folder_dir}/ "
  end

  def rsync_latest_to_local
    "rsync -azhkHKdL  --keep-dirlinks --progress #{@rsync_username}@#{@rsync_host}:#{@rsync_dir}/#{@latest_backup} #{@backup_restore}/ "
  end

  def create_remote_dir
    "ssh #{@rsync_username}@#{@rsync_host} mkdir -p #{@rsync_dir}"
  end

  def dir_remove(dir)
    "rm -Rf #{dir}"
  end

  def file_remove(file)
    "rm #{file}"
  end

  def restore_cms
    "tar xvf #{@cms_restore} -C #{@cms_path}"
  end

  def cms_backup
    @cms_backup = "cms_#{@timestamp}.zip"
    "cd #{@cms_path} ; zip -r #{@dir}/#{@cms_backup} *"
  end

  def mysqldump
    @db_backup = "#{@application}_dev_#{@timestamp}.sql"
    "mysqldump -u#{@db_username} -p#{@db_password} #{@db_name} > #{@dir}/#{@db_backup}"
  end

  def restore_db
    "mysql -u#{@db_username} -p#{@db_password} #{@db_name} < #{@db_restore}"
  end

  def db_restore_file(path)
    files_sorted_by_time("#{path}/*.sql")[0]
  end


  def execute(cmd)
    puts '#'*80
    puts "#{cmd}"
    puts '#'*80
    output = (@env == 'mock' ?  "mocking => #{cmd}"  :  %x[#{cmd}])
    puts output
    output
  end

  def setup(settings)
    local_server_settings settings['local']
    db_settings settings['db']
    rsync_settings settings['rsync']
  end


  def expand_path(path)
    File.expand_path path
  end

  def env_based_settings
    yml ||= File.join(Dir.getwd , 'lib/tasks', "backup.yml")
    settings ||= YAML.load_file(yml)
  end

  def local_server_settings(settings)
    @timestamp ||= Time.now.strftime('%Y%m%d%H%M%S')
    @temp_dir ||= "backup_#{@timestamp}"

    @application ||= settings['application']
    @app_root ||= settings['app_root']
    @cms_folder ||= settings['cms_path']
    @backup_restore ||= expand_path settings['restore_pkg_path']
    @backup_folder ||= settings['backup_folder']
    @folder_dir ||= expand_path settings['backup_dir']
    @backup_count ||= settings['backup_count']
    @latest_backup ||= settings['latest_backup']

    create_paths

  end

  def create_paths
    @app_folder ||= expand_path(File.join(@app_root, @application))
    @folder_path ||= expand_path(File.join(@folder_dir, @backup_folder))
    @cms_path ||= expand_path(File.join(@app_folder, @cms_folder))
    @dir ||= expand_path(File.join(@folder_path , @temp_dir))
  end

  def db_settings(settings)
    @db_username ||= settings['username']
    @db_password ||= settings['password']
    @db_name ||= settings['name']
  end

  def rsync_settings(settings)
    @rsync_username ||= settings['username']
    @rsync_password ||= settings['password']
    @rsync_host ||= settings['host']
    @rsync_dir ||= expand_path(settings['sync_dir'])
  end
end