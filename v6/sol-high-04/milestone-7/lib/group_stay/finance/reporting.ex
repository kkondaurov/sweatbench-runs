defmodule GroupStay.Finance.Reporting do
  use Ecto.Schema

  schema "finance_reportings" do
    field :operation_id, :string
    field :starts_on, :date
    field :closed_through, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
