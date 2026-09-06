defmodule GroupStay.Finance.Close do
  @moduledoc """
  One period finance has signed off, named by the date it published through.

  Closes only ever move forward, so the latest `period_end_on` is the cutoff: every
  report through it is published and everything committed afterwards posts to the
  first open day.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:period_end_on, :operation_id]

  def changeset(close, attrs) do
    close
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:period_end_on)
    |> unique_constraint(:operation_id)
  end
end
