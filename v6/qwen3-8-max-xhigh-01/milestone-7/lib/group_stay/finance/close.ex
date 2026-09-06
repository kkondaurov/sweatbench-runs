defmodule GroupStay.Finance.Close do
  @moduledoc """
  One successful finance-period close.

  Closes advance the published cutoff: a close applies only when its
  `period_end_on` is strictly later than every close before it, so the latest
  successful close is the one with the greatest cutoff. Reports through the
  latest cutoff are published and served from their stored form.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = close, attrs) do
    close
    |> cast(attrs, [:period_end_on])
    |> validate_required([:period_end_on])
    |> unique_constraint(:period_end_on)
  end
end
