defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest by a refundable cancellation. The
  lot is usable through its `expires_on` date and expires the following day.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.CreditApplication

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :original_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, CreditApplication

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(credit_lot, attrs) do
    credit_lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :original_cents,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> validate_required([:guest_id, :original_cents, :remaining_cents, :expires_on])
  end
end
