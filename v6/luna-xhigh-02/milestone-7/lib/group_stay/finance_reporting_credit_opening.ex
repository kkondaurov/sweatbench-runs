defmodule GroupStay.FinanceReportingCreditOpening do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:lot_id, :integer, autogenerate: false}
  schema "finance_reporting_credit_openings" do
    field :source_operation_id, :string
    field :available_cents, :integer
    field :applied_cents, :integer
    field :expires_on, :date
  end

  def changeset(opening, attrs) do
    cast(opening, attrs, [
      :lot_id,
      :source_operation_id,
      :available_cents,
      :applied_cents,
      :expires_on
    ])
    |> validate_required([
      :lot_id,
      :source_operation_id,
      :available_cents,
      :applied_cents,
      :expires_on
    ])
  end
end
