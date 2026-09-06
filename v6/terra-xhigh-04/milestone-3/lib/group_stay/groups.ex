defmodule GroupStay.Groups do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{Credits, Repo}
  alias GroupStay.Groups.{Group, Room}

  @active "active"
  @cancelled "cancelled"

  def get(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :error
      group -> {:ok, preload_rooms(group)}
    end
  end

  def get(_group_id), do: :error

  def create(attrs, rooms) do
    with {:ok, group} <-
           %Group{}
           |> Ecto.Changeset.cast(attrs, [
             :group_id,
             :guest_id,
             :property_id,
             :booked_on,
             :arrival_on,
             :departure_on,
             :rate_plan,
             :policy_version,
             :lodging_total_cents,
             :deposit_due_cents,
             :deposit_paid_cents,
             :cash_paid_cents,
             :credit_paid_cents,
             :refunded_cents,
             :retained_cents,
             :cash_converted_to_credit_cents
           ])
           |> Ecto.Changeset.put_change(:status, @active)
           |> Ecto.Changeset.put_change(:revision, 1)
           |> Ecto.Changeset.unique_constraint(:group_id)
           |> Repo.insert() do
      rooms
      |> Enum.with_index()
      |> Enum.each(fn {room, position} ->
        %Room{}
        |> Ecto.Changeset.cast(
          Map.merge(room, %{group_id: group.id, position: position}),
          [:group_id, :room_id, :nightly_rate_cents, :position]
        )
        |> Repo.insert!()
      end)

      {:ok, preload_rooms(group)}
    end
  end

  def update(group, attrs) do
    group
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.optimistic_lock(:revision)
    |> Repo.update(stale_error_field: :revision)
    |> case do
      {:ok, updated_group} -> {:ok, preload_rooms(updated_group)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def ledger_totals(on \\ Date.utc_today()) do
    %{
      cash_held_cents: sum_for(@active, :cash_paid_cents),
      cash_refunded_cents: sum_for(@cancelled, :refunded_cents),
      cash_retained_cents: sum_for(@cancelled, :retained_cents),
      cash_converted_to_credit_cents: sum_for(@cancelled, :cash_converted_to_credit_cents),
      credit_liability_cents: Credits.liability_cents(on)
    }
  end

  def serialize(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: max(group.deposit_due_cents - group.deposit_paid_cents, 0)
    }
  end

  defp preload_rooms(group) do
    rooms = from(room in Room, order_by: [asc: room.position])
    Repo.preload(group, rooms: rooms)
  end

  defp sum_for(status, field) do
    Repo.one(
      from(group in Group,
        where: group.status == ^status,
        select: coalesce(sum(field(group, ^field)), 0)
      )
    )
  end

  defp policy_version(%{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(group) do
    if group.rate_plan == "advance_purchase" or
         Date.compare(group.booked_on, ~D[2027-01-01]) == :lt,
       do:
         if(group.rate_plan == "advance_purchase", do: "advance-nonrefundable", else: "flex-14"),
       else: "flex-30"
  end

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> group.arrival_on |> Date.add(-14) |> Date.to_iso8601()
      "flex-30" -> group.arrival_on |> Date.add(-30) |> Date.to_iso8601()
      "advance-nonrefundable" -> nil
    end
  end
end
