defmodule GroupStay.FinanceReportingEvent do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_events" do
    field :operation_id, :string
    field :posted_on, :date
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:operation_id, :posted_on, :kind, :property_id, :credit_lot_id, :amount_cents])
    |> validate_required([:operation_id, :posted_on, :kind, :amount_cents])
  end
end
