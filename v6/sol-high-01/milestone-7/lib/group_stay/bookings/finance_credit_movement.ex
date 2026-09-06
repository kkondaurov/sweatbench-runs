defmodule GroupStay.Bookings.FinanceCreditMovement do
  use Ecto.Schema

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :late_adjustment, :boolean, default: false
    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0
  end
end
