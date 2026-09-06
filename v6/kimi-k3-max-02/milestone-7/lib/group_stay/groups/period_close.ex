defmodule GroupStay.Groups.PeriodClose do
  @moduledoc """
  One durable finance period close, recorded by an applied
  `close_finance_period` partner operation.

  Cutoffs are strictly increasing: a close applies only when its
  `period_end_on` is on or after the reporting start date and strictly later
  than the latest successful close. Every finance report through the latest
  cutoff is published with `status: "closed"` and stays byte-for-byte
  stable; an operation committing after a close posts its finance effect on
  the day after the latest cutoff at the moment it commits.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on, :operation_id])
    |> validate_required([:period_end_on])
  end
end
