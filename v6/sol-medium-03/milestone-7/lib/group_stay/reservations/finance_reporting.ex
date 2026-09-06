defmodule GroupStay.Reservations.FinanceReporting do
  @moduledoc false

  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :credit_opening_cents, :integer
    field :latest_period_end_on, :date

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
