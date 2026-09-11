require "test_helper"

class Settings::BackupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @previous_subdirectory = Setting.backup_subdirectory
    @dir = Dir.mktmpdir("backup-controller-test")
    DatabaseBackup.stubs(:mount_root).returns(Pathname.new(@dir))
    @folder = "backups"
    @backup_dir = File.join(@dir, @folder)
    FileUtils.mkdir_p(@backup_dir)
    Setting.backup_subdirectory = @folder
  end

  teardown do
    Setting.backup_subdirectory = @previous_subdirectory
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  test "shows the page with the configured path and existing backups" do
    write_backup("maybe_test-20260101-000000.dump")

    with_self_hosting do
      get settings_backup_path
      assert_response :success
      assert_match @dir, response.body
      assert_match "maybe_test-20260101-000000.dump", response.body
    end
  end

  # The suite runs with SELF_HOSTED=true, so managed mode has to be forced.
  test "hidden unless self hosted" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    get settings_backup_path
    assert_response :forbidden
  end

  test "non-admins cannot reach it" do
    sign_in users(:family_member)

    with_self_hosting do
      get settings_backup_path
      assert_redirected_to settings_hosting_path
    end
  end

  test "create enqueues the dump off the request cycle" do
    with_self_hosting do
      assert_enqueued_with(job: DatabaseBackupJob) do
        post settings_backup_path
      end
      assert_redirected_to settings_backup_path
    end
  end

  test "update rejects a blank folder, keeping the previous one" do
    with_self_hosting do
      [ "", "   ", "/", "..", "./" ].each do |bad|
        patch settings_backup_path, params: { setting: { backup_subdirectory: bad } }

        assert_redirected_to settings_backup_path
        assert_equal @folder, Setting.backup_subdirectory, "#{bad.inspect} should have been rejected"
      end
    end
  end

  test "update changes the configured folder" do
    with_self_hosting do
      patch settings_backup_path, params: { setting: { backup_subdirectory: "nightly" } }
      assert_redirected_to settings_backup_path
    end

    assert_equal "nightly", Setting.backup_subdirectory
  end

  test "downloads a backup" do
    write_backup("maybe_test-20260101-000000.dump", "PGDMP-content")

    with_self_hosting do
      get download_settings_backup_path(filename: "maybe_test-20260101-000000.dump")
      assert_response :success
      assert_equal "PGDMP-content", response.body
    end
  end

  test "downloads a leftover .sql.gz backup from the short-lived gzip format" do
    write_backup("maybe_test-20250101-000000.sql.gz", "gz-leftover")

    with_self_hosting do
      get settings_backup_path
      assert_match "maybe_test-20250101-000000.sql.gz", response.body

      get download_settings_backup_path(filename: "maybe_test-20250101-000000.sql.gz")
      assert_response :success
      assert_equal "gz-leftover", response.body
    end
  end

  test "deletes a backup" do
    path = write_backup("maybe_test-20260101-000000.dump")

    with_self_hosting do
      delete file_settings_backup_path(filename: "maybe_test-20260101-000000.dump")
      assert_redirected_to settings_backup_path
    end

    assert_not File.exist?(path)
  end

  # The route constraint should stop a traversal attempt before the controller,
  # and DatabaseBackup.find rejects it again if it ever gets through.
  test "traversal and non-matching filenames never serve a file" do
    File.write(File.join(@backup_dir, "notes.txt"), "secret")

    with_self_hosting do
      [
        "/settings/backup/download/..%2F..%2F..%2Fetc%2Fpasswd",
        "/settings/backup/download/notes.txt",
        "/settings/backup/download/%2Fetc%2Fpasswd"
      ].each do |path|
        begin
          get path
        rescue ActionController::RoutingError
          next # the route constraint rejected it outright, which is the ideal case
        end

        assert_not_equal 200, response.status, "#{path} should not have served a file"
        assert_not_equal "application/octet-stream", response.media_type,
          "#{path} should not have been served as a download"
        assert_no_match "secret", response.body, "#{path} leaked file contents"
      end
    end
  end

  test "downloading a non-existent backup is handled, not a 500" do
    with_self_hosting do
      get download_settings_backup_path(filename: "maybe_test-20990101-000000.dump")
      assert_redirected_to settings_backup_path
    end
  end

  private
    def write_backup(name, content = "x")
      File.join(@backup_dir, name).tap { |path| File.write(path, content) }
    end
end
