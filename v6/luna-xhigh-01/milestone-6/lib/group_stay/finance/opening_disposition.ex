defmodule GroupStay.Finance.OpeningDisposition do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_reporting_opening_dispositions" do
    field :payment_operation_id, :string
    field :property_id, :string
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
  end

  def changeset(disposition, attrs) do
    Ecto.Changeset.cast(disposition, attrs, [
      :payment_operation_id,
      :property_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> Ecto.Changeset.validate_required([
      :payment_operation_id,
      :property_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
  end
end
