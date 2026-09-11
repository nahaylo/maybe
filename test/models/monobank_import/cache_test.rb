require "test_helper"

class MonobankImport::CacheTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir)
    @cache = MonobankImport::Cache.new(root: @root)
  end

  teardown { FileUtils.remove_entry(@root) }

  test "writes a miss and replays it without calling again" do
    calls = 0
    fetch = -> { @cache.fetch("k") { calls += 1; [ { "id" => "x" } ] } }

    assert_equal [ { "id" => "x" } ], fetch.call
    assert_equal [ { "id" => "x" } ], fetch.call
    assert_equal 1, calls, "the second fetch must be served from disk -- the rate limit is a full minute"
  end

  test "refresh ignores what is cached" do
    @cache.fetch("k") { [ "old" ] }

    assert_equal [ "new" ], MonobankImport::Cache.new(root: @root, refresh: true).fetch("k") { [ "new" ] }
  end

  test "offline mode refuses to fetch" do
    cache = MonobankImport::Cache.new(root: @root, offline: true)

    assert_raises(MonobankImport::Error) { cache.fetch("k") { flunk "must not fetch" } }
  end

  test "offline mode still replays a cached response" do
    @cache.fetch("k") { [ "cached" ] }
    cache = MonobankImport::Cache.new(root: @root, offline: true)

    assert_equal [ "cached" ], cache.fetch("k") { flunk "must not fetch" }
  end
end
