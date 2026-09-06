defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest, for example by converting refunded
  cash during a cancellation. `remaining_cents` is the portion that has not
  been applied to a group or spent; portions currently funding active rooms
  are tracked by `GroupStay.Groups.RoomCreditApplication`.

  `unrecovered_clawback_cents` is the part of charged-back payments' credit
  entitlements that could not be taken from the lot's remaining balance.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :expires_on, :date
    field :remaining_cents, :integer, default: 0
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :group_applications, GroupStay.Groups.RoomCreditApplication,
      foreign_key: :credit_lot_id

    timestamps(type: :utc_datetime)
  end
end
