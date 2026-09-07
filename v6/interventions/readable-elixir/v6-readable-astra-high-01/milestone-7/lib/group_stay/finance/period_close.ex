defmodule GroupStay.Finance.PeriodClose do
  @moduledoc "A published cutoff, committed atomically with its durable operation receipt."
  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date
  end
end
