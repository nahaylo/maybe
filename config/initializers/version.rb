module Maybe
  class << self
    def version
      Semver.new(semver)
    end

    # Memoized: the user menu asks for this several times per render, and the
    # fallback below forks a subprocess.
    def commit_sha
      return @commit_sha if defined?(@commit_sha)

      @commit_sha = ENV["BUILD_COMMIT_SHA"].presence || git_commit_sha
    end

    private
      # Best-effort only. Production images are built with BUILD_COMMIT_SHA, and
      # the slim runtime image ships no git binary and no .git directory, so a
      # missing or failing git must degrade to nil rather than raise -- this is
      # called while rendering the app layout, so an exception here takes down
      # every page.
      def git_commit_sha
        return nil if Rails.env.production?

        `git rev-parse HEAD 2>/dev/null`.chomp.presence
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      # Bump together with the top entry of docs/CHANGELOG.md; ChangelogTest
      # checks they agree.
      def semver
        "0.7.0"
      end
  end
end
