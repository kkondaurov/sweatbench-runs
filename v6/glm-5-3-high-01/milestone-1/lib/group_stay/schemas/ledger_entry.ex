defmodule GroupStay.Schemas.LedgerEntry do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ledger_entries" do
    belongs_to :group, GroupStay.Schemas.Group
    field :operation_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    timestamps()
  end
end
