defmodule GroupStay.Bookings do
  @moduledoc """
  Reads for group reservations.

  Group totals describe active rooms only: cancelled rooms no longer require a
  deposit and their funding has been settled.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Policy
  alias GroupStay.Bookings.Room
  alias GroupStay.Finance.Allocations
  alias GroupStay.Repo

  @empty_paid %{cash: 0, credit: 0}

  @doc """
  Finds a group by its partner-supplied identifier, with rooms in their
  original order. Returns nil when the group does not exist.
  """
  def get_group(group_id) do
    Repo.one(from g in Group, where: g.group_id == ^group_id, preload: [:rooms])
  end

  @doc """
  The group's lodging, deposit, and payment totals over its active rooms.
  """
  def group_totals(%Group{} = group) do
    paid = Allocations.paid_by_room(group.id)
    active_rooms = active_rooms(group)

    cash_paid_cents = sum_over(active_rooms, &Map.get(paid, &1.id, @empty_paid).cash)
    credit_paid_cents = sum_over(active_rooms, &Map.get(paid, &1.id, @empty_paid).credit)

    deposit_due_cents = sum_over(active_rooms, & &1.deposit_cents)

    %{
      lodging_total_cents: sum_over(active_rooms, & &1.lodging_amount_cents),
      deposit_due_cents: deposit_due_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      outstanding_deposit_cents: max(deposit_due_cents - cash_paid_cents - credit_paid_cents, 0)
    }
  end

  @doc """
  The API representation of a group, including per-room accounting fields.
  """
  def group_payload(%Group{} = group) do
    totals = group_totals(group)
    paid = Allocations.paid_by_room(group.id)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "policy_version" => Policy.version_for(group),
      "refundable_until" => group |> Policy.refundable_until() |> maybe_date_to_iso8601(),
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          room_payload(room, Map.get(paid, room.id, %{cash: 0, credit: 0}))
        end),
      "lodging_total_cents" => totals.lodging_total_cents,
      "deposit_due_cents" => totals.deposit_due_cents,
      "deposit_paid_cents" => totals.deposit_paid_cents,
      "cash_paid_cents" => totals.cash_paid_cents,
      "credit_paid_cents" => totals.credit_paid_cents,
      "outstanding_deposit_cents" => totals.outstanding_deposit_cents
    }
  end

  defp room_payload(room, paid) do
    active? = Room.active?(room)

    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "deposit_due_cents" => if(active?, do: room.deposit_cents, else: 0),
      "cash_paid_cents" => if(active?, do: paid.cash, else: 0),
      "credit_paid_cents" => if(active?, do: paid.credit, else: 0)
    }
  end

  defp active_rooms(%Group{} = group), do: Enum.filter(group.rooms, &Room.active?/1)

  defp sum_over(rooms, fun), do: rooms |> Enum.map(fun) |> Enum.sum()

  defp maybe_date_to_iso8601(nil), do: nil
  defp maybe_date_to_iso8601(date), do: Date.to_iso8601(date)
end
