defmodule GroupStay.Deposits.CashPayment do
  @moduledoc "Current accounting dispositions for one durably applied cash payment."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.Group

  schema "cash_payments" do
    field :operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transfer_participated, :boolean, default: false

    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end

  @fields ~w(operation_id group_record_id recorded_cents refunded_cents retained_cents
             converted_to_credit_cents reduced_cents charged_back_cents transfer_participated)a

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:operation_id)
  end
end
