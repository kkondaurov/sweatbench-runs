defmodule GroupStay.FinanceReporting.CashOpening do
  @moduledoc "A property's held-cash position when finance reporting began."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.FinanceReporting.Setting

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer
    belongs_to :reporting_setting, Setting
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:reporting_setting_id, :property_id, :opening_held_cents])
    |> validate_required([:reporting_setting_id, :property_id, :opening_held_cents])
    |> unique_constraint([:reporting_setting_id, :property_id])
  end
end
