defmodule GroupStay.Groups.PaymentSettlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "payment_settlements" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :disposition, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields ~w(payment_operation_id group_id disposition amount_cents)a

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:disposition, ["refunded", "retained", "converted_to_credit"])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
