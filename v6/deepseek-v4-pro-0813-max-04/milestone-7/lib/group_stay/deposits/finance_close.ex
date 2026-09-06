defmodule GroupStay.Deposits.FinanceClose do
  use Ecto.Schema

  @moduledoc """
  One successfully applied `close_finance_period` operation. The latest
  `period_end_on` bounds the open reporting period: operations committing
  after a close never report on a day at or before it.
  """

  schema "finance_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps()
  end
end
