class Business < ApplicationRecord
  include Accountable

  class << self
    def display_name
      "Business"
    end

    def color
      "#DD2590"
    end

    def icon
      "briefcase"
    end

    def classification
      "asset"
    end
  end
end
