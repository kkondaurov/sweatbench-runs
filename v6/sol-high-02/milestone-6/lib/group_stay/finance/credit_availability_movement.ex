defmodule GroupStay.Finance.CreditAvailabilityMovement do
  @moduledoc false

  use Ecto.Schema

  schema "finance_credit_availability_movements" do
    field :operation_id, :string
    field :credit_lot_id, :integer
    field :posting_date, :date
    field :amount_cents, :integer
  end
end
