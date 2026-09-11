module CategoriesHelper
  def transfer_category
    Category.new \
      name: "Transfer",
      color: Category::TRANSFER_COLOR,
      lucide_icon: "arrow-right-left"
  end

  def payment_category
    Category.new \
      name: "Payment",
      color: Category::PAYMENT_COLOR,
      lucide_icon: "arrow-right"
  end

  def trade_category
    Category.new \
      name: "Trade",
      color: Category::TRADE_COLOR
  end

  def family_categories
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically)
  end

  # The search filter carries category names rather than ids, so a filter chip
  # has to look the category back up to show its icon. Indexed once per request,
  # since a page can render a chip per selected category.
  def filter_category(name)
    @filter_categories ||= family_categories.index_by(&:name)
    @filter_categories[name]
  end

  # -- Two-select category picker --------------------------------------------
  #
  # One <select> holding every category, even grouped into <optgroup>s, stops
  # being usable at a few hundred of them. The picker is split in two instead:
  # categories, then the subcategories of whichever category is chosen.
  #
  # The subcategory select is the one that actually gets submitted. Its "None"
  # option carries the parent's own id, so leaving the subcategory alone submits
  # the category itself -- a parent is assignable in its own right, and most of
  # them carry transactions directly.
  NO_SUBCATEGORY = "None".freeze

  # The group the current value belongs to, whether that value is a parent or
  # one of its subcategories.
  def category_group_for(groups, selected)
    return nil if selected.blank?

    groups.find { |group| group.category.id == selected || group.subcategories.any? { |sub| sub.id == selected } }
  end

  def category_parent_options(groups, selected:, blank_label:)
    options_for_select(
      [ [ blank_label, "" ] ] + groups.map { |group| [ group.name, group.category.id ] },
      selected&.category&.id
    )
  end

  def category_subcategory_options(group, selected:)
    return options_for_select([ [ NO_SUBCATEGORY, "" ] ]) if group.nil?

    options_for_select(
      [ [ NO_SUBCATEGORY, group.category.id ] ] + group.subcategories.map { |sub| [ sub.name, sub.id ] },
      selected
    )
  end

  # Parent id => its subcategories, for the Stimulus controller to swap into the
  # second select. Childless categories are left out to keep the payload small.
  def category_subcategories_by_parent(groups)
    groups.reject { |group| group.subcategories.empty? }
          .to_h { |group| [ group.category.id, group.subcategories.map { |sub| [ sub.name, sub.id ] } ] }
  end
end
