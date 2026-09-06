defmodule GroupStay.Finance.PaymentTransfer do
  @moduledoc """
  Marks a recorded cash payment that has participated in a deposit transfer.

  Once a payment is marked, its statement reports the `held_by_group` breakdown
  in addition to the earlier fields. The marker is permanent: it survives later
  settlements, reductions, chargebacks, and further transfers.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payment_transfers" do
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end
end
