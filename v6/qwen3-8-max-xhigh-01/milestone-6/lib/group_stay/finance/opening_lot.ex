defmodule GroupStay.Finance.OpeningLot do
  @moduledoc """
  The remaining balance of one credit lot in the opening position, captured
  immediately before the finance-reporting start operation was processed.

  Only lots still unexpired on `starts_on` are captured; their balances let a
  later report compute how much expires when the lot's expiry date passes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_opening_lots" do
    field :remaining_cents, :integer

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = opening, attrs) do
    opening
    |> cast(attrs, [:credit_lot_id, :remaining_cents])
    |> validate_required([:credit_lot_id, :remaining_cents])
  end
end
