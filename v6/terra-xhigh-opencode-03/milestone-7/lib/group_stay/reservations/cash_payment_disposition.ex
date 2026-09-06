defmodule GroupStay.Reservations.CashPaymentDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  @foreign_key_type :binary_id

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :disposition, :string
    field :amount_cents, :integer

    belongs_to :group, Group, foreign_key: :group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(cash_payment_disposition, attrs) do
    cash_payment_disposition
    |> cast(attrs, [:payment_operation_id, :group_db_id, :disposition, :amount_cents])
    |> validate_required([:payment_operation_id, :group_db_id, :disposition, :amount_cents])
    |> validate_inclusion(:disposition, ["refunded", "retained", "converted_to_credit"])
    |> validate_number(:amount_cents, greater_than: 0)
    |> unique_constraint([:payment_operation_id, :group_db_id, :disposition])
  end
end
