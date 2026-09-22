defmodule GroupStay.Finance.CreditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_events" do
    field :credit_lot_id, :binary_id
    field :posting_on, :date
    field :kind, :string
    field :amount_cents, :integer
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:credit_lot_id, :posting_on, :kind, :amount_cents, :operation_id])
    |> validate_required([:credit_lot_id, :posting_on, :kind, :amount_cents, :operation_id])
    |> validate_inclusion(:kind, ["issue", "apply", "restore_available", "revoke"])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
