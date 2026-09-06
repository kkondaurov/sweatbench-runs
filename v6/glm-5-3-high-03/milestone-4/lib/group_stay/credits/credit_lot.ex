defmodule GroupStay.Credits.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest, for example when a refundable
  cancellation is settled as hotel credit instead of a cash refund.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, GroupStay.Credits.CreditApplication

    timestamps(type: :utc_datetime)
  end
end
