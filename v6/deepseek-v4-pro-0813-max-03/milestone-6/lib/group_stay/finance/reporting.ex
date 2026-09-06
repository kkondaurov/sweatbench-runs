defmodule GroupStay.Finance.Reporting do
  @moduledoc false

  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening, :map

    timestamps()
  end
end
