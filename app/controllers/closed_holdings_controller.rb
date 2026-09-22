class ClosedHoldingsController < ApplicationController
  def index
    @account = Current.family.accounts.find(params[:account_id])
    # Newest sale first. Few rows, so sorting on the FIFO replay is fine.
    @holdings = @account.closed_holdings.sort_by { |h| h.performance.last_sale_date || Date.new(1900) }.reverse
  end
end
