defmodule GroupStay.FinancePosting do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "finance_postings" do
    field :operation_id, :string
    field :posting_on, :date
    field :original_posting_on, :date
    field :property_id, :string
    field :payment_operation_id, :string
    field :credit_lot_id, :integer

    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0

    field :credit_available_delta_cents, :integer, default: 0
    field :credit_applied_delta_cents, :integer, default: 0
  end
end
