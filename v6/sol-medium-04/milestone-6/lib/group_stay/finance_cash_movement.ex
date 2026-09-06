defmodule GroupStay.FinanceCashMovement do
  use Ecto.Schema

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :property_id, :string
    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
