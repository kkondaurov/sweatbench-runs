defmodule GroupStay.Finance.ReportingPeriod do
  @moduledoc "The durable inception and inclusive publication cutoff for company-wide reporting."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :closed_through, :date
  end
end
