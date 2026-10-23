class InvestmentPerformancesController < ApplicationController
  def show
    @account = Current.family.accounts.find(params[:account_id])

    year = params[:year].to_i
    year = Date.current.year unless year.between?(1990, Date.current.year + 1)
    @performance = Account::InvestmentPerformance.new(@account, year: year)
  end
end
