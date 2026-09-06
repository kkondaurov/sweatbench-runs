defmodule GroupStay.Reservations.FinanceCreditMovement do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    operation_id
    posting_date
    issued_cents
    expired_cents
    consumed_cents
    revoked_cents
    absorbed_cents
  )a

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, @fields)
    |> validate_required([:operation_id, :posting_date])
  end
end
