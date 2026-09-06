defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The finance-reporting inception point.

  The first applied `start_finance_reporting` operation inserts the single
  row here. `opening_cash` is a JSON object of property id to held cash and
  `opening_liability_cents` the company-wide credit liability, both
  snapshotted from the financial state immediately before that operation was
  processed. Every daily report opens from this position and accumulates the
  movements posted after it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :string
    field :opening_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:starts_on, :opening_cash, :opening_liability_cents])
    |> validate_required([:starts_on, :opening_cash, :opening_liability_cents])
  end
end
