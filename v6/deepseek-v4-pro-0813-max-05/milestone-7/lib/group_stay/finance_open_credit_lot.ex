defmodule GroupStay.FinanceOpenCreditLot do
  use Ecto.Schema

  alias GroupStay.CreditLot

  @moduledoc """
  A credit lot's remaining balance when finance reporting started. Expiry
  movements are reconstructed from this base plus later lot deltas.
  """

  @primary_key false
  @foreign_key_type :binary_id

  schema "finance_open_credit_lots" do
    belongs_to :credit_lot, CreditLot, primary_key: true, type: :binary_id
    field :opening_remaining_cents, :integer

    timestamps()
  end
end
