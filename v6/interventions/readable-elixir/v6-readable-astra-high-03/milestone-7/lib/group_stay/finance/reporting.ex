defmodule GroupStay.Finance.Reporting do
  @moduledoc "The singleton inception date and latest published cutoff for the finance journal."
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :closed_through, :date
  end
end
