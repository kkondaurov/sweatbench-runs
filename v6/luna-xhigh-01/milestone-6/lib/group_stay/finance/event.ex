defmodule GroupStay.Finance.Event do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_events" do
    field :operation_id, :string
    field :posting_date, :date
    field :property_id, :string
    field :payment_operation_id, :string
    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :credit_lot_id, :integer
    field :credit_available_delta_cents, :integer, default: 0
    field :credit_issued_cents, :integer, default: 0
    field :credit_expired_cents, :integer, default: 0
    field :credit_consumed_cents, :integer, default: 0
    field :credit_revoked_cents, :integer, default: 0
    field :credit_absorbed_cents, :integer, default: 0
  end

  def changeset(event, attrs) do
    Ecto.Changeset.cast(event, attrs, [
      :operation_id,
      :posting_date,
      :property_id,
      :payment_operation_id,
      :received_cents,
      :transferred_in_cents,
      :transferred_out_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents,
      :credit_lot_id,
      :credit_available_delta_cents,
      :credit_issued_cents,
      :credit_expired_cents,
      :credit_consumed_cents,
      :credit_revoked_cents,
      :credit_absorbed_cents
    ])
    |> Ecto.Changeset.validate_required([:operation_id, :posting_date])
  end
end
