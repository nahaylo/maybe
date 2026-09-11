require "open3"

# A pg_dump of the whole database, written to a configurable directory.
#
# PostgreSQL custom format, restored with `pg_restore`. The format compresses
# internally with gzip already, so there is nothing to gain from a .gz wrapper.
#
# Self-hosted only. The directory is admin-configurable (Setting.backup_path),
# which is inherently privileged, so everything that touches the filesystem is
# constrained here rather than in the controller:
#
#   - filenames are generated, never taken from input, and must match FILENAME
#   - a looked-up path is resolved and re-checked to be inside the directory,
#     so "../../etc/passwd" cannot escape
#   - pg_dump is invoked with an argv array and never a shell string, so no
#     part of the connection config can be interpreted as a command
class DatabaseBackup
  class Error < StandardError; end

  # Fixed at container-creation time by compose (BACKUP_HOST_ROOT). A container
  # cannot change its own mounts, so this is the one part not settable in-app.
  MOUNT_ROOT = "/rails/backups".freeze

  EXTENSION = ".dump".freeze

  # Recognised but no longer produced, so any backup left over from the
  # short-lived gzip format stays listable, downloadable and deletable.
  LEGACY_EXTENSION = ".sql.gz".freeze

  FILENAME = /\A[a-z0-9_]+-\d{8}-\d{6}(\.sql\.gz|\.dump)\z/

  # A dump still being written carries this suffix so a crashed or half-finished
  # run is never listed or restored as if it were complete.
  PARTIAL_SUFFIX = ".part".freeze

  attr_reader :path

  class << self
    def mount_root
      Pathname.new(File.directory?(MOUNT_ROOT) ? MOUNT_ROOT : Rails.root.join("storage", "backups").to_s)
    end

    # Where dumps are written: a subfolder of the mount, chosen in the settings
    # page. Only the subfolder is user-controlled, so the mount cannot be escaped.
    def directory
      subdirectory.present? ? mount_root.join(subdirectory) : mount_root
    end

    # Sanitised subfolder. Leading slashes and any ".." segment are dropped, so a
    # value like "../../etc" can only ever resolve inside the mount.
    def subdirectory
      sanitize_subdirectory(Setting.backup_subdirectory.to_s.strip)
    end

    def default_directory
      MOUNT_ROOT
    end

    # Sanitised form of an incoming value, so the controller can reject anything
    # that would resolve to the mount root itself.
    def sanitize_subdirectory(value)
      value.to_s.split("/").reject { |part| part.blank? || part == "." || part == ".." }.join("/")
    end

    # The path on the host that `directory` corresponds to, for display only.
    # A container cannot introspect the host side of its bind mount, so this
    # relies on compose passing BACKUP_HOST_ROOT through. Nil when unknown.
    def host_directory
      root = ENV["BACKUP_HOST_ROOT"].to_s.strip
      return nil if root.blank? || !mounted?

      subdirectory.present? ? File.join(root, subdirectory) : root
    end

    def all
      return [] if subdirectory.blank?
      return [] unless directory.directory?

      [ EXTENSION, LEGACY_EXTENSION ]
        .flat_map { |extension| directory.glob("*#{extension}") }
        .select { |path| path.basename.to_s.match?(FILENAME) }
        .sort_by { |path| [ path.mtime, path.basename.to_s ] } # mtime, not the name: see the UTC note on create!
        .reverse
        .map { |path| new(path) }
    end

    def find(filename)
      raise Error, "Invalid backup name" unless filename.to_s.match?(FILENAME)

      # Re-resolve and re-check: expand_path collapses any traversal, and the
      # result must still sit directly inside the backup directory.
      path = directory.join(filename).expand_path
      raise Error, "Backup not found" unless path.dirname == directory.expand_path && path.file?

      new(path)
    end

    def create!
      ensure_directory!

      # Explicitly UTC. Time.current follows Time.zone, which this app sets per
      # request from the family's timezone -- and a Sidekiq thread can inherit a
      # leaked zone, so Time.current here is not reliably UTC. Mixed-zone stamps
      # would make filenames sort out of order.
      target = directory.join("#{database_name}-#{Time.current.utc.strftime('%Y%m%d-%H%M%S')}#{EXTENSION}")
      partial = Pathname.new("#{target}#{PARTIAL_SUFFIX}")

      _out, err, status = Open3.capture3(dump_env, *dump_command(partial))

      unless status.success?
        partial.delete if partial.exist?
        raise Error, "pg_dump failed: #{err.lines.first&.strip || "exit #{status.exitstatus}"}"
      end

      FileUtils.mv(partial, target)
      new(target)
    end

    # Deliberately does NOT create anything. Backups land in a folder the
    # operator has shared from the host; silently creating it would just make a
    # directory inside the container that looks right and disappears on rebuild.
    def ensure_directory!
      raise Error, "Backup folder is not set" if subdirectory.blank?
      raise Error, "#{directory} does not exist. Create it before taking a backup." unless directory.directory?
      raise Error, "Cannot write to #{directory}" unless File.writable?(directory)
    end

    def directory_exists?
      subdirectory.present? && directory.directory?
    end

    # Reports whether the configured directory is usable, for the settings form.
    def directory_writable?
      directory_exists? && File.writable?(directory)
    rescue SystemCallError
      false
    end

    # Whether the directory survives the container being rebuilt.
    #
    # A bind mount or named volume is a different filesystem from the container's
    # own layer, so comparing device ids tells them apart. Anything sharing a
    # device with "/" lives in the ephemeral layer and is destroyed by
    # `docker compose up -d`, silently taking every backup with it.
    #
    # Outside a container there is nothing to lose, so this is only meaningful
    # when the app is containerised.
    def directory_persistent?
      return true unless containerised?
      return false unless directory.exist?

      File.stat(directory.to_s).dev != File.stat("/").dev
    rescue SystemCallError
      false
    end

    # Directories the app can currently write to that do survive a rebuild,
    # offered as a hint when the chosen one does not.
    def persistent_directory_hints
      return [] unless containerised?

      root_dev = File.stat("/").dev
      [ MOUNT_ROOT, Rails.root.join("storage", "backups").to_s, "/rails/storage" ]
        .uniq
        .select { |candidate| File.directory?(candidate) && File.stat(candidate).dev != root_dev }
    rescue SystemCallError
      []
    end

    # True when the mount is actually wired up, so the settings page can say so
    # rather than silently writing into the container.
    def mounted?
      File.directory?(MOUNT_ROOT) && (!containerised? || File.stat(MOUNT_ROOT).dev != File.stat("/").dev)
    rescue SystemCallError
      false
    end

    def containerised?
      File.exist?("/.dockerenv")
    end

    def database_name
      db_config[:database].to_s.gsub(/[^a-z0-9_]/i, "_")
    end

    private
      def db_config
        ActiveRecord::Base.connection_db_config.configuration_hash
      end

      # config/database.yml uses the libpq spelling `user:`. The adapter accepts
      # it, but it never lands in configuration_hash[:username] -- without this
      # pg_dump would fall back to the OS user and fail to authenticate.
      def db_username
        db_config[:username].presence || db_config[:user].presence
      end

      # argv array, never a shell string.
      def dump_command(target)
        command = [ "pg_dump", "--format=custom", "--no-owner", "--no-acl", "--file=#{target}" ]
        command << "--host=#{db_config[:host]}" if db_config[:host].present?
        command << "--port=#{db_config[:port]}" if db_config[:port].present?
        command << "--username=#{db_username}" if db_username.present?
        command << db_config[:database].to_s
        command
      end

      # The password goes in the environment so it never appears in argv, where
      # it would be visible to any process listing.
      def dump_env
        db_config[:password].present? ? { "PGPASSWORD" => db_config[:password].to_s } : {}
      end
  end

  def initialize(path)
    @path = Pathname.new(path)
  end

  def filename
    path.basename.to_s
  end

  def size
    path.size
  end

  def created_at
    path.mtime
  end

  def delete!
    path.delete
  end

  def ==(other)
    other.is_a?(self.class) && other.path == path
  end
end
