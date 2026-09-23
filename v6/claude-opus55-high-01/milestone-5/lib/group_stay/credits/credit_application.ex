defmodule GroupStay.Credits.CreditApplication do
  @moduledoc """
  Hotel credit from one lot applied to one room of a group's deposit.

  `operation_id` is the credit application that drew the credit from its lot. `allocation_seq` is
  the order in which funding was allocated, shared with `GroupStay.Groups.CashAllocation`.

  Statuses:

    * `applied` - funding an active group; the lot's expiry is paused;
    * `restored` - returned to its lot on a refundable cancellation;
    * `expired` - returned on a refundable cancellation after its lot had expired;
    * `consumed` - used up by a non-refundable cancellation;
    * `absorbed` - returned on a refundable cancellation and used to extinguish the lot's
      unrecovered clawback;
    * `transferred` - moved to another group by the transfer `transfer_operation_id`, where it is
      applied by a new row carrying the same lot, application, and transfer.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "credit_applications" do
    field :group_ref, :integer
    field :lot_ref, :integer
    field :room_ref, :integer
    field :operation_id, :string
    field :amount_cents, :integer
    field :applied_on, :date
    field :status, :string
    field :settled_on, :date
    field :allocation_seq, :integer
    field :transfer_operation_id, :string

    timestamps()
  end
end
