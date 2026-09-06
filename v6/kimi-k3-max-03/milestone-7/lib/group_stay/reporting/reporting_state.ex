defmodule GroupStay.Reporting.ReportingState do
  @moduledoc """
  The singleton row that turns finance reporting on: the reporting inception
  date and the credit liability opening position captured the moment the first
  `start_finance_reporting` operation was processed. Per-property opening cash
  balances live in `finance_opening_balances`. `closed_through` is the latest
  successful close cutoff: reports on or before that date are published and
  immutable.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reporting.OpeningBalance

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    field :closed_through, :date

    has_many :opening_balances, OpeningBalance,
      foreign_key: :finance_reporting_id,
      preload_order: [asc: :property_id]

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:starts_on, :opening_credit_liability_cents])
    |> cast_assoc(:opening_balances)
    |> validate_required([:starts_on, :opening_credit_liability_cents])
  end
end
