class AddPositionToAccounts < ActiveRecord::Migration[7.2]
  def up
    add_column :accounts, :position, :integer
    add_index :accounts, [ :family_id, :position ]

    # Seed the manual order from the ordering accounts were displayed in until
    # now (Account.alphabetically), so nothing visibly moves on deploy. The SQL
    # is inlined rather than calling the scope: a migration must keep working
    # after the model changes.
    execute <<~SQL
      UPDATE accounts a
      SET position = ranked.row_number
      FROM (
        SELECT
          ac.id,
          ROW_NUMBER() OVER (
            PARTITION BY ac.family_id
            ORDER BY
              split_part(ac.name, ' · ', 1) ASC,
              (ac.currency <> f.currency) ASC,
              ac.currency ASC,
              ac.name ASC
          ) AS row_number
        FROM accounts ac
        JOIN families f ON f.id = ac.family_id
      ) ranked
      WHERE a.id = ranked.id
    SQL
  end

  def down
    remove_index :accounts, [ :family_id, :position ]
    remove_column :accounts, :position
  end
end
