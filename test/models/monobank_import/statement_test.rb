require "test_helper"

class MonobankImport::StatementTest < ActiveSupport::TestCase
  setup do
    @rows = MonobankImport::Statement.parse(JSON.parse(file_fixture("monobank/statement.json").read))
    @by_id = @rows.index_by(&:external_id)
    @from = Time.utc(2026, 8, 22)
    @to = Time.utc(2026, 9, 3)
  end

  teardown { FileUtils.remove_entry(@cache_root) if @cache_root }

  test "parses rows oldest first" do
    assert_equal @rows.map(&:time).sort, @rows.map(&:time)
  end

  test "flips the sign and converts minor units" do
    # Monobank sends -25000 for a 250.00 purchase; Maybe wants outflows positive.
    assert_equal 250.to_d, @by_id["TESTgroceries0000000000"].amount
  end

  test "an incoming payment becomes a negative amount" do
    assert_equal(-1000.to_d, @by_id["TESTtransferunknown00"].amount)
  end

  test "dates use the bank's timezone, not the server's" do
    # 1755594000 is 09:00 UTC, which is 12:00 in Kyiv -- same day either way,
    # but the conversion has to happen for late-evening rows to land right.
    assert_equal Date.new(2025, 8, 19), @by_id["TESTgroceries0000000000"].date
  end

  test "resolves ISO 4217 numeric codes from the currency config" do
    assert_equal "UAH", @by_id["TESTgroceries0000000000"].currency
    assert_equal "EUR", @by_id["TESTforeigneur0000000"].currency
  end

  test "a row is foreign when the operation amount differs from the posted amount" do
    assert_predicate @by_id["TESTforeigneur0000000"], :foreign?
    assert_not_predicate @by_id["TESTgroceries0000000000"], :foreign?
  end

  test "unsettled rows are flagged" do
    assert_predicate @by_id["TESTholdpending000000"], :hold?
    assert_not_predicate @by_id["TESTgroceries0000000000"], :hold?
  end

  test "name falls back to the counterparty when the description is blank" do
    row = MonobankImport::Statement.row_from(
      "id" => "x", "time" => 1_755_594_000, "description" => "", "amount" => -100,
      "counterName" => "ТОВ Ромашка"
    )

    assert_equal "ТОВ Ромашка", row.name
  end

  # The path that actually calls the API. Nothing else covered it, and a missing
  # provider! helper survived the whole suite because every other test either
  # hits the cache or stubs at the provider level.
  test "fetches through the provider on a cache miss, then serves from cache" do
    provider = mock
    provider.expects(:statement)
            .with(account_id: "acc", from: @from, to: @to)
            .returns(Provider::Response.new(success?: true, data: [], error: nil))
            .once

    statement = MonobankImport::Statement.new(provider: provider, cache: cache)

    assert_equal [], statement.rows(account_id: "acc", from: @from, to: @to)
    assert_equal [], statement.rows(account_id: "acc", from: @from, to: @to)
  end

  test "a failed fetch raises the provider's error rather than caching a miss" do
    provider = mock
    provider.stubs(:statement).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Monobank::RateLimitedError.new("slow down"))
    )

    statement = MonobankImport::Statement.new(provider: provider, cache: cache)

    assert_raises(Provider::Monobank::RateLimitedError) do
      statement.rows(account_id: "acc", from: @from, to: @to)
    end
    assert_not cache.cached?(MonobankImport::Statement.cache_key("acc", @from, @to))
  end

  test "without a provider a cache miss says why" do
    statement = MonobankImport::Statement.new(cache: cache)

    error = assert_raises(MonobankImport::Error) { statement.rows(account_id: "acc", from: @from, to: @to) }
    assert_match(/no Monobank connection/, error.message)
  end

  test "missing money fields read as zero rather than raising" do
    row = MonobankImport::Statement.row_from("id" => "x", "time" => 1_755_594_000, "description" => "d")

    assert_equal 0.to_d, row.amount
    assert_equal 0.to_d, row.cashback
  end

  test "a span inside the API limit is a single window" do
    statement = MonobankImport::Statement.new(cache: cache)

    assert_equal [ [ @from, @to ] ], statement.windows(@from, @to)
  end

  test "a long backfill is split into windows that tile the span exactly" do
    statement = MonobankImport::Statement.new(cache: cache)
    from = Time.utc(2026, 3, 7)
    to = Time.utc(2026, 9, 3)

    windows = statement.windows(from, to)

    assert_equal 6, windows.size # 180 days over 30-day windows
    assert_equal from, windows.first.first
    assert_equal to, windows.last.last
    windows.each_cons(2) do |(_, earlier_end), (later_start, _)|
      assert_equal 1, (later_start - earlier_end), "windows must be contiguous, with no gap or overlap"
    end
    windows.each do |start, finish|
      assert_operator finish - start, :<=, Provider::Monobank::MAX_RANGE.to_i, "window wider than the API allows"
    end
  end

  test "a backfill fetches each window once and merges them" do
    statement = MonobankImport::Statement.new(provider: chunked_provider, cache: cache)
    rows = statement.rows(account_id: "acc", from: Time.utc(2026, 6, 1), to: Time.utc(2026, 9, 3))

    assert_equal %w[w0 w1 w2 w3], rows.map(&:external_id)
  end

  private
    # Returns one distinguishable row per window, so the merge can be asserted.
    def chunked_provider
      provider = mock
      provider.stubs(:statement).with do |account_id:, from:, to:|
        @window_index = (@window_index || -1) + 1
        true
      end.returns(*Array.new(4) { |i|
        Provider::Response.new(
          success?: true,
          data: [ { "id" => "w#{i}", "time" => Time.utc(2026, 6, 1).to_i + (i * 86_400), "description" => "row #{i}", "amount" => -100 } ],
          error: nil
        )
      })
      provider
    end

    def cache
      @cache_root ||= Pathname.new(Dir.mktmpdir)
      @cache ||= MonobankImport::Cache.new(root: @cache_root)
    end
end
