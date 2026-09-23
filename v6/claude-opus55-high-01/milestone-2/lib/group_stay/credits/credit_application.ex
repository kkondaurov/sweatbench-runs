defmodule GroupStay.Credits.CreditApplication do
  @moduledoc """
  Hotel credit from one lot applied to a group's deposit.

  Statuses:

    * `applied` - funding an active group; the lot's expiry is paused;
    * `restored` - returned to its lot on a refundable cancellation;
    * `expired` - returned on a refundable cancellation after its lot had expired;
    * `consumed` - used up by a non-refundable cancellation.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "credit_applications" do
    field :group_ref, :integer
    field :lot_ref, :integer
    field :operation_id, :string
    field :amount_cents, :integer
    field :applied_on, :date
    field :status, :string
    field :settled_on, :date

    timestamps()
  end
end
