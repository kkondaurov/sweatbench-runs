defmodule GroupStay.FinanceLotDelta do
  use Ecto.Schema

  alias GroupStay.CreditLot

  @moduledoc """
  A reported change to a credit lot's remaining balance at a posting date.

  Applying credit subtracts from a lot and a normal restoration adds to it;
  issuance and revocation also change the reported remaining. Expiry is not
  stored here: it is reconstructed from the lot's opening base plus these
  deltas for dates at or before its `expires_on`.
  """

  @foreign_key_type :binary_id

  schema "finance_lot_deltas" do
    field :operation_id, :string
    field :durable_operation_id, :integer
    field :posting_date, :date
    field :delta_cents, :integer

    belongs_to :credit_lot, CreditLot

    timestamps()
  end
end
