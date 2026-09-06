defmodule GroupStay.Finance.Reporting do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :latest_closed_on, :date
    field :opening_credit_liability_cents, :integer
    timestamps(type: :utc_datetime_usec)
  end
end
