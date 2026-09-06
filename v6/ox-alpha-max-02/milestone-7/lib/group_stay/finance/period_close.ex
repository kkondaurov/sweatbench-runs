defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One applied `close_finance_period` operation: the date through which daily
  finance reports are published.

  At most one row exists per cutoff, and each cutoff is strictly later than
  the previous one. Every report through the latest cutoff is closed: no
  later operation can post a movement at or before it, so its content is
  stable across later operations, later closes, and restarts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(close, attrs) do
    cast(close, attrs, [:period_end_on, :operation_id])
    |> validate_required([:period_end_on])
    |> unique_constraint(:period_end_on)
  end
end
