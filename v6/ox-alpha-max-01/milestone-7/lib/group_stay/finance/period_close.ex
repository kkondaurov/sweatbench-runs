defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One applied `close_finance_period` operation's cutoff date.

  The latest row's `period_end_on` is the published frontier: reports
  through it are frozen, and a new close must land strictly later. The
  unique index keeps a cutoff from being closed twice.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps()
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on])
    |> validate_required([:period_end_on])
    |> unique_constraint(:period_end_on)
  end
end
