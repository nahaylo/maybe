require "test_helper"
class TypeFilterMarkupTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "global transactions filter menu: checkboxes do not auto-submit and reflect state" do
    get transactions_url(q: { types: [ "expense" ] })
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    boxes = doc.css('input[type=checkbox][name="q[types][]"]')
    assert_equal 3, boxes.size
    boxes.each do |b|
      assert_nil b["data-auto-submit-form-target"],
        "global page checkbox #{b['value']} must not auto-submit (menu has an Apply button)"
    end
    assert_equal({ "income" => false, "expense" => true, "transfer" => false },
                 boxes.to_h { |b| [ b["value"], b["checked"].present? ] })
  end

  # Nothing checked is the unfiltered state: you start from everything and check
  # the types you want to narrow to.
  test "unfiltered renders every box unchecked on both pages" do
    [ transactions_url, account_url(accounts(:depository)) ].each do |url|
      get url
      assert_response :success

      boxes = Nokogiri::HTML(response.body).css('input[type=checkbox][name="q[types][]"]')
      assert_equal 3, boxes.size, "expected three type checkboxes at #{url}"
      assert boxes.none? { |b| b["checked"].present? },
        "unfiltered state at #{url} should render no box checked"
    end
  end

  test "global page filter chips clear via the DELETE endpoint" do
    get transactions_url(q: { types: [ "expense" ], search: "coffee" })
    assert_response :success

    chips = Nokogiri::HTML(response.body).css("#transaction-search-filters li")
    assert_equal 2, chips.size

    chips.each do |chip|
      form = chip.at_css("form")
      assert form, "global chip should clear via button_to, not a link"
      assert_includes form["action"], "/transactions/clear_filter"
      assert_equal "delete", form.at_css("input[name=_method]")["value"]
    end
  end

  test "account page filter chips clear by re-navigating with the value removed" do
    account = accounts(:depository)
    get account_url(account, q: { types: %w[expense transfer], search: "coffee" })
    assert_response :success

    chips = Nokogiri::HTML(response.body).css("ul[id^=entry_search_filters] li")
    assert_equal 3, chips.size, "expected one chip per applied filter value"

    # A GET form drops its query string, so these must be links.
    chips.each do |chip|
      assert_nil chip.at_css("form"), "account chip must clear via a link, not a form"
      assert chip.at_css("a"), "account chip needs a clear link"
    end

    hrefs = chips.map { |chip| chip.at_css("a")["href"] }

    search_chip = hrefs.find { |h| !h.include?("q%5Bsearch%5D") }
    assert_includes search_chip, "q%5Btypes%5D%5B%5D=expense"
    assert_includes search_chip, "q%5Btypes%5D%5B%5D=transfer"

    expense_chip = hrefs.find { |h| h.include?("transfer") && !h.include?("expense") }
    assert expense_chip, "clearing expense should keep search and transfer"
    assert_includes expense_chip, "q%5Bsearch%5D=coffee"
  end

  test "account page renders no chip list when unfiltered" do
    get account_url(accounts(:depository))
    assert_response :success
    assert_empty Nokogiri::HTML(response.body).css("ul[id^=entry_search_filters]")
  end

  # A bare <button> inside a form defaults to type=submit, so a menu trigger
  # placed in a search form submits it on click and the menu closes immediately.
  test "menu triggers inside a form are type=button" do
    [ transactions_url, account_url(accounts(:depository)) ].each do |url|
      get url
      assert_response :success

      triggers = Nokogiri::HTML(response.body)
        .css('form button[data-ds--menu-target="button"]')

      assert triggers.any?, "expected at least one in-form menu trigger at #{url}"
      triggers.each do |button|
        assert_equal "button", button["type"],
          "menu trigger #{button.text.squish.inspect} at #{url} would submit its form"
      end
    end
  end
end
