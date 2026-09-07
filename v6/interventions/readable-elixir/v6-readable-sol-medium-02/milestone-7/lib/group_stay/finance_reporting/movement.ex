defmodule GroupStay.FinanceReporting.Movement do
  @moduledoc false

  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :late_adjustment, :boolean, default: false

    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    field :credit_issued_cents, :integer, default: 0
    field :credit_expired_cents, :integer, default: 0
    field :credit_consumed_cents, :integer, default: 0
    field :credit_revoked_cents, :integer, default: 0
    field :credit_absorbed_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
