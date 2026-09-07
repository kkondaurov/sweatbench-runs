defmodule GroupStay.FinanceReporting.PeriodClose do
  @moduledoc """
  A successfully published finance cutoff.

  Close records are append-only. Keeping every cutoff, rather than only the
  latest one, leaves a durable finance audit trail while the operation record
  retains the exact submitted request and response.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:operation_id, :period_end_on])
    |> validate_required([:operation_id, :period_end_on])
    |> unique_constraint(:operation_id)
    |> unique_constraint(:period_end_on)
  end
end
