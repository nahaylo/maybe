# Dedupe key for entries pulled from an external API (currently Monobank).
#
# Not a reuse of the existing, empty `plaid_id`: Entry#linked? is defined as
# `plaid_id.present?`, and the transaction drawer disables date, amount and
# nature for linked entries -- locking exactly the fields an imported row is
# meant to be reviewed and corrected in.
class AddExternalIdToEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :entries, :external_id, :string

    add_index :entries, [ :account_id, :external_id ],
              unique: true,
              where: "external_id IS NOT NULL",
              name: "index_entries_on_account_id_and_external_id"
  end
end
