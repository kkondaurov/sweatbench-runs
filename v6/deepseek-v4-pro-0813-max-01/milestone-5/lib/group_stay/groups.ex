defmodule GroupStay.Groups do
  @moduledoc """
  Reads deposits groups and finance totals from the data layer.
  """

  alias GroupStay.{Credit, Group, Repo, Room, RoomAllocation}

  import Ecto.Query

  @doc """
  Fetches a group by its partner-supplied identifier, with rooms ordered as
  submitted and any hotel credit applications attached.
  """
  @spec fetch(String.t()) :: Group.t() | nil
  def fetch(group_id) when is_binary(group_id) do
    from(g in Group,
      where: g.group_id == ^group_id,
      preload: [
        rooms: ^from(r in Room, order_by: r.position),
        credit_applications: :lot
      ]
    )
    |> Repo.one()
  end

  @doc """
  The group payload returned by the read endpoint. Group totals describe
  active rooms only; cancelled rooms report their status and zeroed funding.
  """
  @spec to_response(Group.t()) :: map()
  def to_response(%Group{} = group) do
    room_payments = room_allocation_sums(group.id)
    active_rooms = Enum.filter(group.rooms, &(&1.status == "active"))

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => group.booked_on,
      "arrival_on" => group.arrival_on,
      "departure_on" => group.departure_on,
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "revision" => group.revision,
      "rooms" => Enum.map(group.rooms, &room_response(&1, room_payments)),
      "lodging_total_cents" => active_rooms |> Enum.map(& &1.lodging_cents) |> Enum.sum(),
      "deposit_due_cents" => active_rooms |> Enum.map(& &1.deposit_cents) |> Enum.sum(),
      "deposit_paid_cents" => paid_cents(active_rooms, room_payments),
      "cash_paid_cents" => paid_cents(active_rooms, room_payments, "cash"),
      "credit_paid_cents" => paid_cents(active_rooms, room_payments, "credit"),
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  @doc """
  The cancellation window in days fixed by a group's policy version, or
  `nil` when the rate plan is non-refundable.
  """
  @spec cancellation_window(String.t() | nil) :: non_neg_integer() | nil
  def cancellation_window("flex-14"), do: 14
  def cancellation_window("flex-30"), do: 30
  def cancellation_window(_), do: nil

  @doc """
  The last calendar date on which a flexible cancellation is refundable,
  or `nil` for advance purchase.
  """
  @spec refundable_until(Group.t()) :: Date.t() | nil
  def refundable_until(%Group{} = group) do
    case cancellation_window(group.policy_version) do
      nil -> nil
      window -> Date.add(group.arrival_on, -window)
    end
  end

  @doc """
  Cash and credit finance totals, with credit expiry reported as of `on`.
  """
  @spec ledger(Date.t()) :: map()
  def ledger(on \\ Date.utc_today()) do
    %{
      "cash_held_cents" => cash_sum(:cash_paid_cents, "active"),
      "cash_refunded_cents" => column_sum(:refunded_cents),
      "cash_retained_cents" => column_sum(:retained_cents),
      "cash_converted_to_credit_cents" => column_sum(:cash_converted_to_credit_cents),
      "cash_reduced_cents" => column_sum(:cash_reduced_cents),
      "cash_charged_back_cents" => column_sum(:cash_charged_back_cents),
      "credit_liability_cents" => Credit.liability(on),
      "credit_shortfall_cents" => Credit.shortfall()
    }
  end

  @doc """
  The deposit still required from an active group: active rooms' deposit
  requirements minus what is still allocated to those rooms.
  """
  @spec outstanding_deposit_cents(Group.t()) :: non_neg_integer()
  def outstanding_deposit_cents(%Group{} = group) do
    active_rooms = Enum.filter(group.rooms, &(&1.status == "active"))

    max(
      Enum.sum(Enum.map(active_rooms, & &1.deposit_cents)) -
        paid_cents(active_rooms, room_allocation_sums(group.id)),
      0
    )
  end

  @doc """
  The current sums of cash and credit allocations per room.
  """
  @spec room_allocation_sums(term()) :: map()
  def room_allocation_sums(group_id) do
    from(a in RoomAllocation,
      where: a.group_id == ^group_id,
      group_by: [a.room_id, a.kind],
      select: {a.room_id, a.kind, type(sum(a.amount_cents), :integer)}
    )
    |> Repo.all()
    |> Enum.group_by(fn {room_id, _kind, _amount} -> room_id end, fn {_room_id, kind, amount} ->
      {kind, amount}
    end)
    |> Map.new(fn {room_id, pairs} -> {room_id, Map.new(pairs)} end)
  end

  defp paid_cents(rooms, room_payments, kind \\ nil) do
    rooms
    |> Enum.map(fn room ->
      payments = Map.get(room_payments, room.id, %{})

      if kind do
        Map.get(payments, kind, 0)
      else
        Map.get(payments, "cash", 0) + Map.get(payments, "credit", 0)
      end
    end)
    |> Enum.sum()
  end

  defp room_response(%Room{status: "active"} = room, room_payments) do
    payments = Map.get(room_payments, room.id, %{})

    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => "active",
      "deposit_due_cents" => room.deposit_cents,
      "cash_paid_cents" => Map.get(payments, "cash", 0),
      "credit_paid_cents" => Map.get(payments, "credit", 0)
    }
  end

  defp room_response(%Room{} = room, _room_payments) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => "cancelled",
      "deposit_due_cents" => 0,
      "cash_paid_cents" => 0,
      "credit_paid_cents" => 0
    }
  end

  defp cash_sum(field, status) do
    from(g in Group,
      where: g.status == ^status,
      select: type(coalesce(sum(field(g, ^field)), 0), :integer)
    )
    |> Repo.one()
  end

  defp column_sum(field) do
    from(g in Group, select: type(coalesce(sum(field(g, ^field)), 0), :integer))
    |> Repo.one()
  end
end
