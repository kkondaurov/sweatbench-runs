defmodule GroupStay.Groups.PaymentDisposition do
  @moduledoc """
  The current disposition of the cash recorded by one applied cash payment.

  Held cash is not stored here: it is derived as recorded cash minus every
  other disposition, and lives on rooms as allocations.
  """

  use Ecto.Schema

  schema "payment_dispositions" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :recorded_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    # Set once any of this payment's held cash moved through a
    # transfer_deposit operation; its statement then reports held_by_group.
    field :participated_in_transfer, :boolean, default: false

    timestamps()
  end
end
