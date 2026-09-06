defmodule GroupStay.Reservations.FinanceReporting do
  @moduledoc false

  use Ecto.Schema

  schema "finance_reporting_settings" do
    field :starts_on, :date

    timestamps(type: :utc_datetime)
  end
end
