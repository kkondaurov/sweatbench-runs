defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued by a refundable cancellation. `available_cents`
  is the portion not currently applied to a group. The lot is available through
  `expires_on` and expires the following day.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :available_cents, :integer
    field :expires_on, :date

    has_many :applications, GroupStay.Groups.CreditApplication, foreign_key: :lot_id

    timestamps()
  end
end
