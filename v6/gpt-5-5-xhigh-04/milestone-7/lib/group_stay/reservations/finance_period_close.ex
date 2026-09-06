defmodule GroupStay.Reservations.FinancePeriodClose do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(type: :utc_datetime_usec)
  end
end
