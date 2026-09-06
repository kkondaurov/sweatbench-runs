defmodule GroupStay.Groups.CashPaymentDisposition do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payment_dispositions" do
    belongs_to :reservation, Group
    belongs_to :credit_lot, CreditLot
    field :payment_operation_id, :string
    field :kind, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:reservation_id, :credit_lot_id, :payment_operation_id, :kind, :amount_cents],
      empty_values: []
    )
    |> validate_required([:reservation_id, :payment_operation_id, :kind, :amount_cents])
    |> validate_inclusion(:kind, ["refunded", "retained", "converted", "reduced", "charged_back"])
    |> validate_number(:amount_cents, greater_than: 0)
  end

  def update_changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:kind])
    |> validate_inclusion(:kind, ["charged_back"])
  end
end
