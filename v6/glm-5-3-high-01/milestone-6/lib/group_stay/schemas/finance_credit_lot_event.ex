defmodule GroupStay.Schemas.FinanceCreditLotEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finance_credit_lot_events" do
    belongs_to :credit_lot, GroupStay.Schemas.CreditLot
    field :posting_date, :date
    field :delta_cents, :integer

    timestamps()
  end
end
