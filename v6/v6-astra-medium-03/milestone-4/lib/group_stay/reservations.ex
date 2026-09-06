defmodule GroupStay.Reservations do
  @moduledoc "Processes partner operations atomically, in order, against persisted reservations."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, Repo, CreditLot, CreditAllocation, Operation, Accounting}

  @types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms reduce_cash_payment charge_back_payment)
  @public_fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan policy_version cash_paid_cents credit_paid_cents status revision rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a

  def batch(operations), do: Enum.map(operations, &process/1)

  def get_group(id), do: snapshot(fn -> read_group(id) end)

  defp read_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
        |> Map.put(:rooms, Accounting.view(Accounting.state(id)))
    end
  end

  def guest_credit(id, on \\ Date.utc_today()) do
    lots = available_lots(id, on)

    %{
      guest_id: id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def ledger(on \\ Date.utc_today()), do: snapshot(fn -> read_ledger(on) end)

  defp read_ledger(on) do
    totals =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0),
            credit_liability_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.credit_paid_cents
                  )
                ),
                0
              ) +
                subquery(
                  from l in CreditLot,
                    where: l.expires_on >= ^on,
                    select: coalesce(sum(l.remaining_cents), 0)
                )
          }
      )

    entries =
      Repo.all(from s in "room_accounts", select: s.data)
      |> Enum.flat_map(fn data -> Jason.decode!(data)["entries"] end)

    Map.merge(totals, %{
      cash_reduced_cents:
        Accounting.total(Enum.filter(entries, &(&1["disposition"] == "reduced"))),
      cash_charged_back_cents:
        Accounting.total(Enum.filter(entries, &(&1["disposition"] == "charged_back"))),
      credit_shortfall_cents: Accounting.ledger_extras()
    })
  end

  # Multiple queries in a read must observe the same committed database snapshot.
  defp snapshot(read) do
    {:ok, result} = Repo.transaction(read, mode: :deferred)
    result
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp process(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil
    # Reserve SQLite's writer before looking up the operation or domain state. This
    # serializes both retries and revision checks, including across server processes.
    {:ok, result} =
      operation_transaction(
        fn ->
          if identifier?(id) do
            case Repo.get_by(Operation, operation_id: id) do
              nil ->
                result = evaluate(op, id)

                Repo.insert!(%Operation{
                  operation_id: id,
                  type: if(is_binary(op["type"]), do: op["type"], else: nil),
                  payload: op,
                  result: result
                })

                result

              record ->
                if record.payload === op do
                  record.result
                else
                  %{operation_id: id, status: "rejected", code: "operation_id_conflict"}
                end
            end
          else
            # Missing or unusable identifiers cannot establish a retry identity.
            evaluate(op, id)
          end
        end,
        4
      )

    # Results are JSON snapshots (including dates), with the context's atom keys.
    # Only these server-authored top-level keys are converted, never submitted data.
    result
    |> Jason.encode!()
    |> Jason.decode!()
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp operation_transaction(fun, attempts) do
    Repo.transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      # Retry only failure to acquire the writer, before the callback has run.
      # Errors during domain processing or commit must propagate and abort the batch.
      if attempts > 1 and error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           error.message == "database is locked" do
        Process.sleep(:rand.uniform(25))
        operation_transaction(fun, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  def get_operation(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> nil
      record -> record.result
    end
  end

  defp evaluate(op, id) do
    result =
      case validate_common(op) do
        :ok -> dispatch(op)
        {:error, code} -> {:error, code}
      end

    case result do
      {:ok, fields} ->
        Map.merge(fields, %{operation_id: id, status: "applied"})

      {:error, code} ->
        %{operation_id: id, status: "rejected", code: code}

      {:stale, group} ->
        %{
          operation_id: id,
          status: "rejected",
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: op["expected_revision"],
          actual_revision: group.revision
        }
    end
  end

  defp validate_common(op) when is_map(op) do
    if op["type"] in @types and identifier?(op["operation_id"]) and
         identifier?(
           op[
             if(op["type"] in ~w(reduce_cash_payment charge_back_payment),
               do: "payment_operation_id",
               else: "group_id"
             )
           ]
         ) and Map.has_key?(op, "occurred_on"),
       do: :ok,
       else: {:error, "invalid_operation"}
  end

  defp validate_common(_), do: {:error, "invalid_operation"}

  defp dispatch(%{"type" => "open_group"} = op), do: open(op)

  defp dispatch(%{"type" => type} = op)
       when type in ~w(reduce_cash_payment charge_back_payment) do
    case Accounting.payment(op["payment_operation_id"]) do
      {:error, "operation_not_found"} = error ->
        error

      {:error, _} ->
        {:error,
         if(type == "reduce_cash_payment",
           do: "payment_not_reducible",
           else: "payment_not_chargeable"
         )}

      {:ok, record} ->
        group = Repo.get!(Group, record.result["group_id"])

        if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
          {:stale, group}
        else
          correct_payment(group, record, op)
        end
    end
  end

  defp dispatch(op) do
    case Repo.get(Group, op["group_id"]) do
      nil ->
        {:error, "group_not_found"}

      group ->
        cond do
          Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
            {:stale, group}

          group.status != "active" ->
            {:error, "group_not_active"}

          true ->
            apply_operation(group, op)
        end
    end
  end

  def get_payment(id), do: snapshot(fn -> read_payment(id) end)

  defp read_payment(id) do
    with {:ok, record} <- Accounting.payment(id), do: {:ok, Accounting.statement(record)}
  end

  defp correct_payment(group, record, op) do
    statement = Accounting.statement(record)
    reduction = op["type"] == "reduce_cash_payment"

    with {:ok, _} <- date(op["occurred_on"], "invalid_operation") do
      cond do
        reduction and statement.held_cents == 0 ->
          {:error, "payment_not_reducible"}

        not reduction and
            (statement.charged_back_cents > 0 or
               statement.reduced_cents == statement.recorded_cents) ->
          {:error, "payment_not_chargeable"}

        reduction and not Map.has_key?(op, "amount_cents") ->
          {:error, "invalid_operation"}

        reduction and not (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) ->
          {:error, "invalid_amount"}

        reduction and op["amount_cents"] > statement.held_cents ->
          {:error, "reduction_exceeds_held_cash"}

        true ->
          data = Accounting.state(group.group_id)

          data =
            if reduction,
              do: Accounting.reduce(data, record.operation_id, op["amount_cents"]),
              else: Accounting.chargeback(data, record.operation_id)

          Accounting.save(group.group_id, data)
          attrs = Accounting.totals(data)

          attrs =
            if reduction,
              do: attrs,
              else:
                attrs ++
                  [
                    refunded_cents: group.refunded_cents - statement.refunded_cents,
                    retained_cents: group.retained_cents - statement.retained_cents,
                    cash_converted_to_credit_cents:
                      group.cash_converted_to_credit_cents - statement.converted_to_credit_cents
                  ]

          group = update(group, attrs)

          fields = %{
            payment_operation_id: record.operation_id,
            outstanding_deposit_cents: outstanding(group)
          }

          fields =
            if reduction,
              do: Map.put(fields, :amount_cents, op["amount_cents"]),
              else:
                Map.put(
                  fields,
                  :charged_back_cents,
                  statement.recorded_cents - statement.reduced_cents
                )

          success(group, fields)
      end
    end
  end

  defp open(op) do
    with :ok <- required(op, ~w(guest_id property_id arrival_on departure_on rate_plan rooms)),
         true <-
           (identifier?(op["guest_id"]) and identifier?(op["property_id"])) ||
             {:error, "invalid_operation"},
         nil <- Repo.get(Group, op["group_id"]),
         {:ok, booked} <- date(op["occurred_on"], "invalid_stay"),
         {:ok, arrival} <- date(op["arrival_on"], "invalid_stay"),
         {:ok, departure} <- date(op["departure_on"], "invalid_stay"),
         true <- Date.diff(departure, arrival) > 0 || {:error, "invalid_stay"},
         true <- op["rate_plan"] in ~w(flexible advance_purchase) || {:error, "invalid_rate_plan"},
         :ok <- validate_rooms(op["rooms"]) do
      nights = Date.diff(departure, arrival)
      rooms = Enum.map(op["rooms"], &Map.take(&1, ~w(room_id nightly_rate_cents)))
      lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

      due =
        Enum.sum(
          Enum.map(lodging, fn amount ->
            if op["rate_plan"] == "flexible", do: div(amount * 20 + 50, 100), else: amount
          end)
        )

      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: booked,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          policy_version: policy_version(op["rate_plan"], booked),
          rooms: rooms,
          lodging_total_cents: Enum.sum(lodging),
          deposit_due_cents: due
        })

      Accounting.initialize(group)
      success(group, %{deposit_due_cents: due})
    else
      %Group{} -> {:error, "group_already_exists"}
      error -> error
    end
  end

  defp apply_operation(group, %{"type" => "record_cash_payment"} = op) do
    with :ok <- required(op, ["amount_cents"]),
         {:ok, _} <- date(op["occurred_on"], "invalid_operation"),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) ||
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) || {:error, "payment_exceeds_outstanding"} do
      data =
        Accounting.state(group.group_id)
        |> Accounting.fund(op["amount_cents"], "cash", op["operation_id"])

      Accounting.save(group.group_id, data)

      group =
        update(group,
          deposit_paid_cents: group.deposit_paid_cents + op["amount_cents"],
          cash_paid_cents: group.cash_paid_cents + op["amount_cents"]
        )

      success(group, %{
        amount_cents: op["amount_cents"],
        outstanding_deposit_cents: outstanding(group)
      })
    end
  end

  defp apply_operation(group, %{"type" => "reschedule_group"} = op) do
    with :ok <- required(op, ["new_arrival_on"]),
         {:ok, occurred} <- date(op["occurred_on"], "invalid_stay"),
         {:ok, arrival} <- date(op["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(arrival, occurred) == :gt || {:error, "invalid_stay"} do
      departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
      group = update(group, arrival_on: arrival, departure_on: departure)

      success(group, %{
        new_arrival_on: arrival,
        new_departure_on: departure,
        policy_version: group.policy_version,
        refundable_until: refundable_until(group)
      })
    end
  end

  defp apply_operation(group, %{"type" => "apply_hotel_credit"} = op) do
    with :ok <- required(op, ["amount_cents"]),
         {:ok, occurred} <- date(op["occurred_on"], "invalid_operation"),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) ||
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) || {:error, "payment_exceeds_outstanding"} do
      lots = available_lots(group.guest_id, occurred)
      amount = op["amount_cents"]

      if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
        {:error, "insufficient_credit"}
      else
        Enum.reduce_while(lots, amount, fn lot, needed ->
          used = min(lot.remaining_cents, needed)

          lot
          |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
          |> Repo.update!()

          data = Accounting.state(group.group_id) |> Accounting.fund(used, "credit", nil, lot.id)
          Accounting.save(group.group_id, data)

          Repo.insert!(%CreditAllocation{
            group_id: group.group_id,
            credit_lot_id: lot.id,
            amount_cents: used
          })

          if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
        end)

        group =
          update(group,
            deposit_paid_cents: group.deposit_paid_cents + amount,
            credit_paid_cents: group.credit_paid_cents + amount
          )

        success(group, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group)})
      end
    end
  end

  defp apply_operation(group, %{"type" => type} = op)
       when type in ~w(cancel_group cancel_rooms) do
    data = Accounting.state(group.group_id)
    active_ids = for room <- data["rooms"], room["status"] == "active", do: room["room_id"]
    ids = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    with true <-
           (type != "cancel_rooms" or Map.has_key?(op, "room_ids")) ||
             {:error, "invalid_operation"},
         true <-
           (is_list(ids) and ids != [] and Enum.uniq(ids) == ids and
              Enum.all?(ids, &(&1 in active_ids))) || {:error, "invalid_rooms"},
         {:ok, occurred} <- date(op["occurred_on"], "invalid_operation"),
         method = Map.get(op, "refund_method", "cash"),
         true <- method in ~w(cash hotel_credit) || {:error, "invalid_operation"} do
      cutoff = refundable_until(group)
      refundable = cutoff != nil and Date.compare(occurred, cutoff) != :gt

      if method == "hotel_credit" and not refundable do
        {:error, "refund_method_not_available"}
      else
        cash =
          data["entries"]
          |> Enum.filter(
            &(&1["room_id"] in ids and &1["kind"] == "cash" and &1["disposition"] == "held")
          )
          |> Accounting.total()

        converted = if method == "hotel_credit", do: cash, else: 0
        issued = Accounting.bonus(converted)
        refunded = if refundable and method == "cash", do: cash, else: 0
        retained = if refundable, do: 0, else: cash

        lot =
          if issued > 0 do
            Repo.insert!(%CreditLot{
              guest_id: group.guest_id,
              source_operation_id: op["operation_id"],
              remaining_cents: issued,
              expires_on: Date.add(occurred, 365)
            })
          end

        data = Accounting.settle(data, ids, refundable, method, if(lot, do: lot.id), occurred)
        Accounting.save(group.group_id, data)

        group =
          update(
            group,
            Accounting.totals(data) ++
              [
                refunded_cents: group.refunded_cents + refunded,
                retained_cents: group.retained_cents + retained,
                cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
              ]
          )

        fields = %{
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: issued
        }

        fields =
          if type == "cancel_rooms",
            do: Map.put(fields, :cancelled_room_ids, Enum.filter(active_ids, &(&1 in ids))),
            else: fields

        success(group, fields)
      end
    end
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked) do
    if Date.compare(booked, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))
  end

  defp update(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp success(group, fields),
    do: {:ok, Map.merge(fields, %{group_id: group.group_id, revision: group.revision})}

  defp outstanding(%{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp required(op, keys) do
    if Enum.all?(keys, &Map.has_key?(op, &1)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp date(_, code), do: {:error, code}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0
      end)

    if valid and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms),
      do: :ok,
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}
end
