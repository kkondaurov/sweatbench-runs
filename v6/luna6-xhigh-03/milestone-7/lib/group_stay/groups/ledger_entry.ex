defmodule GroupStay.Groups.LedgerEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "ledger_entries" do
    field :group_id, :string
    field :payment_operation_id, :string
    field :entry_type, :string
    field :amount_cents, :integer
    field :occurred_on, :date
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:group_id, :payment_operation_id, :entry_type, :amount_cents, :occurred_on])
    |> validate_required([:group_id, :entry_type, :amount_cents, :occurred_on])
    |> validate_inclusion(:entry_type, [
      "cash_held",
      "cash_refunded",
      "cash_retained",
      "cash_converted_to_credit",
      "cash_reduced",
      "cash_charged_back"
    ])
    |> foreign_key_constraint(:group_id)
  end
end
