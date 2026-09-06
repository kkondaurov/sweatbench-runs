defmodule GroupStay.Reservations.PaymentCashDisposition do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "payment_cash_dispositions" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :charged_back, :boolean, default: false
    field :transferred, :boolean, default: false

    belongs_to :group, Group, foreign_key: :group_pk_id

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    group_pk_id
    payment_operation_id
    recorded_cents
    refunded_cents
    retained_cents
    converted_to_credit_cents
    reduced_cents
    charged_back_cents
    charged_back
    transferred
  )a

  @required_fields ~w(
    group_pk_id
    payment_operation_id
    recorded_cents
    refunded_cents
    retained_cents
    converted_to_credit_cents
    reduced_cents
    charged_back_cents
    charged_back
    transferred
  )a

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_number(:recorded_cents, greater_than: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:reduced_cents, greater_than_or_equal_to: 0)
    |> validate_number(:charged_back_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:group_pk_id)
    |> unique_constraint(:payment_operation_id)
  end
end
