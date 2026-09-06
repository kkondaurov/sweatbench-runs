defmodule GroupStay.Groups.CashPaymentDisposition do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashPayment, Group}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cash_payment_dispositions" do
    belongs_to :cash_payment, CashPayment, type: :binary_id
    belongs_to :group, Group, foreign_key: :reservation_id, type: :binary_id
    field :kind, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:cash_payment_id, :reservation_id, :kind, :amount_cents])
    |> validate_required([:cash_payment_id, :reservation_id, :kind, :amount_cents])
    |> validate_inclusion(:kind, ["refunded", "retained", "converted"])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
