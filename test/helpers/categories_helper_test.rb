require "test_helper"

class CategoriesHelperTest < ActionView::TestCase
  setup do
    @parent = categories(:food_and_drink)
    @child = categories(:subcategory)
    @childless = categories(:income)
    @groups = Category::Group.for([ @childless, @parent, @child ])
  end

  test "finds the group a parent belongs to" do
    assert_equal @parent, category_group_for(@groups, @parent.id).category
  end

  test "finds the group a subcategory belongs to" do
    assert_equal @parent, category_group_for(@groups, @child.id).category
  end

  test "no group when nothing is selected" do
    assert_nil category_group_for(@groups, nil)
  end

  test "the first select offers only categories, never subcategories" do
    options = parse(category_parent_options(@groups, selected: nil, blank_label: "Pick one"))

    assert_equal [ "Pick one", @childless.name, @parent.name ], options.css("option").map(&:text)
  end

  test "the first select preselects the group of the current value" do
    options = parse(category_parent_options(@groups, selected: category_group_for(@groups, @child.id), blank_label: "Pick one"))

    assert_equal [ @parent.id ], options.css("option[selected]").map { |option| option["value"] }
  end

  # The whole point of the split: a parent stays assignable, so "None" submits
  # the parent's own id rather than a blank.
  test "None carries the parent's own id" do
    options = parse(category_subcategory_options(category_group_for(@groups, @parent.id), selected: @parent.id))
    none = options.css("option").first

    assert_equal "None", none.text
    assert_equal @parent.id, none["value"]
    assert none["selected"]
  end

  test "the second select marks the current subcategory" do
    options = parse(category_subcategory_options(category_group_for(@groups, @child.id), selected: @child.id))

    assert_equal [ "None", @child.name ], options.css("option").map(&:text)
    assert_equal [ @child.id ], options.css("option[selected]").map { |option| option["value"] }
  end

  test "the second select is empty until a category is chosen" do
    options = parse(category_subcategory_options(nil, selected: nil))

    assert_equal [ "None" ], options.css("option").map(&:text)
    assert_equal "", options.css("option").first["value"]
  end

  test "the swap map leaves out categories with no subcategories" do
    map = category_subcategories_by_parent(@groups)

    assert_equal [ @parent.id ], map.keys
    assert_equal [ [ @child.name, @child.id ] ], map[@parent.id]
  end

  private
    def parse(html)
      Nokogiri::HTML5.fragment(html)
    end
end
