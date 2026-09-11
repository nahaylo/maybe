class UI::Account::ActivityFeed < ApplicationComponent
  attr_reader :feed_data, :pagy, :search, :types

  def initialize(feed_data:, pagy:, search: nil, types: nil)
    @feed_data = feed_data
    @pagy = pagy
    @search = search
    @types = types
  end

  def id
    dom_id(account, :activity_feed)
  end

  def broadcast_channel
    account
  end

  def broadcast_refresh!
    Turbo::StreamsChannel.broadcast_replace_to(
      broadcast_channel,
      target: id,
      renderable: self,
      layout: false
    )
  end

  def activity_dates
    feed_data.entries_by_date
  end

  # Chips for the filters currently applied, mirroring the global transaction
  # list. Each chip's clear_path drops just that one value and keeps the rest.
  def active_filters
    filters = []

    if search.present?
      filters << { param_key: "search", param_value: search, clear_path: filter_path(search: nil) }
    end

    Array(types).each do |type|
      filters << {
        param_key: "types",
        param_value: type,
        clear_path: filter_path(types: Array(types) - [ type ])
      }
    end

    filters
  end

  private
    def account
      feed_data.account
    end

    def filter_path(overrides)
      q = { search: search, types: Array(types) }.merge(overrides).compact_blank
      helpers.account_path(account, q: q.presence)
    end
end
