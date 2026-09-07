defmodule GroupStay.Finance.Reporting do
  @moduledoc "The singleton inception date; its opening position lives in the finance journal."
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
  end
end
