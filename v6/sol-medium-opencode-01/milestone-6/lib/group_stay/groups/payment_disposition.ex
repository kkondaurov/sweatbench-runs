defmodule GroupStay.Groups.PaymentDisposition do
  use Ecto.Schema

  alias GroupStay.Groups.{CashAllocation, Group, PaymentSettlement}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payment_dispositions" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :participated_in_transfer, :boolean, default: false

    belongs_to :group, Group
    has_many :cash_allocations, CashAllocation
    has_many :settlements, PaymentSettlement
    timestamps(type: :utc_datetime_usec)
  end
end
