defmodule GroupStay.Bookings.CashSource do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.{CashAllocation, CashDisposition, CreditEntitlement, Group, Operation}

  schema "cash_sources" do
    field :payment_operation_id, :string
    field :funding_order, :integer
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transfer_participated, :boolean, default: false

    belongs_to :group, Group, references: :group_id, type: :string

    belongs_to :payment_operation, Operation,
      references: :operation_id,
      foreign_key: :payment_operation_id,
      type: :string,
      define_field: false

    has_many :allocations, CashAllocation
    has_many :dispositions, CashDisposition
    has_many :credit_entitlements, CreditEntitlement
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :group_id,
      :payment_operation_id,
      :funding_order,
      :recorded_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents,
      :transfer_participated
    ])
    |> validate_required([
      :group_id,
      :recorded_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents,
      :transfer_participated
    ])
    |> unique_constraint(:payment_operation_id)
  end
end
