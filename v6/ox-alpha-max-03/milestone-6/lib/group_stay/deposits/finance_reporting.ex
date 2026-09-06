defmodule GroupStay.Deposits.FinanceReporting do
  @moduledoc """
  The durable reporting inception point.

  A single row exists once the first `start_finance_reporting` operation has
  been applied: `starts_on` is the first reportable date and
  `opening_liability_cents` is the company-wide hotel-credit liability that
  the financial state immediately before that operation contributed to the
  opening position, evaluated as of `starts_on`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:starts_on, :opening_liability_cents])
    |> validate_required([:starts_on, :opening_liability_cents])
  end
end
