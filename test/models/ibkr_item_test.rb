require "test_helper"

class IbkrItemTest < ActiveSupport::TestCase
  setup do
    @item = IbkrItem.create!(family: families(:dylan_family), name: "ib", access_token: "token-a", query_id: "123456")
  end

  test "reuses one API client for the whole connection" do
    assert_same @item.provider, @item.provider
    assert_equal "token-a", @item.provider.token
  end

  test "a query id is required -- the token alone cannot fetch anything" do
    item = IbkrItem.new(family: families(:dylan_family), name: "other", access_token: "token-b")

    assert_not item.valid?
    assert_includes item.errors[:query_id], "can't be blank"
  end

  test "a name identifies one connection within a family" do
    duplicate = IbkrItem.new(family: families(:dylan_family), name: "ib", access_token: "token-b", query_id: "1")

    assert_not duplicate.valid?
  end
end
