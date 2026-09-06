defmodule GroupStay.Groups do
  @moduledoc """
  The Groups context owns group reservations: opening them, recording cash
  against their deposits, rescheduling their stays, and cancelling them, as
  well as the finance totals derived from those records.

  Partner operations are applied one at a time, each in its own transaction,
  so a rejected operation leaves the database exactly as it was before the
  operation began and never stops later operations in the same batch.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @refund_window_days 14

  ## Reads

  @doc """
  Fetches a group by its partner-supplied `group_id`, with rooms in their
  original order. Returns `:error` when no such group exists.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :error
      %Group{} = group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_group_id), do: :error

  @doc """
  Finance totals across all groups: cash held against active reservations and
  cash refunded or retained through cancellations. Unpaid deposit requirements
  never appear in these totals.
  """
  def ledger_totals do
    %{
      cash_held_cents: ledger_sum("active", :deposit_paid_cents),
      cash_refunded_cents: ledger_sum("cancelled", :refunded_cents),
      cash_retained_cents: ledger_sum("cancelled", :retained_cents)
    }
  end

  defp ledger_sum(status, field) do
    Repo.one(
      from g in Group,
        where: g.status == ^status,
        select: coalesce(sum(field(g, ^field)), 0)
    )
  end

  ## Partner operations

  @doc """
  Applies partner operations in array order and returns one result map per
  operation, in the same order. An operation can observe changes made by
  earlier operations in the same batch; a rejected operation changes nothing.
  """
  def apply_operations(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(operation) do
    case Repo.transact(fn -> do_apply(operation) end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp do_apply(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp do_apply(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp do_apply(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)

  defp do_apply(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp do_apply(operation) when is_map(operation), do: rejected(operation, "invalid_operation")

  defp do_apply(_operation), do: rejected(%{}, "invalid_operation")

  ## open_group

  defp open_group(operation) do
    with :ok <- require_fields(operation, ["group_id", "guest_id", "property_id"]),
         {:ok, booked_on} <- fetch_occurred_on(operation),
         :ok <- ensure_group_absent(Map.get(operation, "group_id")),
         {:ok, arrival_on, departure_on} <- stay_dates(operation),
         {:ok, rooms} <- valid_rooms(Map.get(operation, "rooms")),
         :ok <- valid_rate_plan(Map.get(operation, "rate_plan")) do
      create_group(operation, booked_on, arrival_on, departure_on, rooms)
    else
      error -> rejection_for(operation, error)
    end
  end

  defp create_group(operation, booked_on, arrival_on, departure_on, rooms) do
    rate_plan = Map.get(operation, "rate_plan")
    nights = Date.diff(departure_on, arrival_on)

    room_attrs =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          room_id: Map.get(room, "room_id"),
          nightly_rate_cents: Map.get(room, "nightly_rate_cents"),
          position: position
        }
      end)

    lodging_total_cents =
      Enum.sum(for room <- room_attrs, do: nights * room.nightly_rate_cents)

    deposit_due_cents =
      Enum.sum(
        for room <- room_attrs,
            do: room_deposit(rate_plan, nights * room.nightly_rate_cents)
      )

    attrs = %{
      group_id: Map.get(operation, "group_id"),
      guest_id: Map.get(operation, "guest_id"),
      property_id: Map.get(operation, "property_id"),
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      rooms: room_attrs
    }

    case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
      {:ok, group} ->
        applied(operation, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, %Changeset{}} ->
        rejected(operation, "group_already_exists")
    end
  end

  # A flexible room requires 20% of its lodging amount as deposit, rounded to
  # the nearest cent with an exact half-cent rounding upward. An
  # advance-purchase room requires its full lodging amount.
  defp room_deposit("flexible", lodging_cents), do: div(lodging_cents * 20 + 50, 100)
  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  ## record_cash_payment

  defp record_cash_payment(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- payment_amount(Map.get(operation, "amount_cents")),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      deposit_paid_cents = group.deposit_paid_cents + amount_cents
      group = update_group!(group, %{deposit_paid_cents: deposit_paid_cents})

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: group.deposit_due_cents - deposit_paid_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  defp payment_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp payment_amount(_amount_cents), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  ## reschedule_group

  defp reschedule_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, new_arrival_on} <- new_arrival(operation, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      group = update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_string(group.arrival_on),
        new_departure_on: Date.to_string(group.departure_on),
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  defp new_arrival(operation, occurred_on) do
    case parse_date(Map.get(operation, "new_arrival_on")) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:error, "invalid_stay"}
        end

      :error ->
        {:error, "invalid_stay"}
    end
  end

  ## cancel_group

  defp cancel_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation) do
      {refunded_cents, retained_cents} = settlement(group, occurred_on)

      group =
        update_group!(group, %{
          status: "cancelled",
          refunded_cents: refunded_cents,
          retained_cents: retained_cents
        })

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: group.refunded_cents,
        retained_cents: group.retained_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  # Flexible stays cancelled at least @refund_window_days before arrival are
  # refundable; everything else is non-refundable. Only cash actually paid is
  # refunded or retained; unpaid deposit is simply no longer due.
  defp settlement(group, occurred_on) do
    if group.rate_plan == "flexible" and
         Date.diff(group.arrival_on, occurred_on) >= @refund_window_days do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  ## Shared validation and persistence

  defp fetch_group(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, "group_not_found"}
          %Group{} = group -> {:ok, group}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  # Group existence is resolved before revisions are compared, and a stale
  # revision is rejected before any other domain rule is evaluated.
  defp check_revision(operation, group) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected_revision ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, "stale_revision",
           %{expected_revision: expected_revision, actual_revision: group.revision}}
        end
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:error, "group_not_active"}

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &is_binary(Map.get(operation, &1))) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp fetch_occurred_on(operation) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, occurred_on} -> {:ok, occurred_on}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp stay_dates(operation) do
    with {:ok, arrival_on} <- parse_date(Map.get(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(Map.get(operation, "departure_on")),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on}
    else
      _other -> {:error, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp valid_room?(room) do
    is_map(room) and is_binary(Map.get(room, "room_id")) and
      is_integer(Map.get(room, "nightly_rate_cents")) and
      Map.get(room, "nightly_rate_cents") >= 0
  end

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  # Every applied operation addressed to a group increments its revision
  # exactly once, even when no booking field visibly changes.
  defp update_group!(group, attrs) do
    group
    |> Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  ## Operation results

  defp applied(operation, fields) do
    result =
      Map.merge(
        %{operation_id: Map.get(operation, "operation_id"), status: "applied"},
        fields
      )

    {:ok, result}
  end

  defp rejection_for(operation, {:error, code}), do: rejected(operation, code)

  defp rejection_for(operation, {:error, code, extra}),
    do: rejected(operation, code, extra)

  defp rejected(operation, code, extra \\ %{}) do
    result = %{
      operation_id: Map.get(operation, "operation_id"),
      status: "rejected",
      code: code
    }

    result =
      case Map.get(operation, "group_id") do
        group_id when is_binary(group_id) -> Map.put(result, :group_id, group_id)
        _other -> result
      end

    {:error, Map.merge(result, extra)}
  end
end
