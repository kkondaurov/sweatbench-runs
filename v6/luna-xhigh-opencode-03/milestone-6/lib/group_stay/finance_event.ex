defmodule GroupStay.FinanceEvent do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :received_cents, :integer
    field :transferred_in_cents, :integer
    field :transferred_out_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
    field :issued_cents, :integer
    field :expired_cents, :integer
    field :consumed_cents, :integer
    field :revoked_cents, :integer
    field :absorbed_cents, :integer
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :operation_id,
      :posting_on,
      :property_id,
      :received_cents,
      :transferred_in_cents,
      :transferred_out_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents,
      :issued_cents,
      :expired_cents,
      :consumed_cents,
      :revoked_cents,
      :absorbed_cents
    ])
    |> validate_required([:operation_id, :posting_on])
  end
end
