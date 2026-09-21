require "test_helper"

class IbkrImport::CacheTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir)
    @cache = IbkrImport::Cache.new(root: @root)
  end

  teardown { FileUtils.remove_entry(@root) }

  test "writes a miss verbatim and replays it without calling again" do
    calls = 0
    fetch = -> { @cache.fetch("k") { calls += 1; "<FlexQueryResponse/>" } }

    assert_equal "<FlexQueryResponse/>", fetch.call
    assert_equal "<FlexQueryResponse/>", fetch.call
    assert_equal 1, calls
    assert_predicate @root.join("k.xml"), :exist?
  end

  test "refresh ignores what is cached" do
    @cache.fetch("k") { "old" }

    assert_equal "new", IbkrImport::Cache.new(root: @root, refresh: true).fetch("k") { "new" }
  end

  test "offline mode refuses to fetch but still replays a cached response" do
    offline = IbkrImport::Cache.new(root: @root, offline: true)

    assert_raises(IbkrImport::Error) { offline.fetch("k") { flunk "must not fetch" } }

    @cache.fetch("k") { "cached" }
    assert_equal "cached", offline.fetch("k") { flunk "must not fetch" }
  end
end
