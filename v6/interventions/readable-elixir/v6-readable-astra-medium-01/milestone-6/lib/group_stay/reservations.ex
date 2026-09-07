defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations to group deposit accounts.

  Each operation uses a SQLite immediate transaction, acquiring the writer lock
  before reading the revision. This serializes competing updates and makes the
  revision check and accounting change one atomic operation across processes.
  Ledger totals are derived from the same persisted accounts to avoid a second
  balance that could drift from reservation settlements.
  """
  alias GroupStay.{Repo, Credits, Accounting, Payments}
  alias GroupStay.Reservations.{Group, CancellationPolicy}

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit)

  def submit(operations), do: Enum.map(operations, &apply_operation/1)
  def get_group(id), do: Repo.get(Group, id)

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        Accounting.ledger()
        |> Map.put(:credit_liability_cents, Credits.liability(on))
        |> Map.put(:credit_shortfall_cents, Credits.shortfall())
      end)

    totals
  end

  defp apply_operation(operation) do
    GroupStay.Operations.execute(operation, fn ->
      operation
      |> dispatch()
      |> Map.put(:operation_id, if(is_map(operation), do: operation["operation_id"]))
    end)
  end

  defp dispatch(%{"type" => "start_finance_reporting"} = operation) do
    with true <- identifier?(operation["operation_id"]),
         {:ok, _} <- date(operation["occurred_on"]) do
      GroupStay.Finance.start(operation["starts_on"])
    else
      _ -> rejected("invalid_operation")
    end
  end

  defp dispatch(operation) when is_map(operation) do
    target_key =
      case operation["type"] do
        type when type in ~w(reduce_cash_payment charge_back_payment) -> "payment_operation_id"
        "transfer_deposit" -> "source_group_id"
        _ -> "group_id"
      end

    with true <-
           identifier?(operation["operation_id"]) and
             identifier?(operation[target_key]) and operation["type"] in @types,
         {:ok, occurred_on} <- date(operation["occurred_on"]) do
      case operation["type"] do
        "open_group" ->
          open_group(operation, occurred_on)

        "transfer_deposit" ->
          GroupStay.Transfers.apply(operation)

        type when type in ~w(reduce_cash_payment charge_back_payment) ->
          Payments.change(operation)

        _ ->
          update_group(operation, occurred_on)
      end
    else
      _ -> rejected("invalid_operation")
    end
  end

  defp dispatch(_), do: rejected("invalid_operation")

  defp open_group(op, booked_on) do
    cond do
      not required?(op, ~w(guest_id property_id arrival_on departure_on rate_plan rooms)) ->
        rejected("invalid_operation")

      not identifier?(op["guest_id"]) or not identifier?(op["property_id"]) ->
        rejected("invalid_operation")

      get_group(op["group_id"]) != nil ->
        rejected("group_already_exists")

      true ->
        create_group(op, booked_on)
    end
  end

  defp create_group(op, booked_on) do
    with {:ok, arrival} <- date(op["arrival_on"]),
         {:ok, departure} <- date(op["departure_on"]),
         true <- Date.diff(departure, arrival) > 0 do
      cond do
        not valid_rooms?(op["rooms"]) ->
          rejected("invalid_rooms")

        op["rate_plan"] not in ~w(flexible advance_purchase) ->
          rejected("invalid_rate_plan")

        true ->
          nights = Date.diff(departure, arrival)

          rooms =
            Enum.map(op["rooms"], fn room ->
              %Group.Room{
                room_id: room["room_id"],
                nightly_rate_cents: room["nightly_rate_cents"],
                lodging_total_cents: room["nightly_rate_cents"] * nights,
                deposit_due_cents: deposit(room["nightly_rate_cents"] * nights, op["rate_plan"])
              }
            end)

          lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
          deposit = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

          group =
            Repo.insert!(%Group{
              group_id: op["group_id"],
              guest_id: op["guest_id"],
              property_id: op["property_id"],
              booked_on: booked_on,
              arrival_on: arrival,
              departure_on: departure,
              rate_plan: op["rate_plan"],
              policy_version: CancellationPolicy.version(op["rate_plan"], booked_on),
              rooms: rooms,
              lodging_total_cents: lodging,
              deposit_due_cents: deposit
            })

          applied(group, %{deposit_due_cents: deposit})
      end
    else
      _ -> rejected("invalid_stay")
    end
  end

  defp update_group(op, occurred_on) do
    case get_group(op["group_id"]) do
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

          group.status != "active" ->
            rejected("group_not_active")

          true ->
            change_group(group, op, occurred_on)
        end
    end
  end

  defp change_group(group, %{"type" => type} = op, occurred_on)
       when type in ~w(record_cash_payment apply_hotel_credit) do
    amount = op["amount_cents"]

    cond do
      not Map.has_key?(op, "amount_cents") ->
        rejected("invalid_operation")

      not is_integer(amount) or amount <= 0 ->
        rejected("invalid_amount")

      amount > Group.outstanding(group) ->
        rejected("payment_exceeds_outstanding")

      true ->
        funding =
          if type == "apply_hotel_credit",
            do: Credits.apply(group, amount, occurred_on),
            else: Accounting.fund_cash(group, op["operation_id"], amount)

        case funding do
          {:error, code} ->
            rejected(code)

          :ok ->
            updated = Accounting.refresh(group)

            applied(updated, %{
              amount_cents: amount,
              outstanding_deposit_cents: Group.outstanding(updated)
            })
        end
    end
  end

  defp change_group(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    if Map.has_key?(op, "new_arrival_on") do
      with {:ok, arrival} <- date(op["new_arrival_on"]),
           :gt <- Date.compare(arrival, occurred_on) do
        departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
        updated = persist(group, arrival_on: arrival, departure_on: departure)

        applied(updated, %{
          new_arrival_on: arrival,
          new_departure_on: departure,
          policy_version: updated.policy_version,
          refundable_until: CancellationPolicy.refundable_until(updated)
        })
      else
        _ -> rejected("invalid_stay")
      end
    else
      rejected("invalid_operation")
    end
  end

  defp change_group(group, %{"type" => type} = op, occurred_on)
       when type in ~w(cancel_group cancel_rooms) do
    method = Map.get(op, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, occurred_on)

    active_ids = group.rooms |> Enum.filter(&(&1.status == "active")) |> Enum.map(& &1.room_id)
    ids = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    cond do
      type == "cancel_rooms" and not Map.has_key?(op, "room_ids") ->
        rejected("invalid_operation")

      not is_list(ids) or ids == [] ->
        rejected("invalid_rooms")

      length(Enum.uniq(ids)) != length(ids) or not Enum.all?(ids, &(&1 in active_ids)) ->
        rejected("invalid_rooms")

      method not in ~w(cash hotel_credit) ->
        rejected("invalid_operation")

      method == "hotel_credit" and not refundable? ->
        rejected("refund_method_not_available")

      true ->
        ordered_ids = Enum.filter(active_ids, &(&1 in ids))

        {updated, result} =
          Accounting.settle(
            group,
            ordered_ids,
            op["operation_id"],
            occurred_on,
            method,
            refundable?
          )

        result =
          if type == "cancel_rooms",
            do: Map.put(result, :cancelled_room_ids, ordered_ids),
            else: result

        applied(updated, result)
    end
  end

  defp persist(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  # Integer arithmetic rounds each room independently without floating-point loss.
  defp deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp deposit(lodging, "advance_purchase"), do: lodging

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn
      %{"room_id" => id, "nightly_rate_cents" => rate} ->
        identifier?(id) and is_integer(rate) and rate >= 0

      _ ->
        false
    end) and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp required?(op, fields), do: Enum.all?(fields, &Map.has_key?(op, &1))
  defp date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date(_), do: {:error, :invalid_date}
  defp rejected(code), do: %{status: "rejected", code: code}

  defp applied(group, fields),
    do:
      Map.merge(fields, %{status: "applied", group_id: group.group_id, revision: group.revision})
end
