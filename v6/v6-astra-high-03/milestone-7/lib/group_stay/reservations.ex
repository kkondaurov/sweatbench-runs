defmodule GroupStay.Reservations do
  @moduledoc "Applies ordered partner operations and reads reservation accounting."
  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo, RoomAccounting}
  alias RoomAccounting, as: Rooms
  alias GroupStay.FinanceReporting

  @updates ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms)
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
    # Cash, liability, and shortfall must observe the same database snapshot.
    {:ok, totals} =
      Repo.transaction(fn ->
        cash =
          Repo.one(
            from g in Group,
              select: %{
                cash_held_cents: coalesce(sum(g.cash_paid_cents), 0),
                cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
                cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
                cash_reduced_cents: coalesce(sum(g.cash_reduced_cents), 0),
                cash_charged_back_cents: coalesce(sum(g.cash_charged_back_cents), 0),
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

        cash
        |> Map.update!(:credit_liability_cents, &(&1 + available))
        |> Map.put(:credit_shortfall_cents, Rooms.shortfall())
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
    cond do
      not identifier?(op["operation_id"]) -> rejected("invalid_operation")
      op["type"] == "start_finance_reporting" -> FinanceReporting.start(op)
      op["type"] == "close_finance_period" -> FinanceReporting.close(op)
      op["type"] == "transfer_deposit" -> transfer_deposit(op)
      op["type"] in ~w(reduce_cash_payment charge_back_payment) -> update_payment(op)
      not identifier?(op["group_id"]) -> rejected("invalid_operation")
      op["type"] == "open_group" -> with_operation_date(op, &open_group(op, &1))
      op["type"] in @updates -> update_group(op)
      true -> rejected("invalid_operation")
    end
  end

  defp dispatch(_), do: rejected("invalid_operation")

  defp transfer_deposit(op) do
    if identifier?(op["source_group_id"]) and identifier?(op["destination_group_id"]) do
      with {:ok, source} <- transfer_group(op["source_group_id"]),
           {:ok, destination} <- transfer_group(op["destination_group_id"]),
           :ok <- check_revision(source, op, "expected_revision"),
           :ok <- check_revision(destination, op, "destination_expected_revision") do
        if required?(op, ~w(amount_cents occurred_on)) do
          with_operation_date(op, fn _ -> perform_transfer(source, destination, op) end)
        else
          rejected("invalid_operation")
        end
      else
        {:error, result} -> result
      end
    else
      rejected("invalid_operation")
    end
  end

  defp transfer_group(id) do
    case Repo.get(Group, id) do
      nil -> {:error, Map.put(rejected("group_not_found"), :group_id, id)}
      group -> {:ok, group}
    end
  end

  defp check_revision(group, op, key) do
    if Map.has_key?(op, key) and op[key] !== group.revision do
      {:error,
       Map.merge(rejected("stale_revision"), %{
         group_id: group.group_id,
         expected_revision: op[key],
         actual_revision: group.revision
       })}
    else
      :ok
    end
  end

  defp perform_transfer(source, destination, op) do
    amount = op["amount_cents"]

    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        rejected("invalid_transfer")

      source.status != "active" ->
        Map.put(rejected("group_not_active"), :group_id, source.group_id)

      destination.status != "active" ->
        Map.put(rejected("group_not_active"), :group_id, destination.group_id)

      not (is_integer(amount) and amount > 0) ->
        rejected("invalid_amount")

      amount > source.deposit_paid_cents ->
        rejected("transfer_exceeds_held_funding")

      amount > outstanding(destination) ->
        rejected("transfer_exceeds_outstanding")

      true ->
        {drawn, funded} = Rooms.transfer(source, destination, amount)
        moved_cash = source.cash_paid_cents - Rooms.totals(drawn.rooms).cash_paid_cents
        source = save(source, Rooms.totals(drawn.rooms))
        destination = save(destination, Rooms.totals(funded.rooms))

        FinanceReporting.cash_change(op, source.property_id, %{
          "transferred_out_cents" => moved_cash
        })

        FinanceReporting.cash_change(op, destination.property_id, %{
          "transferred_in_cents" => moved_cash
        })

        %{
          status: "applied",
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: amount,
          source_outstanding_deposit_cents: outstanding(source),
          destination_outstanding_deposit_cents: outstanding(destination),
          source_revision: source.revision,
          destination_revision: destination.revision
        }
    end
  end

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
        funded = Rooms.fund(group, amount, :cash, op["operation_id"])
        group = save(group, Rooms.totals(funded.rooms))
        FinanceReporting.cash_change(op, group.property_id, %{"received_cents" => amount})

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
          funded =
            Enum.reduce_while(lots, {group, amount}, fn lot, {funded, needed} ->
              used = min(lot.remaining_cents, needed)

              lot
              |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
              |> Repo.update!()

              FinanceReporting.credit_change(op, lot, -used, used, :none)
              funded = Rooms.fund(funded, used, :credit, op["operation_id"], lot.id)
              if used == needed, do: {:halt, funded}, else: {:cont, {funded, needed - used}}
            end)

          group = save(group, Rooms.totals(funded.rooms))

          applied(group, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group)})
        end
    end
  end

  defp perform_update(group, %{"type" => type} = op, occurred_on)
       when type in ~w(cancel_group cancel_rooms) do
    method = Map.get(op, "refund_method", "cash")
    until = refundable_until(group)
    refundable = until != nil and Date.compare(occurred_on, until) != :gt

    active_ids = for room <- group.rooms, room["status"] == "active", do: room["room_id"]
    selected = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    cond do
      not (is_list(selected) and selected != [] and
             length(Enum.uniq(selected)) == length(selected) and
               Enum.all?(selected, &(&1 in active_ids))) ->
        rejected("invalid_rooms")

      method not in ["cash", "hotel_credit"] ->
        rejected("invalid_operation")

      method == "hotel_credit" and not refundable ->
        rejected("refund_method_not_available")

      true ->
        settle(
          group,
          op,
          occurred_on,
          refundable,
          method,
          Enum.filter(active_ids, &(&1 in selected))
        )
    end
  end

  defp settle(group, op, occurred_on, refundable, method, room_ids) do
    cash_allocations = Rooms.cash(group.group_id, room_ids)
    cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    converted = if refundable and method == "hotel_credit", do: cash, else: 0
    issued = Rooms.bonus_value(converted)
    refunded = if refundable and method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash

    disposition =
      cond do
        not refundable -> "retained"
        method == "hotel_credit" -> "converted_to_credit"
        true -> "refunded"
      end

    if issued > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: op["operation_id"],
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, 365)
        })

      Rooms.entitle(lot, cash_allocations)
      FinanceReporting.credit_change(op, lot, issued, 0, :issued, issued)
    end

    for allocation <- cash_allocations,
        do: Rooms.move(allocation, allocation.amount_cents, disposition)

    FinanceReporting.cash_change(op, group.property_id, %{(disposition <> "_cents") => cash})

    allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_id == ^group.group_id and a.room_id in ^room_ids
      )

    for allocation <- allocations do
      if refundable do
        Rooms.restore(allocation, occurred_on, op)
      else
        lot = Repo.get!(CreditLot, allocation.credit_lot_id)

        FinanceReporting.credit_change(
          op,
          lot,
          0,
          -allocation.amount_cents,
          :consumed,
          allocation.amount_cents
        )
      end

      Repo.delete!(allocation)
    end

    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] in room_ids do
          Map.merge(room, %{
            "status" => "cancelled",
            "lodging_total_cents" => 0,
            "deposit_due_cents" => 0,
            "cash_paid_cents" => 0,
            "credit_paid_cents" => 0
          })
        else
          room
        end
      end)

    group =
      save(
        group,
        Map.merge(Rooms.totals(rooms), %{
          cash_refunded_cents: group.cash_refunded_cents + refunded,
          cash_retained_cents: group.cash_retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
        })
      )

    fields = %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}

    fields =
      if op["type"] == "cancel_rooms",
        do: Map.put(fields, :cancelled_room_ids, room_ids),
        else: fields

    applied(group, fields)
  end

  def get_payment(id) do
    case payment_record(id) do
      {:ok, payment} ->
        allocations = Rooms.payment_allocations(id)

        amounts =
          Enum.reduce(
            allocations,
            %{
              held_cents: 0,
              refunded_cents: 0,
              retained_cents: 0,
              converted_to_credit_cents: 0,
              reduced_cents: 0,
              charged_back_cents: 0
            },
            fn allocation, totals ->
              key = String.to_existing_atom(allocation.disposition <> "_cents")
              Map.update!(totals, key, &(&1 + allocation.amount_cents))
            end
          )

        amounts =
          if Enum.any?(allocations, & &1.transferred) do
            held_by_group =
              allocations
              |> Enum.filter(&(&1.disposition == "held"))
              |> Enum.group_by(& &1.group_id)
              |> Enum.sort_by(fn {id, _} -> id end)
              |> Enum.map(fn {id, held} ->
                %{group_id: id, amount_cents: Enum.sum(Enum.map(held, & &1.amount_cents))}
              end)

            Map.put(amounts, :held_by_group, held_by_group)
          else
            amounts
          end

        {:ok,
         Map.merge(amounts, %{
           payment_operation_id: id,
           original_group_id: payment.result["group_id"],
           recorded_cents: payment.result["amount_cents"]
         })}

      {:error, code} ->
        {:error, if(code == "operation_not_found", do: code, else: "payment_not_reconcilable")}
    end
  end

  defp payment_record(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %Operation{submission: %{"type" => "record_cash_payment"}, result: %{"status" => "applied"}} =
          payment ->
        {:ok, payment}

      _ ->
        {:error, "invalid_payment"}
    end
  end

  defp update_payment(op) do
    chargeback = op["type"] == "charge_back_payment"
    code = if chargeback, do: "payment_not_chargeable", else: "payment_not_reducible"

    if identifier?(op["payment_operation_id"]) do
      case payment_record(op["payment_operation_id"]) do
        {:error, "operation_not_found"} ->
          rejected("operation_not_found")

        {:error, _} ->
          rejected(code)

        {:ok, payment} ->
          group = Repo.get!(Group, payment.result["group_id"])

          cond do
            Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
              rejected("stale_revision")
              |> Map.merge(%{
                group_id: group.group_id,
                expected_revision: op["expected_revision"],
                actual_revision: group.revision
              })

            not chargeback and not Map.has_key?(op, "amount_cents") ->
              rejected("invalid_operation")

            true ->
              with_operation_date(op, fn _ -> correct_payment(group, op, chargeback, code) end)
          end
      end
    else
      rejected("invalid_operation")
    end
  end

  defp correct_payment(group, op, chargeback, code) do
    allocations = Rooms.payment_allocations(op["payment_operation_id"])

    eligible =
      Enum.filter(allocations, fn a ->
        if chargeback,
          do: a.disposition not in ~w(reduced charged_back),
          else: a.disposition == "held"
      end)

    correctable = Enum.sum(Enum.map(eligible, & &1.amount_cents))
    amount = if chargeback, do: correctable, else: op["amount_cents"]

    cond do
      correctable == 0 or
          (chargeback and Enum.any?(allocations, &(&1.disposition == "charged_back"))) ->
        rejected(code)

      not (is_integer(amount) and amount > 0) ->
        rejected("invalid_amount")

      amount > correctable ->
        rejected("reduction_exceeds_held_cash")

      true ->
        disposition = if chargeback, do: "charged_back", else: "reduced"

        # Keep each allocation's accounting on its current group. The addressed
        # payment group also advances even if all its cash has moved elsewhere.
        {groups, 0} =
          Enum.reduce(eligible, {%{group.group_id => group}, amount}, fn a, {groups, left} ->
            removed = min(left, a.amount_cents)

            if removed > 0 do
              Rooms.move(a, removed, disposition)
              affected = Map.get_lazy(groups, a.group_id, fn -> Repo.get!(Group, a.group_id) end)

              movements = %{(disposition <> "_cents") => removed}

              movements =
                if a.disposition == "held",
                  do: movements,
                  else: Map.put(movements, a.disposition <> "_cents", -removed)

              FinanceReporting.cash_change(op, affected.property_id, movements)

              affected =
                if a.disposition == "held" do
                  %{affected | rooms: Rooms.remove_held(affected.rooms, a, removed)}
                else
                  key = String.to_existing_atom("cash_" <> a.disposition <> "_cents")
                  Map.update!(affected, key, &(&1 - removed))
                end

              key = if chargeback, do: :cash_charged_back_cents, else: :cash_reduced_cents
              affected = Map.update!(affected, key, &(&1 + removed))
              {Map.put(groups, a.group_id, affected), left - removed}
            else
              {groups, left}
            end
          end)

        if chargeback, do: Rooms.revoke(op["payment_operation_id"], op)

        saved =
          Map.new(groups, fn {id, affected} ->
            changes =
              affected
              |> Map.take(
                ~w(cash_refunded_cents cash_retained_cents cash_converted_to_credit_cents cash_reduced_cents cash_charged_back_cents)a
              )
              |> Map.merge(Rooms.totals(affected.rooms))

            {id, save(Repo.get!(Group, id), changes)}
          end)

        group = Map.fetch!(saved, group.group_id)

        fields = %{
          payment_operation_id: op["payment_operation_id"],
          outstanding_deposit_cents: outstanding(group)
        }

        fields =
          Map.put(fields, if(chargeback, do: :charged_back_cents, else: :amount_cents), amount)

        applied(group, fields)
    end
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

  defp required_update_fields?(%{"type" => "cancel_rooms"} = op), do: required?(op, ["room_ids"])
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
      rooms =
        Enum.map(rooms, &Rooms.price(Map.take(&1, ~w(room_id nightly_rate_cents)), nights, plan))

      lodging = Enum.sum(Enum.map(rooms, & &1["lodging_total_cents"]))
      deposit = Enum.sum(Enum.map(rooms, & &1["deposit_due_cents"]))

      if lodging <= @max_cents do
        {:ok, rooms, lodging, deposit}
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
