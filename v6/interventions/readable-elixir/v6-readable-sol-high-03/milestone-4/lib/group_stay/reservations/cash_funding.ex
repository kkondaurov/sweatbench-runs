defmodule GroupStay.Reservations.CashFunding do
  @moduledoc """
  The complete, current disposition of one recorded cash payment.

  A funding without a payment operation identifier is the senior legacy block
  reconstructed when room accounting was introduced. Its seven amount columns
  form a conservation equation: every recorded cent has exactly one current
  disposition.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{CashAllocation, CreditEntitlement, Group}

  schema "cash_fundings" do
    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    field :payment_operation_id, :string
    field :funding_order, :integer
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    has_many :allocations, CashAllocation
    has_many :credit_entitlements, CreditEntitlement

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    group_id payment_operation_id funding_order recorded_cents held_cents
    refunded_cents retained_cents converted_to_credit_cents reduced_cents
    charged_back_cents
  )a

  def changeset(funding, attributes) do
    funding
    |> cast(attributes, @fields)
    |> validate_required([:group_id, :funding_order, :recorded_cents])
    |> validate_number(:recorded_cents, greater_than: 0)
    |> validate_amounts()
    |> unique_constraint(:payment_operation_id)
  end

  def disposition_changeset(funding, attributes) do
    funding
    |> cast(
      attributes,
      @fields -- [:group_id, :payment_operation_id, :funding_order, :recorded_cents]
    )
    |> validate_amounts()
  end

  defp validate_amounts(changeset) do
    Enum.reduce(
      ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a,
      changeset,
      &validate_number(&2, &1, greater_than_or_equal_to: 0)
    )
  end
end
