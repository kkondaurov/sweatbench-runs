defmodule GroupStay.Finance.ReportingStart do
  @moduledoc "The singleton inception point, captured under the partner operation write lock."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting_starts" do
    field :operation_id, :string
    field :starts_on, :date
  end
end
