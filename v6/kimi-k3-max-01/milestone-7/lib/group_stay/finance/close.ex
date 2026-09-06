defmodule GroupStay.Finance.Close do
  @moduledoc """
  A durable finance period close.

  Each applied `close_finance_period` operation inserts one row with its
  `period_end_on` cutoff. Every daily report through the cutoff is published
  at close time and never changes again; a later close must be strictly
  later than the latest row here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_closes" do
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
