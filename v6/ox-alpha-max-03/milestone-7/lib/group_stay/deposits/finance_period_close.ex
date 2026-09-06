defmodule GroupStay.Deposits.FinancePeriodClose do
  @moduledoc """
  One successful `close_finance_period` operation.

  Every daily report through `period_end_on` is published when this row is
  committed, and the latest `period_end_on` is the cutoff that later finance
  posting dates may not fall before.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on])
    |> validate_required([:period_end_on])
    |> unique_constraint(:period_end_on)
  end
end
