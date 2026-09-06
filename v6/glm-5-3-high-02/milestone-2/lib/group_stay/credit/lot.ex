defmodule GroupStay.Credit.Lot do
  @moduledoc """
  A lot of hotel credit issued to a guest.

  A lot is issued by a refundable cancellation settled in hotel credit and
  is worth 110% of the cash it replaces. It is spendable through the day
  before `expires_on` and expired from `expires_on` onward.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :applications, GroupStay.Credit.Application

    timestamps()
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than: 0)
  end
end
