defmodule GroupStay.Reservations.FinanceEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finance_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :event_type, :string
    field :property_id, :string
    field :amount_cents, :integer, default: 0
    field :credit_lot_id, :binary_id
    field :credit_lot_expires_on, :date
    field :available_delta_cents, :integer, default: 0
    field :applied_delta_cents, :integer, default: 0
    field :late_adjustment, :boolean, default: false

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting, type: :id
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :finance_reporting_id,
      :operation_id,
      :posting_on,
      :event_type,
      :property_id,
      :amount_cents,
      :credit_lot_id,
      :credit_lot_expires_on,
      :available_delta_cents,
      :applied_delta_cents,
      :late_adjustment
    ])
    |> validate_required([
      :finance_reporting_id,
      :operation_id,
      :posting_on,
      :event_type,
      :amount_cents,
      :available_delta_cents,
      :applied_delta_cents,
      :late_adjustment
    ])
  end
end
