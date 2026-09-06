defmodule GroupStay.Reservations do
  @moduledoc "Applies ordered partner operations and reads reservation accounting."
  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo}

  @updates ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group)
  @public_fields ~w(group_id guest_id property_id revision booked_on arrival_on departure_on rate_plan policy_version cash_paid_cents credit_paid_cents status rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a
  @max_cents 9_223_372_036_854_775_807

  def apply_batch(operations), do: Enum.map(operations, &apply_operation/1)

  def get_operation(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def ledger(on \\ Date.utc_today()) do
    # Both totals must observe the same snapshot when another request redeems credit.
    {:ok, totals} =
      Repo.transaction(fn ->
        cash =
          Repo.one(
            from g in Group,
              select: %{
                cash_held_cents: coalesce(sum(g.cash_paid_cents), 0),
                cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
                cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
                cash_converted_to_credit_cents:
                  coalesce(sum(g.cash_converted_to_credit_cents), 0),
                credit_liability_cents: coalesce(sum(g.credit_paid_cents), 0)
              }
          )

        available =
          Repo.one(
            from l in CreditLot,
              where: l.expires_on >= ^on,
              select: coalesce(sum(l.remaining_cents), 0)
          )

        Map.update!(cash, :credit_liability_cents, &(&1 + available))
      end)

    totals
  end

  defp available_lots(guest_id, on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end

  defp apply_operation(operation) do
    # Acquire the write lock before looking up the durable record or domain state.
    # Concurrent retries observe the first committed result, including rejections.
    {:ok, result} = operation_transaction(operation)

    # Keep the context's atom-keyed result interface. Only server-defined top-level
    # keys are converted; arbitrary submitted stale-revision values stay JSON data.
    Map.new(result, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp operation_transaction(operation, attempt \\ 0) do
    Repo.transaction(fn -> remember_operation(operation) end, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      # A busy BEGIN has not run the operation. Retry only this known-safe case;
      # errors during writes or COMMIT must never replay a possible payment.
      if error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           error.message == "database is locked" and attempt < 5 do
        Process.sleep(10 * Integer.pow(2, attempt))
        operation_transaction(operation, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp remember_operation(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    if identifier?(operation_id) do
      case Repo.get_by(Operation, operation_id: operation_id) do
        nil ->
          result = operation_result(operation, operation_id)

          Repo.insert!(%Operation{
            operation_id: operation_id,
            submission: operation,
            result: result
          })

          result

        %Operation{submission: submission, result: result} ->
          # Structural equality ignores object key order, including nested objects,
          # while preserving array order and distinct JSON value types.
          if submission === operation do
            result
          else
            json_result(Map.put(rejected("operation_id_conflict"), :operation_id, operation_id))
          end
      end
    else
      # Malformed entries without a usable identifier cannot reserve an ID.
      operation_result(operation, operation_id)
    end
  end

  defp operation_result(operation, operation_id) do
    operation |> dispatch() |> Map.put(:operation_id, operation_id) |> json_result()
  end

  # Normalize dates and keys before both storing and returning the first result.
  defp json_result(result), do: result |> Jason.encode!() |> Jason.decode!()

  defp dispatch(op) when is_map(op) do
    if identifier?(op["operation_id"]) and identifier?(op["group_id"]) do
      case op["type"] do
        "open_group" ->
          with_operation_date(op, &open_group(op, &1))

        type when type in @updates ->
          update_group(op)

        _ ->
          rejected("invalid_operation")
      end
    else
      rejected("invalid_operation")
    end
  end

  defp dispatch(_), do: rejected("invalid_operation")

  defp open_group(op, booked_on) do
    cond do
      Repo.get(Group, op["group_id"]) != nil ->
        rejected("group_already_exists")

      not (identifier?(op["guest_id"]) and identifier?(op["property_id"]) and
               required?(op, ~w(arrival_on departure_on rate_plan rooms))) ->
        rejected("invalid_operation")

      true ->
        with {:ok, arrival_on} <- stay_date(op["arrival_on"]),
             {:ok, departure_on} <- stay_date(op["departure_on"]),
             :ok <- validate_stay(arrival_on, departure_on),
             :ok <- validate_rate_plan(op["rate_plan"]),
             {:ok, rooms, lodging, deposit} <-
               price_rooms(op["rooms"], Date.diff(departure_on, arrival_on), op["rate_plan"]) do
          group =
            Repo.insert!(%Group{
              group_id: op["group_id"],
              guest_id: op["guest_id"],
              property_id: op["property_id"],
              booked_on: booked_on,
              arrival_on: arrival_on,
              departure_on: departure_on,
              rate_plan: op["rate_plan"],
              policy_version: policy_version(op["rate_plan"], booked_on),
              rooms: rooms,
              lodging_total_cents: lodging,
              deposit_due_cents: deposit
            })

          applied(group, %{deposit_due_cents: deposit})
        else
          {:error, code} -> rejected(code)
        end
    end
  end

  defp update_group(op) do
    case Repo.get(Group, op["group_id"]) do
      nil ->
        rejected("group_not_found")

      group ->
        cond do
          Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
            rejected("stale_revision")
            |> Map.merge(%{
              group_id: group.group_id,
              expected_revision: op["expected_revision"],
              actual_revision: group.revision
            })

          not required?(op, ["occurred_on"]) or not required_update_fields?(op) ->
            rejected("invalid_operation")

          group.status != "active" ->
            rejected("group_not_active")

          true ->
            with_operation_date(op, &perform_update(group, op, &1))
        end
    end
  end

  defp perform_update(group, %{"type" => "record_cash_payment"} = op, _) do
    amount = op["amount_cents"]

    cond do
      not (is_integer(amount) and amount > 0) ->
        rejected("invalid_amount")

      amount > outstanding(group) ->
        rejected("payment_exceeds_outstanding")

      true ->
        group =
          save(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })

        applied(group, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group)})
    end
  end

  defp perform_update(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    with {:ok, arrival_on} <- stay_date(op["new_arrival_on"]),
         :gt <- Date.compare(arrival_on, occurred_on),
         {:ok, departure_on} <- shifted_departure(group, arrival_on) do
      group = save(group, %{arrival_on: arrival_on, departure_on: departure_on})

      applied(group, %{
        new_arrival_on: arrival_on,
        new_departure_on: departure_on,
        policy_version: group.policy_version,
        refundable_until: refundable_until(group)
      })
    else
      _ -> rejected("invalid_stay")
    end
  end

  defp perform_update(group, %{"type" => "apply_hotel_credit"} = op, occurred_on) do
    amount = op["amount_cents"]

    cond do
      not (is_integer(amount) and amount > 0) ->
        rejected("invalid_amount")

      amount > outstanding(group) ->
        rejected("payment_exceeds_outstanding")

      true ->
        lots = Repo.all(available_lots(group.guest_id, occurred_on))

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          rejected("insufficient_credit")
        else
          Enum.reduce_while(lots, amount, fn lot, needed ->
            used = min(lot.remaining_cents, needed)

            lot
            |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
            |> Repo.update!()

            Repo.insert!(%CreditAllocation{
              group_id: group.group_id,
              credit_lot_id: lot.id,
              amount_cents: used
            })

            if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
          end)

          group =
            save(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: group.credit_paid_cents + amount
            })

          applied(group, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group)})
        end
    end
  end

  defp perform_update(group, %{"type" => "cancel_group"} = op, occurred_on) do
    method = Map.get(op, "refund_method", "cash")
    until = refundable_until(group)
    refundable = until != nil and Date.compare(occurred_on, until) != :gt

    cond do
      method not in ["cash", "hotel_credit"] -> rejected("invalid_operation")
      method == "hotel_credit" and not refundable -> rejected("refund_method_not_available")
      true -> settle(group, op, occurred_on, refundable, method)
    end
  end

  defp settle(group, op, occurred_on, refundable, method) do
    converted = if refundable and method == "hotel_credit", do: group.cash_paid_cents, else: 0
    issued = converted + div(converted * 10 + 50, 100)
    refunded = if refundable and method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    if issued > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: op["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    allocations = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)

    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      # Restored expired credit is consumed immediately; reads must not resurrect it.
      if refundable and Date.compare(lot.expires_on, occurred_on) != :lt do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end

    group =
      save(group, %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: refunded,
        cash_retained_cents: retained,
        cash_converted_to_credit_cents: converted
      })

    applied(group, %{
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued
    })
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    days = if group.policy_version == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -days)
  end

  defp save(group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp required_update_fields?(%{"type" => type} = op)
       when type in ~w(record_cash_payment apply_hotel_credit),
       do: required?(op, ["amount_cents"])

  defp required_update_fields?(%{"type" => "reschedule_group"} = op),
    do: required?(op, ["new_arrival_on"])

  defp required_update_fields?(_), do: true
  defp required?(op, fields), do: Enum.all?(fields, &Map.has_key?(op, &1))
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp with_operation_date(op, apply) do
    case date(op["occurred_on"]) do
      {:ok, occurred_on} -> apply.(occurred_on)
      _ -> rejected("invalid_operation")
    end
  end

  defp date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date(_), do: {:error, :invalid_date}

  defp stay_date(value) do
    case date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp validate_stay(arrival, departure) do
    if Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(plan) when plan in ~w(flexible advance_purchase), do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp price_rooms(rooms, nights, plan) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and
         length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) do
      lodging = Enum.sum(Enum.map(rooms, &(&1["nightly_rate_cents"] * nights)))

      deposit =
        Enum.sum(
          Enum.map(rooms, fn room ->
            amount = room["nightly_rate_cents"] * nights
            # Integer arithmetic keeps rounding exact, including half-cent ties.
            if plan == "flexible", do: div(amount * 20 + 50, 100), else: amount
          end)
        )

      if lodging <= @max_cents do
        {:ok, Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))), lodging, deposit}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp price_rooms(_, _, _), do: {:error, "invalid_rooms"}

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}),
    do: identifier?(id) and is_integer(rate) and rate >= 0

  defp valid_room?(_), do: false

  defp shifted_departure(group, arrival) do
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
    if departure.year in 0..9999, do: {:ok, departure}, else: {:error, "invalid_stay"}
  rescue
    ArgumentError -> {:error, "invalid_stay"}
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp rejected(code), do: %{status: "rejected", code: code}

  defp applied(group, fields),
    do:
      Map.merge(fields, %{status: "applied", group_id: group.group_id, revision: group.revision})
end
