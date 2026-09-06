defmodule GroupStay.FinancePeriodClose do
  use Ecto.Schema

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_record_cutoff_id, :integer
    timestamps(type: :utc_datetime)
  end
end
