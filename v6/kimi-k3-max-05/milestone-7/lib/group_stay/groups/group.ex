defmodule GroupStay.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :policy_version, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, GroupStay.Groups.Room, preload_order: [asc: :position]
    has_many :credit_applications, GroupStay.Credits.CreditApplication

    timestamps(type: :utc_datetime)
  end

  def open_changeset(attrs, rooms) do
    room_assocs =
      Enum.map(rooms, fn room ->
        %GroupStay.Groups.Room{
          position: room["position"],
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          lodging_total_cents: room["lodging_total_cents"],
          deposit_due_cents: room["deposit_due_cents"]
        }
      end)

    %__MODULE__{}
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :rate_plan,
      :status,
      :booked_on,
      :arrival_on,
      :departure_on,
      :policy_version,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :rate_plan,
      :booked_on,
      :arrival_on,
      :departure_on,
      :policy_version,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> put_assoc(:rooms, room_assocs)
    |> unique_constraint(:group_id)
  end

  def payment_changeset(group, amount) do
    group
    |> change()
    |> put_change(:deposit_paid_cents, group.deposit_paid_cents + amount)
    |> put_change(:cash_paid_cents, group.cash_paid_cents + amount)
    |> put_change(:revision, group.revision + 1)
  end

  def credit_changeset(group, amount) do
    group
    |> change()
    |> put_change(:deposit_paid_cents, group.deposit_paid_cents + amount)
    |> put_change(:credit_paid_cents, group.credit_paid_cents + amount)
    |> put_change(:revision, group.revision + 1)
  end

  def reschedule_changeset(group, new_arrival, new_departure) do
    group
    |> change()
    |> put_change(:arrival_on, new_arrival)
    |> put_change(:departure_on, new_departure)
    |> put_change(:revision, group.revision + 1)
  end

  # Records a settlement of `cash` and `credit` cents from cancelled rooms:
  # the paid amounts leave the active totals, the cash disposition
  # accumulates, and the group is cancelled when no active rooms remain.
  def settle_changeset(group, settlement) do
    group
    |> change()
    |> put_change(:deposit_paid_cents, group.deposit_paid_cents - settlement.paid_cents)
    |> put_change(:cash_paid_cents, group.cash_paid_cents - settlement.cash_cents)
    |> put_change(:credit_paid_cents, group.credit_paid_cents - settlement.credit_cents)
    |> put_change(:refunded_cents, group.refunded_cents + settlement.refunded_cents)
    |> put_change(:retained_cents, group.retained_cents + settlement.retained_cents)
    |> put_change(
      :cash_converted_to_credit_cents,
      group.cash_converted_to_credit_cents + settlement.converted_cents
    )
    |> put_change(:status, if(settlement.cancelled?, do: "cancelled", else: group.status))
    |> put_change(:revision, group.revision + 1)
  end

  # Reopens outstanding deposit when held cash is reduced or charged back.
  def reopen_changeset(group, cash_cents) do
    group
    |> change()
    |> put_change(:deposit_paid_cents, group.deposit_paid_cents - cash_cents)
    |> put_change(:cash_paid_cents, group.cash_paid_cents - cash_cents)
    |> put_change(:revision, group.revision + 1)
  end

  # Applies a deposit transfer to one side: negative deltas for the source,
  # positive for the destination. Only the paid totals and the revision move.
  def transfer_changeset(group, cash_delta, credit_delta) do
    group
    |> change()
    |> put_change(
      :deposit_paid_cents,
      group.deposit_paid_cents + cash_delta + credit_delta
    )
    |> put_change(:cash_paid_cents, group.cash_paid_cents + cash_delta)
    |> put_change(:credit_paid_cents, group.credit_paid_cents + credit_delta)
    |> put_change(:revision, group.revision + 1)
  end
end
