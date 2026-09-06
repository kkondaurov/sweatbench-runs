defmodule GroupStay.Finance.Close do
  @moduledoc """
  One successful finance period close. The latest `period_end_on` is the
  cutoff through which daily reports are published and stay stable.
  """

  use Ecto.Schema

  schema "finance_closes" do
    field :period_end_on, :date

    timestamps()
  end
end
