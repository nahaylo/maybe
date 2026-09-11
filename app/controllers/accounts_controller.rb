class AccountsController < ApplicationController
  before_action :set_account, only: %i[sync sparkline toggle_active convert show destroy]
  include Periodable

  def index
    @manual_accounts = family.accounts.manual.ordered
    @plaid_items = family.plaid_items.ordered

    render layout: "settings"
  end

  def sync_all
    family.sync_later
    redirect_to accounts_path, notice: "Syncing accounts..."
  end

  def convert
    if @account.convert_to!(params[:accountable_type])
      redirect_to account_path(@account), notice: "Account type changed to #{@account.accountable_class.display_name.singularize}"
    else
      redirect_to account_path(@account), alert: "Account is already that type"
    end
  rescue ArgumentError => e
    redirect_to account_path(@account), alert: e.message
  end

  def reorder
    family.reorder_accounts!(params.fetch(:account_ids, []))

    head :no_content
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @tab = params[:tab]
    @q = params.fetch(:q, {}).permit(:search, types: [])
    entries = @account.entries.search(@q).reverse_chronological

    # Tabs switch client-side, so a pagination link rendered at page load does
    # not know which tab is open. Each list pins its own tab into its links.
    @pagy, @entries = pagy(entries, limit: params[:per_page] || "10", params: { tab: "activity" })

    @activity_feed_data = Account::ActivityFeedData.new(@account, @entries)

    # The Costs tab lists spending attributed to a vehicle from other accounts.
    # Its own page param keeps its pagination independent of the activity feed's.
    if @account.vehicle?
      @costs_pagy, @cost_entries = pagy(
        @account.vehicle.cost_entries.includes(:account, entryable: [ :category, :merchant, :transfer ]).reverse_chronological,
        limit: params[:per_page] || "10",
        page_param: :costs_page,
        params: { tab: "costs" }
      )
    end
  end

  def sync
    unless @account.syncing?
      @account.sync_later
    end

    redirect_to account_path(@account)
  end

  def sparkline
    etag_key = @account.family.build_cache_key("#{@account.id}_sparkline", invalidate_on_data_updates: true)

    # Short-circuit with 304 Not Modified when the client already has the latest version.
    # We defer the expensive series computation until we know the content is stale.
    if stale?(etag: etag_key, last_modified: @account.family.latest_sync_completed_at)
      @sparkline_series = @account.sparkline_series
      render layout: false
    end
  end

  def toggle_active
    if @account.active?
      @account.disable!
    elsif @account.disabled?
      @account.enable!
    end
    redirect_to accounts_path
  end

  def destroy
    if @account.linked?
      redirect_to account_path(@account), alert: "Cannot delete a linked account"
    else
      @account.destroy_later
      redirect_to accounts_path, notice: "Account scheduled for deletion"
    end
  end

  private
    def family
      Current.family
    end

    def set_account
      @account = family.accounts.find(params[:id])
    end
end
