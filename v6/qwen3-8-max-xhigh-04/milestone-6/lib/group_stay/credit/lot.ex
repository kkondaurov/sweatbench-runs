defmodule GroupStay.Credit.Lot do
  @moduledoc """
  A lot of hotel credit issued to a guest, funded by the cash portion of a
  refundable cancellation.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :initial_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
