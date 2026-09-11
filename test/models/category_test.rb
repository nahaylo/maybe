require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "replacing and destroying" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(categories(:income))

    assert_equal categories(:income), transactions.map { |t| t.reload.category }.uniq.first
  end

  test "replacing with nil should nullify the category" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(nil)

    assert_nil transactions.map { |t| t.reload.category }.uniq.first
  end

  test "subcategory can only be one level deep" do
    category = categories(:subcategory)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      category.subcategories.create!(name: "Invalid category", family: @family)
    end

    assert_equal "Validation failed: Parent can't have more than 2 levels of subcategories", error.message
  end
  test "Group.for nests subcategories under their parent" do
    groups = Category::Group.for([ categories(:income), categories(:food_and_drink), categories(:subcategory) ])

    assert_equal [ categories(:income), categories(:food_and_drink) ], groups.map(&:category)
    assert_empty groups.first.subcategories
    assert_equal [ categories(:subcategory) ], groups.second.subcategories
  end

  test "Group.for keeps a subcategory whose parent is missing from the list" do
    groups = Category::Group.for([ categories(:subcategory) ])

    assert_equal [ categories(:subcategory) ], groups.map(&:category)
    assert_empty groups.first.subcategories
  end

  test "Group.for treats an unsaved category as its own group" do
    groups = Category::Group.for([ Category.uncategorized, categories(:food_and_drink), categories(:subcategory) ])

    assert_equal [ "Uncategorized", "Food & Drink" ], groups.map(&:name)
  end
end
