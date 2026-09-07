defmodule GroupStay.Reservations.CashPaymentAccounting do
  @moduledoc "The current, reconcilable disposition of one durably applied cash payment."

  use Ecto.Schema

  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Reservations.GroupReservation

  schema "cash_payment_accountings" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    belongs_to :operation_record, OperationRecord

    belongs_to :group, GroupReservation,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
