defmodule GroupStay.Groups.CashFunding do
  @moduledoc """
  One source of cash applied to a group's deposit: a durably recorded cash
  payment (`operation_id` set), or the unattributed senior block that brings
  funding from before durable operation records forward (`operation_id` nil).

  The disposition columns partition `amount_cents` exactly: every recorded
  cent is held, refunded, retained, converted to hotel credit, reduced, or
  charged back. `held_cents` always equals the sum of the funding's held room
  allocations.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{Group, RoomFunding}

  @dispositions [
    :held_cents,
    :refunded_cents,
    :retained_cents,
    :converted_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  schema "cash_fundings" do
    field :operation_id, :string
    field :amount_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transferred, :boolean, default: false

    belongs_to :group, Group, type: :binary_id
    has_many :room_fundings, RoomFunding

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(cash_funding, attrs) do
    cash_funding
    |> cast(attrs, [:group_id, :operation_id, :amount_cents, :transferred] ++ @dispositions)
    |> validate_required([:group_id, :amount_cents] ++ @dispositions)
    |> validate_dispositions_partition()
    |> unique_constraint(:operation_id)
    |> assoc_constraint(:group)
  end

  # Every recorded cent is accounted for by exactly one disposition.
  defp validate_dispositions_partition(changeset) do
    amount_cents = get_field(changeset, :amount_cents)

    disbursed =
      Enum.sum(for field <- @dispositions, do: get_field(changeset, field) || 0)

    if is_integer(amount_cents) and disbursed == amount_cents do
      changeset
    else
      add_error(changeset, :amount_cents, "is not fully accounted for by its dispositions")
    end
  end
end
