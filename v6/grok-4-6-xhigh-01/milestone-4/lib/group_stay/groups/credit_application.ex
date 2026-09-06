defmodule GroupStay.Groups.CreditApplication do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :group_id, :string
    field :room_id, :string
    field :source_operation_id, :string
    field :amount_cents, :integer
    field :status, :string
    field :fill_seq, :integer

    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [
      :group_id,
      :room_id,
      :source_operation_id,
      :credit_lot_id,
      :amount_cents,
      :status,
      :fill_seq
    ])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents, :status])
  end
end
