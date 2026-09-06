defmodule GroupStay.Finance.ReportingState do
  @moduledoc """
  The single row recording that finance reporting has started: the partner
  operation that started it, the reporting start date, and the company-wide
  hotel-credit liability in the opening position.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting_state" do
    field :singleton, :string, default: "current"
    field :operation_id, :string
    field :starts_on, :date
    field :opening_liability_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:singleton, :operation_id, :starts_on, :opening_liability_cents])
    |> validate_required([:singleton, :operation_id, :starts_on, :opening_liability_cents])
    |> unique_constraint(:singleton)
  end
end
