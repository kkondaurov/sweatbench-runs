defmodule GroupStay.Finance.ReportingState do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
  end
end
