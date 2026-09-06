defmodule GroupStay.Reservations.FinanceCreditMovement do
  use Ecto.Schema
  import Ecto.Changeset

  @amount_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:operation_id, :posting_on | @amount_fields])
    |> validate_required([:operation_id, :posting_on | @amount_fields])
  end
end
