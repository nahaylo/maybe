require "test_helper"

class AccountsReorderTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "reorder persists the submitted order" do
    ids = @family.accounts.ordered.pluck(:id)

    patch reorder_accounts_path, params: { account_ids: ids.reverse }

    assert_response :no_content
    assert_equal ids.reverse, @family.accounts.ordered.pluck(:id)
  end

  test "reorder tolerates a missing account_ids param" do
    patch reorder_accounts_path

    assert_response :no_content
  end

  test "reorder cannot touch another family's accounts" do
    other = families(:empty).accounts.create!(
      name: "Not Mine",
      balance: 1,
      currency: "USD",
      accountable: Depository.new
    )

    patch reorder_accounts_path, params: { account_ids: [ other.id ] }

    assert_response :no_content
    assert_equal 1, other.reload.position
  end

  test "reorder requires authentication" do
    reset!
    patch reorder_accounts_path, params: { account_ids: [] }

    assert_redirected_to new_session_path
  end

  test "accounts index renders drag handles wired to the reorder endpoint" do
    get accounts_path
    assert_response :success

    doc = Nokogiri::HTML(response.body)

    wrapper = doc.at_css('[data-controller="sortable"]')
    assert wrapper, "expected a sortable wrapper on the accounts page"
    assert_equal reorder_accounts_path, wrapper["data-sortable-url-value"]

    assert doc.css('[data-sortable-target="list"]').any?, "expected at least one drop zone"

    items = doc.css('[data-sortable-target="item"]')
    assert items.any?, "expected sortable rows"
    items.each do |item|
      assert item["data-sortable-id"].present?, "row is missing its record id"
    end

    handles = doc.css('[data-action*="sortable#grabHandle"]')
    assert_equal items.size, handles.size, "every sortable row needs a drag handle"

    # Browsers decide draggability before mousedown handlers run, so this must
    # come from the server rather than being flipped on in JS.
    items.each do |item|
      assert_equal "true", item["draggable"], "row must be draggable server-side"
    end
  end

  # Propshaft resolves from the manifest baked at image build time, and
  # public/assets is not bind-mounted -- so a new controller file silently drops
  # out of the importmap until the image is rebuilt, and nothing drags.
  test "the sortable controller is present in the importmap" do
    get accounts_path
    assert_response :success

    assert_match "controllers/sortable_controller", response.body,
      "sortable_controller is missing from the importmap; rebuild assets"
  end

  # Interleaved <hr> siblings would be stranded between the wrong rows once a row
  # moves, so the list uses CSS dividers instead.
  test "account rows are separated by CSS dividers, not sibling rulers" do
    get accounts_path
    assert_response :success

    list = Nokogiri::HTML(response.body).at_css('[data-sortable-target="list"]')
    assert_includes list["class"], "divide-y"
    assert_empty list.css("> hr"), "sortable list must not contain sibling rulers"
  end
end
