defmodule GroupStay.Reporting.OpeningBalance do
  @moduledoc """
  One property's opening held-cash balance captured when reporting started.
  Only properties actually holding cash at that moment have rows.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reporting.ReportingState

  schema "finance_opening_balances" do
    field :property_id, :string
    field :opening_held_cents, :integer

    belongs_to :finance_reporting, ReportingState

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:property_id, :opening_held_cents, :finance_reporting_id])
    |> validate_required([:property_id, :opening_held_cents])
  end

  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:property_id, :opening_held_cents])
    |> validate_required([:property_id, :opening_held_cents])
  end
end
