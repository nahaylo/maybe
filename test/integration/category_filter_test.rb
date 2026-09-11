require "test_helper"

class CategoryFilterTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    get transactions_url
    assert_response :success
    @doc = Nokogiri::HTML(response.body)
  end

  test "subcategories are grouped under their parent" do
    group = @doc.at_css("[data-filter-group][data-controller='checkbox-group']")
    assert group, "parent category is not rendered as a group"

    parent = group.at_css("[data-checkbox-group-target='parent']")
    children = group.css("[data-checkbox-group-target='child']")

    assert_equal "Food & Drink", parent["value"]
    assert_equal [ "Restaurants" ], children.map { |child| child["value"] }
  end

  test "subcategory rows carry the same marker as the budget and category lists" do
    group = @doc.at_css("[data-filter-group][data-controller='checkbox-group']")
    child_row = group.at_css("[data-checkbox-group-target='child']").ancestors(".filterable-item").first
    parent_row = group.at_css("[data-checkbox-group-target='parent']").ancestors(".filterable-item").first

    # lucide_icon renders no class naming the icon, so the marker is identified
    # by being the row's only icon in the default (grey) colour -- the category
    # badge's own icon is text-current.
    assert child_row.at_css("svg.fg-gray"), "subcategory row is missing the corner-down-right marker"
    assert_nil parent_row.at_css("svg.fg-gray"), "parent row should not carry the marker"
  end

  test "ticking the parent ticks the whole group" do
    parent = @doc.at_css("[data-checkbox-group-target='parent']")

    assert_equal "change->checkbox-group#toggleAll", parent["data-action"]
  end

  # A Stimulus controller added since the last image build silently drops out of
  # the importmap, leaving the group toggle inert with no error.
  test "the checkbox group controller is present in the importmap" do
    assert_match "controllers/checkbox_group_controller", response.body,
      "checkbox_group_controller is missing from the importmap; rebuild assets"
  end

  # Filtering hides individual rows, so a group whose rows all disappear has to
  # go with them rather than stay behind as an empty container.
  test "group containers are filterable as a unit" do
    group = @doc.at_css("[data-filter-group][data-controller='checkbox-group']")

    assert group.css(".filterable-item").any?, "group has no filterable rows"
    assert_equal "Food & Drink Restaurants",
      group.at_css("[data-checkbox-group-target='child']").ancestors(".filterable-item").first["data-filter-name"]
  end
  test "an applied category filter shows the category's icon in its chip" do
    get transactions_url(q: { categories: [ "Restaurants" ] })
    assert_response :success

    chip = chip_for("Restaurants")
    assert chip, "no filter chip rendered for the applied category"
    # Two icons: the category's own, plus the chip's clear button.
    assert_equal 2, chip.css("svg").size, "chip is missing the category icon"
    assert_includes chip.at_css("span")["style"], categories(:subcategory).color
  end

  test "an unresolvable category name still gets a chip" do
    get transactions_url(q: { categories: [ "Deleted category" ] })
    assert_response :success

    chip = chip_for("Deleted category")
    assert chip, "a category no longer on file should still be clearable"
    assert_equal 1, chip.css("svg").size, "only the clear button should be rendered"
  end

  private
    def chip_for(name)
      Nokogiri::HTML(response.body)
        .css("#transaction-search-filters li")
        .find { |chip| chip.text.include?(name) }
    end
end
