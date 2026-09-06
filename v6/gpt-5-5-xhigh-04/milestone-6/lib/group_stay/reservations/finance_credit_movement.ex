defmodule GroupStay.Reservations.FinanceCreditMovement do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
