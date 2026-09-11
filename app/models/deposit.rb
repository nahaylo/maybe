class Deposit < ApplicationRecord
  include Accountable

  class << self
    def display_name
      "Deposits"
    end

    def color
      "#0BA5EC"
    end

    def icon
      "vault"
    end

    def classification
      "asset"
    end
  end
end
