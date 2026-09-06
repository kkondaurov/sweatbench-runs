defmodule GroupStay.Groups.PaymentDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:payment_operation_id, :string, autogenerate: false}
  schema "payment_dispositions" do
    field :original_group_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transfer_participated, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents
             retained_cents converted_to_credit_cents reduced_cents charged_back_cents
             transfer_participated)a

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:recorded_cents, greater_than: 0)
    |> validate_number(:held_cents, greater_than_or_equal_to: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:reduced_cents, greater_than_or_equal_to: 0)
    |> validate_number(:charged_back_cents, greater_than_or_equal_to: 0)
    |> validate_required([:transfer_participated])
    |> unique_constraint(:payment_operation_id)
  end
end
