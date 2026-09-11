# ISO 18245 merchant category code, as reported by the card network.
#
# Stored rather than merely consumed at import time: it is the strongest
# category predictor available, and the Monobank API allows one request per
# 60 seconds, which makes re-fetching to re-run categorisation expensive.
class AddMccToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :mcc, :integer
  end
end
