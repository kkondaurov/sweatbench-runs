defmodule GroupStay.FinanceReporting.CreditLotOpeningBalance do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_credit_lot_opening_balances" do
    field :credit_lot_record_id, :binary_id
    field :expires_on, :date
    field :remaining_cents, :integer
    field :allocated_cents, :integer

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [
      :credit_lot_record_id,
      :expires_on,
      :remaining_cents,
      :allocated_cents
    ])
    |> validate_required([
      :credit_lot_record_id,
      :expires_on,
      :remaining_cents,
      :allocated_cents
    ])
    |> unique_constraint(:credit_lot_record_id)
  end
end
