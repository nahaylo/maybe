require "test_helper"

class MonobankItemTest < ActiveSupport::TestCase
  setup do
    @item = MonobankItem.create!(family: families(:dylan_family), name: "personal", access_token: "token-a")
  end

  # Provider::Monobank keeps the once-a-minute cooldown in an instance variable,
  # so a fresh client per request would reset it and 429 on the second call.
  test "reuses one API client for the whole connection" do
    assert_same @item.provider, @item.provider
    assert_equal "token-a", @item.provider.token
  end

  test "each connection caches its account list separately" do
    other = MonobankItem.create!(family: families(:dylan_family), name: "spouse", access_token: "token-b")

    assert_not_equal(
      MonobankImport::Statement.client_info_key(@item.cache_scope),
      MonobankImport::Statement.client_info_key(other.cache_scope)
    )
  end

  test "a name identifies one connection within a family" do
    duplicate = MonobankItem.new(family: families(:dylan_family), name: "personal", access_token: "token-b")

    assert_not duplicate.valid?
  end
end
