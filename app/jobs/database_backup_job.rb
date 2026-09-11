class DatabaseBackupJob < ApplicationJob
  queue_as :low_priority

  # pg_dump can take a while on a large database, so backups are always created
  # off the request cycle. Failures are logged rather than retried: a retry would
  # just write a second dump under a new timestamp.
  def perform
    backup = DatabaseBackup.create!
    Rails.logger.info("Database backup written to #{backup.path} (#{backup.size} bytes)")
    backup
  rescue DatabaseBackup::Error => e
    Rails.logger.error("Database backup failed: #{e.message}")
    raise
  end
end
