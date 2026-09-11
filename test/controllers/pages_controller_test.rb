require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "dashboard" do
    get root_path
    assert_response :ok
  end

  test "changelog renders the releases from CHANGELOG.md" do
    Changelog.stubs(:releases).returns([
      Changelog::Release.new(title_html: "[1.0.0] - 2026-09-01", version: "1.0.0", date: Date.new(2026, 9, 1),
                             body_html: "<h3>Added</h3><ul><li>A feature</li></ul>")
    ])

    get changelog_path

    assert_response :ok
    assert_select "h2", text: "[1.0.0] - 2026-09-01"
    assert_select "li", text: "A feature"
    assert_select "div", text: "September 01, 2026"
  end

  test "changelog without a file says so instead of failing" do
    Changelog.stubs(:releases).returns([])

    get changelog_path

    assert_response :ok
    assert_select "p", text: "No changelog is available for this build."
  end
end
