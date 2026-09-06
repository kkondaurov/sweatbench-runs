defmodule GroupStay.Reservations do
  @moduledoc "Applies partner operations atomically and owns reservation deposit accounting."

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, CreditLot, Operation, Accounting}

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit)
  @max_integer 9_223_372_036_854_775_807
  @public_fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status revision rooms lodging_total_cents deposit_due_cents deposit_paid_cents cash_paid_cents credit_paid_cents policy_version)a

  def batch(operations), do: Enum.map(operations, &apply_operation/1)

  def get_operation(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_group(id) do
    {:ok, result} = Repo.transaction(fn -> read_group(id) end, mode: :deferred)
    result
  end

  defp read_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:rooms, Accounting.rooms(group))
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def ledger(on \\ Date.utc_today()) do
    # All accounting queries share a snapshot so a concurrent redemption cannot be counted twice.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end, mode: :deferred)
    totals
  end

  defp ledger_totals(on) do
    # Sum in Elixir to retain exact totals beyond SQLite's signed integer range.
    groups =
      Repo.all(
        from g in Group,
          select:
            map(g, [
              :cash_paid_cents,
              :refunded_cents,
              :retained_cents,
              :cash_converted_to_credit_cents,
              :credit_paid_cents,
              :cash_reduced_cents,
              :cash_charged_back_cents
            ])
      )

    available =
      Repo.all(from l in CreditLot, where: l.expires_on >= ^on, select: l.remaining_cents)

    %{
      cash_reduced_cents: Enum.sum(Enum.map(groups, & &1.cash_reduced_cents)),
      cash_charged_back_cents: Enum.sum(Enum.map(groups, & &1.cash_charged_back_cents)),
      credit_shortfall_cents: Accounting.shortfall(),
      cash_held_cents: Enum.sum(Enum.map(groups, & &1.cash_paid_cents)),
      cash_refunded_cents: Enum.sum(Enum.map(groups, & &1.refunded_cents)),
      cash_retained_cents: Enum.sum(Enum.map(groups, & &1.retained_cents)),
      cash_converted_to_credit_cents:
        Enum.sum(Enum.map(groups, & &1.cash_converted_to_credit_cents)),
      credit_liability_cents:
        Enum.sum(available) + Enum.sum(Enum.map(groups, & &1.credit_paid_cents))
    }
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp apply_operation(op), do: apply_operation(op, 3)

  defp apply_operation(op, retries) do
    # Acquire SQLite's write lock before looking up the operation or domain state.
    # Concurrent requests cannot both miss the audit record or spend the same funds.
    {:ok, result} = Repo.transaction(fn -> remember(op) end, mode: :immediate)
    result
  rescue
    error in Exqlite.Error ->
      # Only lock acquisition is retryable: no operation code has run yet.
      # Never conceal a fault from inside the transaction or during commit.
      if retries > 0 and error.message == "database is locked" and
           error.statement == "BEGIN IMMEDIATE TRANSACTION" do
        Process.sleep((4 - retries) * 25)
        apply_operation(op, retries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp remember(%{"operation_id" => id} = op) when is_binary(id) and byte_size(id) > 0 do
    # Check the durable record before any domain reads, including revision checks.
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        result = op |> execute() |> Jason.encode!() |> Jason.decode!()

        Repo.insert!(%Operation{
          operation_id: id,
          type: if(is_binary(op["type"]), do: op["type"]),
          submission: op,
          result: result
        })

        result_keys(result)

      %Operation{submission: submission, result: result} when submission === op ->
        result_keys(result)

      %Operation{} ->
        reject(op, %{code: "operation_id_conflict"})
    end
  end

  # Without a usable identifier there is no retry identity to remember.
  defp remember(op), do: execute(op)

  # Only server-owned result keys are atoms; nested partner values stay untouched.
  defp result_keys(result),
    do: Map.new(result, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp execute(op) when is_map(op) do
    with :ok <- common_fields(op),
         {:ok, occurred_on} <- date(op["occurred_on"], "invalid_operation"),
         {:ok, result} <- dispatch(op, occurred_on) do
      Map.merge(result, %{operation_id: op["operation_id"], status: "applied"})
    else
      {:error, code} when is_binary(code) -> reject(op, %{code: code})
      {:error, details} -> reject(op, details)
    end
  end

  defp execute(_), do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  defp reject(op, details),
    do: Map.merge(details, %{operation_id: op["operation_id"], status: "rejected"})

  defp common_fields(op) do
    targets =
      case op["type"] do
        "transfer_deposit" -> ~w(source_group_id destination_group_id)
        type when type in ~w(reduce_cash_payment charge_back_payment) -> ~w(payment_operation_id)
        _ -> ~w(group_id)
      end

    if op["type"] in @types and Enum.all?(["operation_id" | targets], &identifier?(op[&1])),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => "transfer_deposit"} = op, _on) do
    with {:ok, source} <- transfer_group(op["source_group_id"]),
         {:ok, destination} <- transfer_group(op["destination_group_id"]),
         :ok <- check_revision(op, source),
         :ok <- check_revision(op, destination, "destination_expected_revision"),
         true <-
           (source.group_id != destination.group_id and source.guest_id == destination.guest_id) or
             {:error, "invalid_transfer"},
         :ok <- transfer_active(source),
         :ok <- transfer_active(destination),
         :ok <- required(op, ~w(amount_cents)),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) or
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= source.deposit_paid_cents or
             {:error, "transfer_exceeds_held_funding"},
         true <-
           op["amount_cents"] <= outstanding(destination) or
             {:error, "transfer_exceeds_outstanding"} do
      Accounting.transfer(source, destination, op["amount_cents"])
      source = persist(source, Accounting.totals(source))
      destination = persist(destination, Accounting.totals(destination))

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: op["amount_cents"],
         source_outstanding_deposit_cents: outstanding(source),
         destination_outstanding_deposit_cents: outstanding(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp dispatch(%{"type" => "open_group"} = op, occurred_on) do
    with :ok <- required(op, ~w(guest_id property_id arrival_on departure_on rate_plan rooms)),
         true <-
           (identifier?(op["guest_id"]) and identifier?(op["property_id"])) or
             {:error, "invalid_operation"},
         nil <- Repo.get(Group, op["group_id"]),
         {:ok, arrival} <- date(op["arrival_on"], "invalid_stay"),
         {:ok, departure} <- date(op["departure_on"], "invalid_stay"),
         true <- Date.compare(departure, arrival) == :gt or {:error, "invalid_stay"},
         true <- op["rate_plan"] in ~w(flexible advance_purchase) or {:error, "invalid_rate_plan"},
         {:ok, rooms, lodging, deposit} <-
           price_rooms(op["rooms"], Date.diff(departure, arrival), op["rate_plan"]) do
      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: occurred_on,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          policy_version: policy_version(op["rate_plan"], occurred_on),
          rooms: rooms,
          lodging_total_cents: lodging,
          deposit_due_cents: deposit
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    else
      %Group{} -> {:error, "group_already_exists"}
      error -> error
    end
  end

  defp dispatch(%{"type" => type} = op, _on)
       when type in ~w(reduce_cash_payment charge_back_payment) do
    error =
      if type == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    with {:ok, payment} <- cash_payment(op["payment_operation_id"], error),
         %Group{} = group <- Repo.get(Group, payment.result["group_id"]),
         :ok <- check_revision(op, group) do
      adjust_payment(op, payment, group)
    else
      nil -> {:error, "group_not_found"}
      error -> error
    end
  end

  defp dispatch(op, occurred_on) do
    with %Group{} = group <- Repo.get(Group, op["group_id"]),
         :ok <- check_revision(op, group),
         true <- group.status == "active" or {:error, "group_not_active"} do
      update_group(op, group, occurred_on)
    else
      nil -> {:error, "group_not_found"}
      error -> error
    end
  end

  defp transfer_group(id) do
    case Repo.get(Group, id) do
      nil -> {:error, %{code: "group_not_found", group_id: id}}
      group -> {:ok, group}
    end
  end

  defp transfer_active(group) do
    if group.status == "active",
      do: :ok,
      else: {:error, %{code: "group_not_active", group_id: group.group_id}}
  end

  defp cash_payment(id, error) do
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %Operation{type: "record_cash_payment", result: %{"status" => "applied"}} = payment ->
        {:ok, payment}

      _ ->
        {:error, error}
    end
  end

  def get_payment(id) do
    with {:ok, payment} <- cash_payment(id, "payment_not_reconcilable") do
      {:ok, Accounting.statement(payment)}
    end
  end

  defp adjust_payment(%{"type" => "reduce_cash_payment"} = op, payment, group) do
    rows = Accounting.payment_funding(payment.operation_id)
    held = rows |> Enum.filter(&(&1.disposition == "held")) |> Accounting.sum()

    with true <- held > 0 or {:error, "payment_not_reducible"},
         :ok <- required(op, ~w(amount_cents)),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) or
             {:error, "invalid_amount"},
         true <- op["amount_cents"] <= held or {:error, "reduction_exceeds_held_cash"} do
      removed = Accounting.remove_held(rows, op["amount_cents"], "reduced")

      updated =
        [group.group_id | Map.keys(removed)]
        |> Enum.uniq()
        |> Enum.map(fn id ->
          affected = Repo.get!(Group, id)

          persist(
            affected,
            Accounting.totals(affected) ++
              [cash_reduced_cents: affected.cash_reduced_cents + Map.get(removed, id, 0)]
          )
        end)
        |> Enum.find(&(&1.group_id == group.group_id))

      {:ok,
       %{
         payment_operation_id: payment.operation_id,
         group_id: group.group_id,
         amount_cents: op["amount_cents"],
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp adjust_payment(%{"type" => "charge_back_payment"}, payment, group) do
    rows = Accounting.payment_funding(payment.operation_id)
    chargeable = Enum.reject(rows, &(&1.disposition in ~w(reduced charged_back)))
    amount = Accounting.sum(chargeable)

    if amount == 0 or Enum.any?(rows, &(&1.disposition == "charged_back")) do
      {:error, "payment_not_chargeable"}
    else
      Accounting.remove_held(rows, amount, "charged_back")

      for row <- chargeable,
          row.disposition != "held",
          do: Accounting.move(row, row.amount_cents, "charged_back")

      Accounting.clawback(payment.operation_id)

      by_group = Enum.group_by(chargeable, & &1.group_id)

      updated =
        [group.group_id | Map.keys(by_group)]
        |> Enum.uniq()
        |> Enum.map(fn id ->
          affected = Repo.get!(Group, id)
          allocations = Map.get(by_group, id, [])

          disposition_amount = fn disposition ->
            allocations |> Enum.filter(&(&1.disposition == disposition)) |> Accounting.sum()
          end

          persist(
            affected,
            Accounting.totals(affected) ++
              [
                refunded_cents: affected.refunded_cents - disposition_amount.("refunded"),
                retained_cents: affected.retained_cents - disposition_amount.("retained"),
                cash_converted_to_credit_cents:
                  affected.cash_converted_to_credit_cents -
                    disposition_amount.("converted_to_credit"),
                cash_charged_back_cents:
                  affected.cash_charged_back_cents + Accounting.sum(allocations)
              ]
          )
        end)
        |> Enum.find(&(&1.group_id == group.group_id))

      {:ok,
       %{
         payment_operation_id: payment.operation_id,
         group_id: group.group_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp check_revision(op, group, key \\ "expected_revision") do
    if not Map.has_key?(op, key) or op[key] === group.revision do
      :ok
    else
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: op[key],
         actual_revision: group.revision
       }}
    end
  end

  defp update_group(%{"type" => "record_cash_payment"} = op, group, _date) do
    with :ok <- required(op, ~w(amount_cents)),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) or
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) or {:error, "payment_exceeds_outstanding"} do
      Accounting.allocate(group, op["amount_cents"], op["operation_id"])

      updated =
        persist(group,
          deposit_paid_cents: group.deposit_paid_cents + op["amount_cents"],
          cash_paid_cents: group.cash_paid_cents + op["amount_cents"]
        )

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: op["amount_cents"],
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => "reschedule_group"} = op, group, occurred_on) do
    with :ok <- required(op, ~w(new_arrival_on)),
         {:ok, arrival} <- date(op["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(arrival, occurred_on) == :gt or {:error, "invalid_stay"},
         {:ok, departure} <- shifted_departure(arrival, group) do
      updated = persist(group, arrival_on: arrival, departure_on: departure)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: arrival,
         new_departure_on: departure,
         policy_version: updated.policy_version,
         refundable_until: refundable_until(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => "apply_hotel_credit"} = op, group, occurred_on) do
    with :ok <- required(op, ~w(amount_cents)),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) or
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) or {:error, "payment_exceeds_outstanding"},
         lots = available_lots(group.guest_id, occurred_on),
         true <-
           Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= op["amount_cents"] or
             {:error, "insufficient_credit"} do
      Enum.reduce_while(lots, op["amount_cents"], fn lot, needed ->
        amount = min(needed, lot.remaining_cents)
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - amount))

        Accounting.allocate(group, amount, nil, lot.id)

        if amount == needed, do: {:halt, 0}, else: {:cont, needed - amount}
      end)

      updated =
        persist(group,
          deposit_paid_cents: group.deposit_paid_cents + op["amount_cents"],
          credit_paid_cents: group.credit_paid_cents + op["amount_cents"]
        )

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: op["amount_cents"],
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => type} = op, group, occurred_on)
       when type in ~w(cancel_group cancel_rooms) do
    active_ids = for room <- group.rooms, room["status"] == "active", do: room["room_id"]
    ids = if type == "cancel_group", do: active_ids, else: op["room_ids"]
    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred_on, cutoff) != :gt
    method = Map.get(op, "refund_method", "cash")

    with :ok <- if(type == "cancel_rooms", do: required(op, ~w(room_ids)), else: :ok),
         true <-
           (is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
              Enum.all?(ids, &(&1 in active_ids))) or {:error, "invalid_rooms"},
         true <- method in ~w(cash hotel_credit) or {:error, "invalid_operation"},
         true <- method != "hotel_credit" or refundable or {:error, "refund_method_not_available"} do
      selected =
        Enum.filter(
          Accounting.funding(group.group_id),
          &(&1.disposition == "held" and &1.room_id in ids)
        )

      {cash, credit} = Enum.split_with(selected, &is_nil(&1.credit_lot_id))
      amount = Accounting.sum(cash)
      converted = if method == "hotel_credit", do: amount, else: 0
      issued = Accounting.bonus(converted)
      refunded = if refundable and method == "cash", do: amount, else: 0
      retained = if refundable, do: 0, else: amount

      disposition =
        cond do
          method == "hotel_credit" -> "converted_to_credit"
          refundable -> "refunded"
          true -> "retained"
        end

      if issued > 0 do
        lot =
          Repo.insert!(%CreditLot{
            guest_id: group.guest_id,
            source_operation_id: op["operation_id"],
            remaining_cents: issued,
            expires_on: Date.add(occurred_on, 365)
          })

        Accounting.entitle(lot, cash)
      end

      for row <- cash, do: Accounting.move(row, row.amount_cents, disposition)

      for row <- credit do
        if refundable, do: Accounting.restore(row, occurred_on)
        Accounting.move(row, row.amount_cents, if(refundable, do: "restored", else: "consumed"))
      end

      rooms =
        Enum.map(group.rooms, fn room ->
          if room["room_id"] in ids, do: Map.put(room, "status", "cancelled"), else: room
        end)

      updated =
        persist(
          group,
          Accounting.totals(%{group | rooms: rooms}) ++
            [
              refunded_cents: group.refunded_cents + refunded,
              retained_cents: group.retained_cents + retained,
              cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
            ]
        )

      result = %{
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: issued,
        revision: updated.revision
      }

      {:ok,
       if(type == "cancel_rooms",
         do: Map.put(result, :cancelled_room_ids, Enum.filter(active_ids, &(&1 in ids))),
         else: result
       )}
    end
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))
  end

  defp persist(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp required(op, keys) do
    if Enum.all?(keys, &Map.has_key?(op, &1)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, parsed} -> {:ok, parsed}
      _ -> {:error, code}
    end
  end

  defp date(_, code), do: {:error, code}

  defp shifted_departure(arrival, group) do
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

    if departure.year in -9999..9999,
      do: {:ok, departure},
      else: {:error, "invalid_stay"}
  end

  defp price_rooms(rooms, nights, plan) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) and is_integer(rate) and rate >= 0

        _ ->
          false
      end)

    if valid and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) do
      lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
      total = Enum.sum(lodging)

      if total <= @max_integer do
        priced =
          Enum.zip(rooms, lodging)
          |> Enum.map(fn {room, amount} ->
            room
            |> Map.take(~w(room_id nightly_rate_cents))
            |> Map.merge(%{
              "status" => "active",
              "lodging_total_cents" => amount,
              # Integer arithmetic rounds each room separately, with half-cents upward.
              "deposit_due_cents" =>
                if(plan == "flexible", do: div(amount * 20 + 50, 100), else: amount)
            })
          end)

        deposit = Enum.sum(Enum.map(priced, & &1["deposit_due_cents"]))
        {:ok, priced, total, deposit}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp price_rooms(_, _, _), do: {:error, "invalid_rooms"}
end
