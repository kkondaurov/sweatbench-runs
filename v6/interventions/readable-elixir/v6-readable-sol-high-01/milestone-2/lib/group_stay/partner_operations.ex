defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner operations in order and isolates every operation in its own
  database transaction.

  An immediate SQLite transaction prevents two writers from both validating
  against the same revision. Rolling back with a rejection value gives each
  operation all-or-nothing behavior without rolling back earlier batch items.
  """

  alias GroupStay.{Credits, Repo}
  alias GroupStay.Reservations
  alias GroupStay.Reservations.{DepositPolicy, Group, Room}

  @rate_plans ~w(flexible advance_purchase)
  @group_operation_types ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group)

  @doc "Applies operations sequentially and returns one result for each input."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process/1)
  end

  defp process(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp process(%{"type" => type} = operation) when type in @group_operation_types do
    mutate_group(operation, type)
  end

  defp process(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with :ok <- require_identifiers(operation, ~w(operation_id group_id guest_id property_id)),
         :ok <-
           require_fields(
             operation,
             ~w(occurred_on arrival_on departure_on rate_plan rooms)
           ),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]) do
      transact(fn ->
        if Repo.get_by(Group, group_id: operation["group_id"]) do
          rollback(operation, "group_already_exists", group_id: operation["group_id"])
        else
          create_group(operation, booked_on)
        end
      end)
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp create_group(operation, booked_on) do
    with {:ok, arrival_on} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- required_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on, operation),
         :ok <- validate_rate_plan(operation),
         {:ok, rooms} <- validate_rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = lodging_total(rooms, nights)
      deposit_due = deposit_due(rooms, nights, operation["rate_plan"])

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: DepositPolicy.version(operation["rate_plan"], booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0
      }

      case %Group{} |> Group.open_changeset(attrs) |> Repo.insert() do
        {:ok, group} ->
          insert_rooms!(group, rooms)

          applied(operation,
            group_id: group.group_id,
            deposit_due_cents: deposit_due,
            revision: group.revision
          )

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            rollback(operation, "group_already_exists", group_id: operation["group_id"])
          else
            raise "could not persist a validated group: #{inspect(changeset.errors)}"
          end
      end
    end
  end

  defp mutate_group(operation, type) do
    with :ok <- require_identifiers(operation, ~w(operation_id group_id)),
         :ok <- require_fields(operation, required_fields(type)) do
      transact(fn ->
        case Repo.get_by(Group, group_id: operation["group_id"]) do
          nil ->
            rollback(operation, "group_not_found", group_id: operation["group_id"])

          group ->
            with :ok <- check_revision(operation, group),
                 {:ok, occurred_on} <-
                   required_date(operation, "occurred_on", "invalid_operation") do
              apply_group_operation(type, operation, group, occurred_on)
            end
        end
      end)
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp apply_group_operation(_type, operation, %Group{status: status}, _occurred_on)
       when status != "active" do
    rollback(operation, "group_not_active", group_id: operation["group_id"])
  end

  defp apply_group_operation("record_cash_payment", operation, group, _occurred_on) do
    amount = operation["amount_cents"]
    outstanding = Reservations.outstanding_deposit(group)

    cond do
      not (is_integer(amount) and amount > 0) ->
        rollback(operation, "invalid_amount", group_id: group.group_id)

      amount > outstanding ->
        rollback(operation, "payment_exceeds_outstanding", group_id: group.group_id)

      true ->
        group =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount,
            revision: group.revision + 1
          })

        applied(operation,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Reservations.outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp apply_group_operation("apply_hotel_credit", operation, group, occurred_on) do
    amount = operation["amount_cents"]
    outstanding = Reservations.outstanding_deposit(group)

    cond do
      not (is_integer(amount) and amount > 0) ->
        rollback(operation, "invalid_amount", group_id: group.group_id)

      amount > outstanding ->
        rollback(operation, "payment_exceeds_outstanding", group_id: group.group_id)

      Credits.available_balance(group.guest_id, occurred_on) < amount ->
        rollback(operation, "insufficient_credit", group_id: group.group_id)

      true ->
        :ok = Credits.allocate(group, amount, occurred_on)

        group =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            credit_paid_cents: group.credit_paid_cents + amount,
            revision: group.revision + 1
          })

        applied(operation,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Reservations.outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp apply_group_operation("reschedule_group", operation, group, occurred_on) do
    case required_date(operation, "new_arrival_on", "invalid_stay") do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          new_departure_on = Date.add(new_arrival_on, stay_length)

          group =
            update_group!(group, %{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            })

          applied(operation,
            group_id: group.group_id,
            new_arrival_on: new_arrival_on,
            new_departure_on: new_departure_on,
            policy_version: DepositPolicy.version(group),
            refundable_until: DepositPolicy.refundable_until(group),
            revision: group.revision
          )
        else
          rollback(operation, "invalid_stay", group_id: group.group_id)
        end

      _ ->
        rollback(operation, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_group_operation("cancel_group", operation, group, occurred_on) do
    refund_method = Map.get(operation, "refund_method", "cash")
    refundable = DepositPolicy.refundable?(group, occurred_on)

    cond do
      refund_method not in ~w(cash hotel_credit) ->
        rollback(operation, "invalid_operation", group_id: group.group_id)

      not refundable and refund_method == "hotel_credit" ->
        rollback(operation, "refund_method_not_available", group_id: group.group_id)

      refundable ->
        settle_refundable_cancellation(operation, group, occurred_on, refund_method)

      true ->
        settle_nonrefundable_cancellation(operation, group)
    end
  end

  defp settle_refundable_cancellation(operation, group, occurred_on, refund_method) do
    Credits.restore_allocations(group, occurred_on)

    {refunded, converted, credit_issued} =
      case refund_method do
        "cash" ->
          {group.cash_paid_cents, 0, 0}

        "hotel_credit" ->
          credit =
            Credits.issue_from_cash(
              group,
              operation["operation_id"],
              occurred_on,
              group.cash_paid_cents
            )

          {0, group.cash_paid_cents, credit}
      end

    group =
      update_group!(group, %{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: 0,
        cash_converted_to_credit_cents: converted,
        revision: group.revision + 1
      })

    cancellation_applied(operation, group, refunded, 0, credit_issued)
  end

  defp settle_nonrefundable_cancellation(operation, group) do
    Credits.consume_allocations(group)

    group =
      update_group!(group, %{
        status: "cancelled",
        refunded_cents: 0,
        retained_cents: group.cash_paid_cents,
        revision: group.revision + 1
      })

    cancellation_applied(operation, group, 0, group.cash_paid_cents, 0)
  end

  defp cancellation_applied(operation, group, refunded, retained, credit_issued) do
    applied(operation,
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: group.revision
    )
  end

  defp check_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when expected === group.revision ->
        :ok

      {:ok, expected} ->
        rollback(operation, "stale_revision",
          group_id: group.group_id,
          expected_revision: expected,
          actual_revision: group.revision
        )
    end
  end

  defp validate_stay(arrival_on, departure_on, operation) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      rollback(operation, "invalid_stay", group_id: operation["group_id"])
    end
  end

  defp validate_rate_plan(operation) do
    if operation["rate_plan"] in @rate_plans do
      :ok
    else
      rollback(operation, "invalid_rate_plan", group_id: operation["group_id"])
    end
  end

  defp validate_rooms(%{"rooms" => rooms} = operation) when is_list(rooms) and rooms != [] do
    normalized =
      Enum.with_index(rooms)
      |> Enum.reduce_while([], fn
        {%{"room_id" => room_id, "nightly_rate_cents" => rate}, position}, acc
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          {:cont, [%{room_id: room_id, nightly_rate_cents: rate, position: position} | acc]}

        _, _acc ->
          {:halt, :invalid}
      end)

    case normalized do
      :invalid ->
        rollback(operation, "invalid_rooms", group_id: operation["group_id"])

      rooms ->
        rooms = Enum.reverse(rooms)

        if Enum.uniq_by(rooms, & &1.room_id) == rooms do
          {:ok, rooms}
        else
          rollback(operation, "invalid_rooms", group_id: operation["group_id"])
        end
    end
  end

  defp validate_rooms(operation) do
    rollback(operation, "invalid_rooms", group_id: operation["group_id"])
  end

  defp deposit_due(rooms, nights, "advance_purchase") do
    lodging_total(rooms, nights)
  end

  defp deposit_due(rooms, nights, "flexible") do
    Enum.reduce(rooms, 0, fn room, total ->
      room_lodging = room.nightly_rate_cents * nights
      total + rounded_percentage(room_lodging, 20)
    end)
  end

  defp lodging_total(rooms, nights) do
    Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * nights + &2))
  end

  # Adding half the denominator before integer division implements nearest-cent
  # rounding with exact half cents rounded upward.
  defp rounded_percentage(cents, percentage) do
    div(cents * percentage + 50, 100)
  end

  defp insert_rooms!(group, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(rooms, fn room ->
        room
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:group_record_id, group.id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _} = Repo.insert_all(Room, entries)

    if count != length(entries), do: raise("not all rooms were persisted")
  end

  defp update_group!(group, attrs) do
    group
    |> Group.accounting_changeset(attrs)
    |> Repo.update!()
  end

  defp required_date(operation, field, error_code) do
    case parse_date(operation[field]) do
      {:ok, date} ->
        {:ok, date}

      :error ->
        rollback(operation, error_code, group_id: operation["group_id"])
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp require_identifiers(operation, fields) do
    if Enum.all?(fields, fn field ->
         case operation[field] do
           value when is_binary(value) -> String.trim(value) != ""
           _ -> false
         end
       end) do
      :ok
    else
      :error
    end
  end

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)), do: :ok, else: :error
  end

  defp required_fields("record_cash_payment"), do: ~w(occurred_on amount_cents)
  defp required_fields("apply_hotel_credit"), do: ~w(occurred_on amount_cents)
  defp required_fields("reschedule_group"), do: ~w(occurred_on new_arrival_on)
  defp required_fields("cancel_group"), do: ~w(occurred_on)

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation["operation_id"], status: "applied"})
  end

  defp reject(operation, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{
      operation_id: operation_id(operation),
      status: "rejected",
      code: code
    })
  end

  defp rollback(operation, code, fields) do
    Repo.rollback(reject(operation, code, fields))
  end

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_operation), do: nil
end
