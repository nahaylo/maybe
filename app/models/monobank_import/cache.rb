# On-disk cache for raw Monobank API responses.
#
# Monobank allows ONE request per 60 seconds per token, so a dry run followed by
# a real run must not cost two calls. Every response is written verbatim and
# replayed from disk on the next ask.
#
# It lives under storage/ rather than tmp/ because storage/ is a named Docker
# volume that survives `docker compose up -d`, while tmp/ is not mounted at all
# and would be lost whenever the container is recreated.
class MonobankImport::Cache
  ROOT = Rails.root.join("storage/monobank")

  attr_reader :root

  # @param refresh [Boolean] ignore anything already cached and re-fetch
  # @param offline [Boolean] never call the API; a cache miss is an error.
  #   This is what lets the importer be exercised end to end against a fixture.
  def initialize(root: ROOT, refresh: false, offline: false)
    @root = Pathname.new(root)
    @refresh = refresh
    @offline = offline
  end

  def refresh? = @refresh
  def offline? = @offline

  # Returns the cached payload for `key`, calling the block on a miss.
  def fetch(key)
    file = path_for(key)

    if file.exist? && !refresh?
      return JSON.parse(file.read)
    end

    if offline?
      raise MonobankImport::Error,
            "offline mode: nothing cached at #{file}. Run once without OFFLINE=1, " \
            "or seed the file from a fixture."
    end

    payload = yield
    write(file, payload)
    payload
  end

  # Reads what is on disk and never fetches, ignoring `refresh` entirely.
  # For callers that want cached data if it happens to be there but must not
  # spend one of the token's once-a-minute requests to get it.
  def read(key)
    file = path_for(key)
    return nil unless file.exist?

    JSON.parse(file.read)
  end

  def path_for(key)
    root.join("#{key}.json")
  end

  def cached?(key)
    path_for(key).exist?
  end

  private
    def write(file, payload)
      file.dirname.mkpath
      file.write(JSON.pretty_generate(payload))
      file
    end
end
