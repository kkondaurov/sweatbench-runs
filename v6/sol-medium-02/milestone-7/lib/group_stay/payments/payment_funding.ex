defmodule GroupStay.Payments.PaymentFunding do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Group
  alias GroupStay.PartnerOperation

  schema "payment_fundings" do
    belongs_to :partner_operation, PartnerOperation
    belongs_to :group, Group
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, [
      :partner_operation_id,
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([
      :partner_operation_id,
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_number(:recorded_cents, greater_than: 0)
    |> validate_non_negative_dispositions()
    |> unique_constraint(:partner_operation_id)
  end

  defp validate_non_negative_dispositions(changeset) do
    Enum.reduce(
      ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a,
      changeset,
      &validate_number(&2, &1, greater_than_or_equal_to: 0)
    )
  end
end
