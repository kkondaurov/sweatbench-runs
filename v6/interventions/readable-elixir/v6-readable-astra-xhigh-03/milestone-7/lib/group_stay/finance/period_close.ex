defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  A durable publication boundary, committed under the partner operation write lock.

  Entries are immutable and subsequent postings must fall after this cutoff.
  Closed reports can therefore be projected from the journal without storing a
  snapshot for every calendar day, including days nobody has read yet.
  """
  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date
  end
end
