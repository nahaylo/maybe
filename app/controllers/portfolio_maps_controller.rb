class PortfolioMapsController < ApplicationController
  def show
    @map = Family::PortfolioMap.new(Current.family, group_by: params[:group])
  end
end
