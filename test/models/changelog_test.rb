require "test_helper"

class ChangelogTest < ActiveSupport::TestCase
  setup do
    @path = Rails.root.join("tmp/changelog_test_#{SecureRandom.hex(4)}.md")
  end

  teardown { FileUtils.rm_f(@path) }

  test "splits the file into releases with version, date and rendered body" do
    File.write(@path, <<~MD)
      # Changelog

      Preamble that is not a release.

      ## [1.2.0] - 2026-09-01

      ### Added
      - A thing that
        wraps onto a second line.

      ## [Unreleased] — `beta` (2026-08-01 … 2026-09-11)

      Text.
    MD

    releases = Changelog.releases(path: @path)

    assert_equal [ "1.2.0", "Unreleased" ], releases.map(&:version)
    assert_equal "[Unreleased] — <code>beta</code> (2026-08-01 … 2026-09-11)", releases.last.title_html
    assert_equal [ Date.new(2026, 9, 1), Date.new(2026, 9, 11) ], releases.map(&:date)
    assert_includes releases.first.body_html, "<h3>Added</h3>"
    assert_includes releases.first.body_html, "<li>A thing that\nwraps onto a second line.</li>"
    assert_not_includes releases.first.body_html, "Preamble"
  end

  test "is empty when the file is missing" do
    assert_empty Changelog.releases(path: @path)
  end

  # The version string in config/initializers/version.rb and the top entry of
  # docs/CHANGELOG.md are edited by hand; this is what keeps them from drifting.
  test "the newest shipped release is the app version" do
    assert_equal Maybe.version.to_s, Changelog.releases.first.version
  end
end
