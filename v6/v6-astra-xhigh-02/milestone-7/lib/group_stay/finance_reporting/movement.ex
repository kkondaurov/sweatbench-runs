defmodule GroupStay.FinanceReporting.Movement do
  @moduledoc false
  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :posted_on, GroupStay.FinanceReporting.PostingDate
    field :late_adjustment, :boolean, default: false
    field :cash, :map
    field :credit, :map
  end
end
