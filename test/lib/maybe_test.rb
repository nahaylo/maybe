require "test_helper"

class MaybeTest < ActiveSupport::TestCase
  setup { reset_commit_sha_cache }
  teardown { reset_commit_sha_cache }

  test "commit_sha prefers BUILD_COMMIT_SHA over shelling out to git" do
    Maybe.expects(:git_commit_sha).never

    with_env("BUILD_COMMIT_SHA" => "abc123") do
      assert_equal "abc123", Maybe.commit_sha
    end
  end

  test "commit_sha falls back to git when BUILD_COMMIT_SHA is blank" do
    Maybe.stubs(:git_commit_sha).returns("def456")

    with_env("BUILD_COMMIT_SHA" => "") do
      assert_equal "def456", Maybe.commit_sha
    end
  end

  # The slim runtime image ships no git binary. This is called while rendering
  # the app layout, so raising here breaks every page instead of one line of it.
  test "commit_sha returns nil when the git binary is unavailable" do
    Maybe.stubs(:`).raises(Errno::ENOENT.new("git"))

    with_env("BUILD_COMMIT_SHA" => nil) do
      assert_nil Maybe.commit_sha
    end
  end

  test "commit_sha returns nil when git produces no output" do
    Maybe.stubs(:`).returns("\n")

    with_env("BUILD_COMMIT_SHA" => nil) do
      assert_nil Maybe.commit_sha
    end
  end

  test "commit_sha is memoized so views do not fork per render" do
    Maybe.expects(:git_commit_sha).once.returns("cafe123")

    with_env("BUILD_COMMIT_SHA" => nil) do
      3.times { assert_equal "cafe123", Maybe.commit_sha }
    end
  end

  private
    def reset_commit_sha_cache
      Maybe.remove_instance_variable(:@commit_sha) if Maybe.instance_variable_defined?(:@commit_sha)
    end

    def with_env(vars)
      original = vars.keys.index_with { |key| ENV[key] }
      vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
