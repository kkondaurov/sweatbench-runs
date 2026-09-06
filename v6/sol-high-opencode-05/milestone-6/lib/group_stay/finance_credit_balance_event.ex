defmodule GroupStay.FinanceCreditBalanceEvent do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_credit_balance_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :effective_on, :date
    field :available_delta_cents, :integer
    field :applied_delta_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot
  end
end
