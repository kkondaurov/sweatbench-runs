defmodule GroupStay.Finance.CreditAvailabilityChange do
  @moduledoc false
  use Ecto.Schema

  alias GroupStay.Deposits.CreditLot

  schema "finance_credit_availability_changes" do
    field :operation_id, :string
    field :posting_on, :date
    field :amount_cents, :integer
    belongs_to :credit_lot, CreditLot
    timestamps(type: :utc_datetime)
  end
end
