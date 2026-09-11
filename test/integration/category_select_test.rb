require "test_helper"

class CategorySelectTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @parent = categories(:food_and_drink)
    @child = categories(:subcategory)
  end

  test "the picker renders two selects, with the model's field on the second" do
    doc = picker_on(new_transaction_url(nature: "outflow"))

    assert_nil doc.at_css("[data-category-select-target='parent']")["name"]&.match(/entryable_attributes/),
      "the category select must not submit the field itself"
    assert_equal "entry[entryable_attributes][category_id]",
      doc.at_css("[data-category-select-target='child']")["name"]
  end

  test "the first select lists categories only" do
    doc = picker_on(new_transaction_url(nature: "outflow"))
    names = doc.at_css("[data-category-select-target='parent']").css("option").map(&:text)

    assert_includes names, @parent.name
    refute_includes names, @child.name, "subcategories belong in the second select"
  end

  test "editing a transaction on a subcategory preselects both selects" do
    entry = entries(:transaction)
    entry.transaction.update!(category: @child)

    doc = picker_on(transaction_url(entry))

    assert_equal @parent.id, doc.at_css("[data-category-select-target='parent'] option[selected]")["value"]
    assert_equal @child.id, doc.at_css("[data-category-select-target='child'] option[selected]")["value"]
  end

  # What the two selects submit: the parent's own id when no subcategory is
  # picked, the subcategory's id when one is.
  test "a category with no subcategory chosen is assigned to the parent" do
    assert_equal @parent, created_transaction_with_category(@parent.id).category
  end

  test "a chosen subcategory wins over its parent" do
    assert_equal @child, created_transaction_with_category(@child.id).category
  end

  # The transfer form only shows a category field for loan payments, so this
  # path renders nowhere in the fixtures by default.
  test "the picker renders on a loan payment transfer" do
    transfer = transfers(:one)
    transfer.inflow_transaction.entry.update!(account: accounts(:loan))

    assert transfer.reload.categorizable?, "fixture is not a loan payment"

    doc = picker_on(transfer_url(transfer))
    assert_equal "transfer[category_id]", doc.at_css("[data-category-select-target='child']")["name"]
  end

  # A Stimulus controller added since the last image build silently drops out of
  # the importmap, leaving the second select frozen with no error.
  test "the category select controller is present in the importmap" do
    get new_transaction_url(nature: "outflow")

    assert_match "controllers/category_select_controller", response.body,
      "category_select_controller is missing from the importmap; rebuild assets"
  end

  test "every form using the picker renders" do
    [ new_transaction_url(nature: "outflow"),
      new_transaction_url(nature: "inflow"),
      transaction_url(entries(:transaction)),
      new_transactions_bulk_update_url,
      new_category_deletion_url(@parent),
      transfer_url(transfers(:one)) ].each do |url|
      get url
      assert_response :success, "#{url} failed to render"
    end
  end

  private
    def picker_on(url)
      get url
      assert_response :success
      Nokogiri::HTML(response.body).at_css("[data-controller='category-select']").tap do |picker|
        assert picker, "no category picker rendered on #{url}"
      end
    end

    def created_transaction_with_category(category_id)
      post transactions_url, params: {
        entry: {
          account_id: accounts(:depository).id,
          name: "Test",
          date: Date.current,
          currency: "USD",
          amount: 100,
          nature: "outflow",
          entryable_type: "Transaction",
          entryable_attributes: { category_id: category_id }
        }
      }

      Entry.order(:created_at).last.transaction
    end
end
