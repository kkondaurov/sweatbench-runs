defmodule GroupStay.FinanceReportingEntry do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_entries" do
    field :operation_id, :string
    field :partner_operation_id, :integer
    field :ordinal, :integer
    field :posting_on, :date
    field :entry_type, :string
    field :property_id, :string
    field :category, :string
    field :amount_cents, :integer
    field :credit_lot_id, :integer
    field :available_delta_cents, :integer, default: 0
    field :applied_delta_cents, :integer, default: 0
    field :expires_on, :date
    field :late_adjustment, :boolean, default: false
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :operation_id,
      :partner_operation_id,
      :ordinal,
      :posting_on,
      :entry_type,
      :property_id,
      :category,
      :amount_cents,
      :credit_lot_id,
      :available_delta_cents,
      :applied_delta_cents,
      :expires_on,
      :late_adjustment
    ])
    |> validate_required([
      :operation_id,
      :partner_operation_id,
      :ordinal,
      :posting_on,
      :entry_type,
      :amount_cents,
      :available_delta_cents,
      :applied_delta_cents
    ])
    |> validate_inclusion(:entry_type, ["cash", "credit"])
    |> validate_number(:ordinal, greater_than: 0)
    |> unique_constraint([:operation_id, :ordinal])
  end
end
