require "test_helper"

class DatabaseBackupTest < ActiveSupport::TestCase
  setup do
    @previous_subdirectory = Setting.backup_subdirectory
    @dir = Dir.mktmpdir("backup-test")

    # Stub the mount: MOUNT_ROOT is a real bind mount in this container, and an
    # unstubbed test would write dumps into the operator's actual backup folder.
    DatabaseBackup.stubs(:mount_root).returns(Pathname.new(@dir))

    # The app never creates the folder, so the test has to.
    @folder = "backups"
    @backup_dir = File.join(@dir, @folder)
    FileUtils.mkdir_p(@backup_dir)
    Setting.backup_subdirectory = @folder
  end

  teardown do
    Setting.backup_subdirectory = @previous_subdirectory
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  test "creates a restorable dump and lists it" do
    backup = DatabaseBackup.create!

    assert backup.path.file?
    assert backup.size.positive?
    assert backup.filename.end_with?(".dump")
    assert_equal "PGDMP", File.binread(backup.path, 5), "expected a pg_dump custom-format archive"
    assert_equal [ backup.filename ], DatabaseBackup.all.map(&:filename)
  end

  test "lists newest first and ignores unrelated files" do
    older = File.join(@backup_dir, "maybe_test-20250101-000000.dump")
    newer = File.join(@backup_dir, "maybe_test-20260101-000000.dump")
    File.write(older, "x")
    File.write(newer, "x")
    File.utime(Time.now - 3600, Time.now - 3600, older)
    File.write(File.join(@backup_dir, "notes.txt"), "x")
    File.write(File.join(@backup_dir, "evil.dump"), "x")

    assert_equal %w[maybe_test-20260101-000000.dump maybe_test-20250101-000000.dump],
                 DatabaseBackup.all.map(&:filename)
  end

  # Filenames are stamped in UTC, but a backup written while Time.zone was set to
  # something else (a leaked zone on a Sidekiq thread) carries a shifted name.
  # Ordering must follow mtime so such a file does not jump the list.
  test "orders by mtime, not by the timestamp in the filename" do
    ahead = File.join(@backup_dir, "maybe_test-20260101-235900.dump")  # name looks latest
    actual_newest = File.join(@backup_dir, "maybe_test-20260101-120000.dump")
    File.write(ahead, "x")
    File.write(actual_newest, "x")
    File.utime(Time.now - 7200, Time.now - 7200, ahead)

    assert_equal %w[maybe_test-20260101-120000.dump maybe_test-20260101-235900.dump],
                 DatabaseBackup.all.map(&:filename)
  end

  test "stamps the filename in UTC regardless of the current Time.zone" do
    backup = Time.use_zone("Europe/Kyiv") { DatabaseBackup.create! }

    stamp = backup.filename[/(\d{8}-\d{6})/, 1]
    assert_in_delta Time.strptime("#{stamp} UTC", "%Y%m%d-%H%M%S %Z").to_i, Time.now.utc.to_i, 120,
      "expected a UTC stamp, got #{stamp} while Time.zone was Europe/Kyiv"
  end

  # A .sql.gz left over from the short-lived gzip format is still manageable, so
  # it can be downloaded or deleted rather than becoming an invisible file.
  test "still lists and finds a leftover .sql.gz backup" do
    File.write(File.join(@backup_dir, "maybe_test-20250101-000000.sql.gz"), "x")
    File.write(File.join(@backup_dir, "maybe_test-20260101-000000.dump"), "x")

    assert_equal %w[maybe_test-20260101-000000.dump maybe_test-20250101-000000.sql.gz],
                 DatabaseBackup.all.map(&:filename)
    assert_equal "maybe_test-20250101-000000.sql.gz",
                 DatabaseBackup.find("maybe_test-20250101-000000.sql.gz").filename
  end

  # A crashed dump must never be listed or restored as if it were complete.
  test "ignores partial dumps still being written" do
    File.write(File.join(@backup_dir, "maybe_test-20260101-000000.dump.part"), "x")

    assert_empty DatabaseBackup.all
  end

  test "find rejects traversal and anything not matching the filename pattern" do
    File.write(File.join(@backup_dir, "maybe_test-20260101-000000.dump"), "x")

    [
      "../../../etc/passwd",
      "../#{File.basename(@backup_dir)}/maybe_test-20260101-000000.dump",
      "maybe_test-20260101-000000.dump/../../secret",
      "notes.txt",
      "",
      nil
    ].each do |bad|
      assert_raises(DatabaseBackup::Error, "expected #{bad.inspect} to be rejected") do
        DatabaseBackup.find(bad)
      end
    end
  end

  test "find returns a backup that really is in the directory" do
    name = "maybe_test-20260101-000000.dump"
    File.write(File.join(@backup_dir, name), "x")

    assert_equal name, DatabaseBackup.find(name).filename
  end

  test "find raises for a well-formed name that does not exist" do
    assert_raises(DatabaseBackup::Error) { DatabaseBackup.find("maybe_test-20990101-000000.dump") }
  end

  test "delete! removes the file" do
    backup = DatabaseBackup.create!

    backup.delete!

    assert_not backup.path.exist?
    assert_empty DatabaseBackup.all
  end

  # Backups must live in a folder of their own, never at the root of the mount,
  # which is shared with unrelated files.
  test "a blank folder is rejected rather than defaulting to the mount root" do
    [ "", "   ", "/", "..", "./", "../.." ].each do |input|
      assert_equal "", DatabaseBackup.sanitize_subdirectory(input), "#{input.inspect} should sanitise to blank"
    end

    Setting.backup_subdirectory = "  "

    assert_empty DatabaseBackup.all
    error = assert_raises(DatabaseBackup::Error) { DatabaseBackup.create! }
    assert_match "not set", error.message
  end

  # The folder is shared from the host; creating it here would make a directory
  # inside the container that vanishes on rebuild.
  test "never creates the backup directory" do
    Setting.backup_subdirectory = "not-created-yet"
    target = DatabaseBackup.directory

    assert_not target.exist?
    error = assert_raises(DatabaseBackup::Error) { DatabaseBackup.create! }

    assert_match "does not exist", error.message
    assert_not target.exist?, "create! must not create the directory"
    assert_not DatabaseBackup.directory_exists?
    assert_not DatabaseBackup.directory_writable?
  end

  test "listing and writability checks do not create the directory either" do
    Setting.backup_subdirectory = "also-not-created"
    target = DatabaseBackup.directory

    DatabaseBackup.all
    DatabaseBackup.directory_writable?
    DatabaseBackup.directory_persistent?

    assert_not target.exist?
  end

  # Only the subfolder is user input, so no value can escape the mount.
  test "a folder value cannot escape the mount" do
    [ "/etc", "../../etc/passwd", "a/../../b", "./x" ].each do |input|
      Setting.backup_subdirectory = input

      assert DatabaseBackup.directory.to_s.start_with?(@dir),
        "#{input.inspect} resolved outside the mount: #{DatabaseBackup.directory}"
    end
  end

  # The page must show where dumps land on the host, which the container can only
  # know because compose passes BACKUP_HOST_ROOT through.
  test "reports the host path for the chosen folder" do
    DatabaseBackup.stubs(:mounted?).returns(true)
    Setting.backup_subdirectory = "nightly"

    with_env_overrides("BACKUP_HOST_ROOT" => "/Users/me/iCloud") do
      assert_equal "/Users/me/iCloud/nightly", DatabaseBackup.host_directory
    end
  end

  test "host path is nil when compose did not pass the root through" do
    DatabaseBackup.stubs(:mounted?).returns(true)

    with_env_overrides("BACKUP_HOST_ROOT" => "") do
      assert_nil DatabaseBackup.host_directory
    end
  end

  # Without a real mount the host path would be a fiction.
  test "host path is nil when nothing is mounted" do
    DatabaseBackup.stubs(:mounted?).returns(false)

    with_env_overrides("BACKUP_HOST_ROOT" => "/Users/me/iCloud") do
      assert_nil DatabaseBackup.host_directory
    end
  end

  test "writes into the chosen subfolder" do
    Setting.backup_subdirectory = "archive/db"
    FileUtils.mkdir_p(File.join(@dir, "archive", "db"))

    backup = DatabaseBackup.create!

    assert_equal File.join(@dir, "archive", "db"), backup.path.dirname.to_s
    assert_equal [ backup.filename ], DatabaseBackup.all.map(&:filename)
  end

  # A writable directory inside the container's own layer is destroyed by
  # `docker compose up -d`, so the settings page has to be able to spot it.
  test "detects a directory that does not survive a container rebuild" do
    skip "only meaningful inside a container" unless DatabaseBackup.containerised?

    DatabaseBackup.unstub(:mount_root)
    DatabaseBackup.stubs(:mount_root).returns(Pathname.new("/tmp"))
    Setting.backup_subdirectory = "backup-persistence-check"
    FileUtils.mkdir_p("/tmp/backup-persistence-check")

    assert DatabaseBackup.directory_writable?, "expected /tmp to be writable"
    assert_not DatabaseBackup.directory_persistent?, "/tmp shares a device with / and is ephemeral"
  ensure
    FileUtils.remove_entry("/tmp/backup-persistence-check", true)
  end

  test "treats a mounted directory as persistent" do
    skip "only meaningful inside a container" unless DatabaseBackup.containerised?

    DatabaseBackup.unstub(:mount_root)
    DatabaseBackup.stubs(:mount_root).returns(Pathname.new("/rails/storage"))
    Setting.backup_subdirectory = "backups"

    assert DatabaseBackup.directory_persistent?
    assert_includes DatabaseBackup.persistent_directory_hints, "/rails/storage/backups"
  end

  test "reports an unwritable directory rather than raising" do
    DatabaseBackup.unstub(:mount_root)
    DatabaseBackup.stubs(:mount_root).returns(Pathname.new("/proc/nope"))
    Setting.backup_subdirectory = "backups"

    assert_not DatabaseBackup.directory_writable?
  end

  # The password must not be visible to a process listing.
  test "the password is passed via the environment, not argv" do
    command = DatabaseBackup.send(:dump_command, Pathname.new("/tmp/x.dump"))
    env = DatabaseBackup.send(:dump_env)
    password = ActiveRecord::Base.connection_db_config.configuration_hash[:password]

    assert_kind_of Array, command, "pg_dump must be invoked with an argv array, never a shell string"
    if password.present?
      assert_equal password.to_s, env["PGPASSWORD"]
      assert command.none? { |arg| arg.to_s.include?(password.to_s) }, "password leaked into argv"
    end
  end

  # database.yml spells it `user:`, which never reaches configuration_hash[:username].
  test "resolves the username from either config spelling" do
    assert_equal ActiveRecord::Base.connection.select_value("SELECT current_user"),
                 DatabaseBackup.send(:db_username)
  end
end
