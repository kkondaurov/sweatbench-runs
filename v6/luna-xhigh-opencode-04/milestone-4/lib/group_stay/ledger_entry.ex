defmodule GroupStay.LedgerEntry do
  use Ecto.Schema

  schema "ledger_entries" do
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Group
  end
end
