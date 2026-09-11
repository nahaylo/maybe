# frozen_string_literal: true

namespace :exchange_rates do
  desc "Backfill exchange rates from free providers (Frankfurter for ECB currencies, NBU for UAH)"
  task :backfill, %i[from to start_date end_date] => :environment do |_task, args|
    pairs = if args[:from].present? && args[:to].present?
      [ [ args[:from].upcase, args[:to].upcase ] ]
    end

    backfiller = ExchangeRate::Backfiller.new(
      pairs: pairs,
      start_date: args[:start_date].presence && Date.parse(args[:start_date]),
      end_date: args[:end_date].presence && Date.parse(args[:end_date]),
      clear_cache: ActiveModel::Type::Boolean.new.cast(ENV["CLEAR_CACHE"]) || false,
      include_reverse: ActiveModel::Type::Boolean.new.cast(ENV["REVERSE"]) || false
    )

    results = backfiller.backfill

    if results.empty?
      puts "No multi-currency accounts or entries found, nothing to backfill."
      next
    end

    results.each do |result|
      pair = "#{result.from} -> #{result.to}"

      if result.skipped?
        puts "  #{pair}: SKIPPED (no free provider covers this pair)"
      elsif result.failed?
        puts "  #{pair}: FAILED (#{result.error.class}: #{result.error.message})"
      else
        puts "  #{pair}: #{result.imported_count} new rate(s) via #{result.provider_name}"
      end
    end

    puts "Done."
  end
end
