defmodule GroupStay.Finance.ClosedReport do
  @moduledoc """
  One published daily report: the report's frozen `data` value as computed
  when the close covering its date was processed. Later operations, later
  closes, and process restarts never change it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_closed_reports" do
    field :date, :date
    field :data, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:date, :data])
    |> validate_required([:date, :data])
    |> unique_constraint(:date)
  end
end
