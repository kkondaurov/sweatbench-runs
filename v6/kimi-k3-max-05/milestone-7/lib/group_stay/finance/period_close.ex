defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One successful period close: the cutoff it published reports through and
  the partner operation that closed the period. Cutoffs are strictly
  increasing, so the row with the latest `period_end_on` separates the
  published period from the open period.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:period_end_on, :operation_id])
    |> validate_required([:period_end_on, :operation_id])
    |> unique_constraint(:period_end_on)
  end
end
