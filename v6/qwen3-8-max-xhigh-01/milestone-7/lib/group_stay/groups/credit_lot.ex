defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest, funded by a refundable cancellation.

  A lot is available through the day before `expires_on` and expires on that
  date. Exhausted lots remain on record because amounts applied to a group can
  be restored to them if that group is later cancelled while refundable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    belongs_to :group, Group
    has_many :credit_applications, CreditApplication, foreign_key: :lot_id

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :issued_cents,
      :remaining_cents,
      :issued_on,
      :expires_on,
      :unrecovered_clawback_cents,
      :group_id
    ])
    |> validate_required([:guest_id, :issued_cents, :remaining_cents, :issued_on, :expires_on])
  end
end
