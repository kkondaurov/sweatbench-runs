defmodule GroupStay.Credit.CreditLot do
  @moduledoc """
  One lot of hotel credit owned by a guest. The lot is available through
  `expires_on` and expires the following day. `remaining_cents` is the portion
  not currently funding a group; applications track the funded portion.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.CreditApplication

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer, default: 0

    has_many :applications, CreditApplication

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :expires_on, :remaining_cents])
    |> validate_required([:guest_id, :source_operation_id, :expires_on, :remaining_cents])
  end
end
