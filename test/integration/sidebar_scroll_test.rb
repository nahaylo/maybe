require "test_helper"

class SidebarScrollTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  # Clicking an account is a full Turbo Drive visit that rebuilds the sidebar, so
  # the scroll offset has to be saved and restored. preserve-scroll keys off the
  # element id, so a missing id silently disables it.
  test "the account sidebar scroller is wired for scroll preservation" do
    get account_path(accounts(:depository))
    assert_response :success

    doc = Nokogiri::HTML(response.body)

    scroller = doc.at_css("#account-sidebar-scroll")
    assert scroller, "desktop sidebar scroller is missing its stable id"
    assert_includes scroller["data-controller"].to_s, "preserve-scroll"
    assert_includes scroller["class"], "overflow-y-auto",
      "preserve-scroll must sit on the element that actually scrolls"

    mobile = doc.at_css("#mobile-account-sidebar-scroll")
    assert mobile, "mobile sidebar scroller is missing its stable id"
    assert_includes mobile["data-controller"].to_s, "preserve-scroll"
  end

  test "sidebar scroller ids are unique on the page" do
    get account_path(accounts(:depository))
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    %w[account-sidebar-scroll mobile-account-sidebar-scroll].each do |id|
      assert_equal 1, doc.css("##{id}").size, "#{id} must appear exactly once"
    end
  end

  # The sidebar must keep re-rendering: data-turbo-permanent would preserve the
  # scroll offset for free but freeze the active-account highlight.
  test "the active account is highlighted server-side" do
    account = accounts(:depository)
    get account_path(account)
    assert_response :success

    scroller = Nokogiri::HTML(response.body).at_css("#account-sidebar-scroll")
    assert_nil scroller["data-turbo-permanent"],
      "a permanent sidebar would stop the active-account highlight updating"

    assert_match account.name, scroller.to_html
  end

  # Propshaft resolves from the manifest baked at image build time, so a JS change
  # that is not rebuilt drops out of the importmap and the controller never runs.
  test "the preserve-scroll controller is present in the importmap" do
    get account_path(accounts(:depository))
    assert_response :success

    assert_match "controllers/preserve_scroll_controller", response.body,
      "preserve_scroll_controller is missing from the importmap; rebuild assets"
  end
end
