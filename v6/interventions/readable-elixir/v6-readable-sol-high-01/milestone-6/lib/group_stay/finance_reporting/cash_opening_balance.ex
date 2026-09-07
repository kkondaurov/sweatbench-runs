defmodule GroupStay.FinanceReporting.CashOpeningBalance do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_cash_opening_balances" do
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:property_id, :opening_held_cents])
    |> validate_required([:property_id, :opening_held_cents])
    |> unique_constraint(:property_id)
  end
end
