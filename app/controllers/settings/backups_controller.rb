class Settings::BackupsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin

  def show
    @backups = DatabaseBackup.all
  end

  def create
    DatabaseBackupJob.perform_later

    redirect_to settings_backup_path, notice: t(".started")
  end

  # Sends the whole database to the browser, so it stays admin-only and the
  # filename is validated back to a path inside the backup directory.
  def download
    backup = DatabaseBackup.find(params[:filename])

    send_file backup.path, filename: backup.filename, type: "application/octet-stream"
  rescue DatabaseBackup::Error => e
    redirect_to settings_backup_path, alert: e.message
  end

  def destroy
    DatabaseBackup.find(params[:filename]).delete!

    redirect_to settings_backup_path, notice: t(".deleted")
  rescue DatabaseBackup::Error => e
    redirect_to settings_backup_path, alert: e.message
  end

  def update
    folder = DatabaseBackup.sanitize_subdirectory(backup_params[:backup_subdirectory])

    # Blank would resolve to the mount root itself, which is shared with
    # unrelated files, so backups always live in a folder of their own.
    return redirect_to settings_backup_path, alert: t(".blank_folder") if folder.blank?

    Setting.backup_subdirectory = folder

    redirect_to settings_backup_path, notice: t(".updated")
  rescue ActiveRecord::RecordInvalid, DatabaseBackup::Error => e
    redirect_to settings_backup_path, alert: e.message
  end

  private
    def backup_params
      params.require(:setting).permit(:backup_subdirectory)
    end

    def ensure_admin
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.admin?
    end
end
