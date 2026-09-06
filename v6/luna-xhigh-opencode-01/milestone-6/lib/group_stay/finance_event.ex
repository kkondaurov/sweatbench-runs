defmodule GroupStay.FinanceEvent do
  use Ecto.Schema

  schema "finance_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :credit_lot_id, :integer
    field :credit_available_delta, :integer
    field :received_cents, :integer
    field :transferred_in_cents, :integer
    field :transferred_out_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
    field :issued_cents, :integer
    field :expired_cents, :integer
    field :consumed_cents, :integer
    field :revoked_cents, :integer
    field :absorbed_cents, :integer
  end
end
