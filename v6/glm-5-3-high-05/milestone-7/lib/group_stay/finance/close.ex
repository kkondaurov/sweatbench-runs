defmodule GroupStay.Finance.Close do
  @moduledoc """
  One successful finance period close.

  Each applied `close_finance_period` operation writes exactly one row. The
  latest `period_end_on` is the reporting cutoff: every daily report through
  it is published, and any operation processed after it posts its finance
  effects on the first open day.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_closes" do
    field :period_end_on, :date

    timestamps()
  end

  def changeset(close, attrs) do
    close
    |> Ecto.Changeset.cast(attrs, [:period_end_on])
    |> Ecto.Changeset.validate_required([:period_end_on])
  end
end
