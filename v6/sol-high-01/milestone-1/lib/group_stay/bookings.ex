defmodule GroupStay.Bookings do
  @moduledoc """
  Applies partner operations and exposes the resulting group-deposit records.

  Each operation gets its own transaction so a rejection cannot leak partial state into the
  following operation. Operations in a batch are deliberately processed serially.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Bookings.{Group, Room}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @known_operations ~w(open_group record_cash_payment reschedule_group cancel_group)

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :error
      group -> {:ok, Repo.preload(group, rooms: from(room in Room, order_by: room.position))}
    end
  end

  def get_group(_group_id), do: :error

  def group_data(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  def ledger_data do
    Group
    |> Repo.all()
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn group, totals ->
        held = if group.status == "active", do: group.deposit_paid_cents, else: 0

        %{
          cash_held_cents: totals.cash_held_cents + held,
          cash_refunded_cents: totals.cash_refunded_cents + group.cash_refunded_cents,
          cash_retained_cents: totals.cash_retained_cents + group.cash_retained_cents
        }
      end
    )
  end

  defp apply_operation(operation) when not is_map(operation) do
    rejected(operation_id(operation), "invalid_operation")
  end

  defp apply_operation(operation) do
    type = Map.get(operation, "type")

    if type in @known_operations and structurally_complete?(type, operation) do
      transact(fn -> execute(type, operation) end)
    else
      rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp transact(fun) do
    case Repo.transaction(
           fn ->
             case fun.() do
               {:ok, result} -> result
               {:error, result} -> Repo.rollback(result)
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp execute("open_group", operation), do: open_group(operation)
  defp execute("record_cash_payment", operation), do: record_cash_payment(operation)
  defp execute("reschedule_group", operation), do: reschedule_group(operation)
  defp execute("cancel_group", operation), do: cancel_group(operation)

  defp open_group(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id guest_id property_id)),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], "invalid_stay"),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         :ok <- ensure_group_absent(operation["group_id"]) do
      nights = Date.diff(departure_on, arrival_on)

      lodging_total_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          total + nights * room.nightly_rate_cents
        end)

      deposit_due_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          lodging = nights * room.nightly_rate_cents
          total + room_deposit(lodging, operation["rate_plan"])
        end)

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        status: "active",
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        revision: 1
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          room_rows =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              %{
                group_id: group.group_id,
                position: position,
                room_id: room.room_id,
                nightly_rate_cents: room.nightly_rate_cents
              }
            end)

          {_count, nil} = Repo.insert_all(Room, room_rows)

          applied(operation, %{
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          })

        {:error, _changeset} ->
          domain_error(operation, "group_already_exists")
      end
    else
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- validate_amount(operation["amount_cents"]),
         :ok <- ensure_not_overpaid(group, operation["amount_cents"]) do
      amount = operation["amount_cents"]
      revision = group.revision + 1

      {:ok, group} =
        group
        |> change(deposit_paid_cents: group.deposit_paid_cents + amount, revision: revision)
        |> Repo.update()

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp reschedule_group(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay"),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"], "invalid_stay"),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      revision = group.revision + 1

      {:ok, group} =
        group
        |> change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: revision
        )
        |> Repo.update()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp cancel_group(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation") do
      {refunded, retained} = cancellation_settlement(group, occurred_on)
      revision = group.revision + 1

      {:ok, group} =
        group
        |> change(
          status: "cancelled",
          cash_refunded_cents: refunded,
          cash_retained_cents: retained,
          revision: revision
        )
        |> Repo.update()

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: group.cash_refunded_cents,
        retained_cents: group.cash_retained_cents,
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp structurally_complete?(type, operation) do
    required =
      case type do
        "open_group" ->
          ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

        "record_cash_payment" ->
          ~w(operation_id type occurred_on group_id amount_cents)

        "reschedule_group" ->
          ~w(operation_id type occurred_on group_id new_arrival_on)

        "cancel_group" ->
          ~w(operation_id type occurred_on group_id)
      end

    Enum.all?(required, &Map.has_key?(operation, &1)) and
      is_binary(operation["operation_id"])
  end

  defp validate_identifiers(operation, fields) do
    if Enum.all?(fields, fn field ->
         value = operation[field]
         is_binary(value) and value != ""
       end) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn room ->
        is_map(room) and is_binary(room["room_id"]) and room["room_id"] != "" and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0
      end)

    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid? and length(Enum.uniq(room_ids)) == length(room_ids) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount), do: {:error, "invalid_amount"}

  defp parse_date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, error_code}
    end
  end

  defp parse_date(_value, error_code), do: {:error, error_code}

  defp ensure_group_absent(group_id) do
    if Repo.get(Group, group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp fetch_group(operation) do
    case Repo.get(Group, operation["group_id"]) do
      nil -> domain_error(operation, "group_not_found")
      group -> {:ok, group}
    end
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       rejected(operation_id(operation), "stale_revision")
       |> Map.merge(%{
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       })}
    else
      :ok
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, "group_not_active"}

  defp ensure_not_overpaid(group, amount) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp room_deposit(lodging_cents, "flexible") do
    div(lodging_cents * 20 + 50, 100)
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp cancellation_settlement(group, occurred_on) do
    refundable? =
      group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    if refundable?,
      do: {group.deposit_paid_cents, 0},
      else: {0, group.deposit_paid_cents}
  end

  defp applied(operation, fields) do
    {:ok,
     fields
     |> Map.merge(%{operation_id: operation_id(operation), status: "applied"})}
  end

  defp domain_error(operation, code) do
    {:error, rejected(operation_id(operation), code)}
  end

  defp rejected(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: code}
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil
end
