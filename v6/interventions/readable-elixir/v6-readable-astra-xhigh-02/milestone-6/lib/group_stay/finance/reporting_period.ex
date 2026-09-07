defmodule GroupStay.Finance.ReportingPeriod do
  @moduledoc "The single, durable inception date for company-wide finance reporting."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
  end
end
