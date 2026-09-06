defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, OperationRecord, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)

  def submit(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, rooms: from(r in Room, order_by: r.position))}
    end
  end

  def get_operation(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, deserialize_result(record.result)}
    end
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        cash =
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
                cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
              }
          )

        available =
          Repo.one(
            from l in CreditLot,
              where: l.expires_on > ^on,
              select: coalesce(sum(l.remaining_cents), 0)
          )

        applied =
          Repo.one(
            from a in CreditAllocation,
              join: g in assoc(a, :group),
              where: g.status == "active",
              select: coalesce(sum(a.amount_cents), 0)
          )

        Map.put(cash, :credit_liability_cents, available + applied)
      end)

    totals
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: format_date(refundable_until(group)),
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(group.rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp process(operation) when is_map(operation) do
    operation_id = operation["operation_id"]

    if valid_identifier?(operation_id) do
      {:ok, result} =
        Repo.transaction(fn -> process_durable(operation, operation_id) end, mode: :immediate)

      result
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process(_operation), do: rejected(nil, "invalid_operation")

  defp process_durable(operation, operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      %OperationRecord{submission: submission, result: result} ->
        if submission === operation,
          do: deserialize_result(result),
          else: rejected(operation_id, "operation_id_conflict")

      nil ->
        result = process_new(operation, operation_id)

        %OperationRecord{}
        |> OperationRecord.changeset(%{
          operation_id: operation_id,
          operation_type: operation_type(operation),
          submission: operation,
          result: result
        })
        |> Repo.insert!()

        result
    end
  end

  defp process_new(operation, operation_id) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, result} <- dispatch(operation, occurred_on) do
      Map.merge(%{operation_id: operation_id, status: "applied"}, result)
    else
      :error ->
        rejected(operation_id, "invalid_operation")

      {:error, result} when is_map(result) ->
        result
        |> Map.put(:operation_id, operation_id)
        |> Map.put(:status, "rejected")

      {:error, code} ->
        rejected(operation_id, code)
    end
  end

  defp dispatch(%{"type" => "open_group"} = operation, occurred_on) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if required_fields?(operation, required),
      do: open_group(operation, occurred_on),
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => "record_cash_payment"} = operation, occurred_on),
    do: dispatch_update(operation, occurred_on, ~w(group_id amount_cents))

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation, occurred_on),
    do: dispatch_update(operation, occurred_on, ~w(group_id amount_cents))

  defp dispatch(%{"type" => "reschedule_group"} = operation, occurred_on),
    do: dispatch_update(operation, occurred_on, ~w(group_id new_arrival_on))

  defp dispatch(%{"type" => "cancel_group"} = operation, occurred_on),
    do: dispatch_update(operation, occurred_on, ~w(group_id))

  defp dispatch(_operation, _occurred_on), do: {:error, "invalid_operation"}

  defp open_group(operation, booked_on) do
    with {:ok, attrs} <- opening_attrs(operation, booked_on) do
      case Repo.insert(Group.create_changeset(attrs)) do
        {:ok, group} ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          rooms =
            operation["rooms"]
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              %{
                group_record_id: group.id,
                room_id: room["room_id"],
                nightly_rate_cents: room["nightly_rate_cents"],
                position: position,
                inserted_at: now,
                updated_at: now
              }
            end)

          {count, _} = Repo.insert_all(Room, rooms)
          if count != length(rooms), do: raise("failed to persist all rooms")

          {:ok,
           %{
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}

        {:error, changeset} ->
          if unique_error?(changeset, :group_id),
            do: {:error, "group_already_exists"},
            else: {:error, "invalid_operation"}
      end
    end
  end

  defp opening_attrs(operation, booked_on) do
    with true <- identifiers?(operation, ~w(group_id guest_id property_id)),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt || {:domain, "invalid_stay"},
         rate_plan when rate_plan in @rate_plans <-
           operation["rate_plan"] || {:domain, "invalid_rate_plan"},
         {:ok, room_totals} <-
           room_totals(operation["rooms"], Date.diff(departure_on, arrival_on), rate_plan) do
      {:ok,
       %{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         policy_version: policy_version(rate_plan, booked_on),
         status: "active",
         revision: 1,
         lodging_total_cents: room_totals.lodging,
         deposit_due_cents: room_totals.deposit
       }}
    else
      false -> {:error, "invalid_operation"}
      :error -> {:error, "invalid_stay"}
      {:domain, code} -> {:error, code}
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp room_totals(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0
      end)

    unique = Enum.uniq_by(rooms, & &1["room_id"]) |> length() == length(rooms)

    if valid and unique do
      totals =
        Enum.reduce(rooms, %{lodging: 0, deposit: 0}, fn room, totals ->
          lodging = nights * room["nightly_rate_cents"]
          deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
          %{lodging: totals.lodging + lodging, deposit: totals.deposit + deposit}
        end)

      {:ok, totals}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp room_totals(_rooms, _nights, _rate_plan), do: {:error, "invalid_rooms"}

  defp dispatch_update(operation, occurred_on, required) do
    if required_fields?(operation, required),
      do: update_group(operation, occurred_on),
      else: {:error, "invalid_operation"}
  end

  defp update_group(operation, occurred_on) do
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> {:error, "group_not_found"}
        group -> normalize_apply_result(apply_to_group(group, operation, occurred_on))
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp apply_to_group(group, operation, occurred_on) do
    expected_revision = operation["expected_revision"]

    cond do
      not is_nil(expected_revision) and expected_revision != group.revision ->
        {:error,
         %{
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}

      group.status != "active" ->
        {:error, "group_not_active"}

      true ->
        apply_active(group, operation, occurred_on)
    end
  end

  defp apply_active(group, %{"type" => "record_cash_payment"} = operation, _occurred_on) do
    amount = operation["amount_cents"]
    outstanding = outstanding(group)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > outstanding ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        group =
          update!(group,
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          )

        %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        }
    end
  end

  defp apply_active(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on) do
    amount = operation["amount_cents"]
    outstanding = outstanding(group)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > outstanding ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        lots = available_lots(group.guest_id, occurred_on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          {:error, "insufficient_credit"}
        else
          allocate_credit!(lots, group, amount)

          group =
            update!(group,
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: group.credit_paid_cents + amount
            )

          %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(group),
            revision: group.revision
          }
        end
    end
  end

  defp apply_active(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      new_departure = Date.add(new_arrival, Date.diff(group.departure_on, group.arrival_on))
      group = update!(group, arrival_on: new_arrival, departure_on: new_departure)

      %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival),
        new_departure_on: Date.to_iso8601(new_departure),
        policy_version: group.policy_version,
        refundable_until: format_date(refundable_until(group)),
        revision: group.revision
      }
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp apply_active(group, %{"type" => "cancel_group"} = operation, occurred_on) do
    refund_method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred_on)

    cond do
      refund_method not in ~w(cash hotel_credit) ->
        {:error, "invalid_operation"}

      refund_method == "hotel_credit" and not refundable ->
        {:error, "refund_method_not_available"}

      true ->
        settle_cancellation(group, operation, occurred_on, refundable, refund_method)
    end
  end

  defp settle_cancellation(group, operation, occurred_on, refundable, refund_method) do
    allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_record_id == ^group.id,
          preload: [:credit_lot]
      )

    if refundable, do: restore_credit!(allocations, occurred_on)
    Enum.each(allocations, &Repo.delete!/1)

    refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    converted =
      if refundable and refund_method == "hotel_credit", do: group.cash_paid_cents, else: 0

    credit_issued =
      if converted > 0 do
        issued = converted + div(converted * 10 + 50, 100)

        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, 366)
        })

        issued
      else
        0
      end

    group =
      update!(group,
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained,
        cash_converted_to_credit_cents: converted
      )

    %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: group.revision
    }
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp allocate_credit!(lots, group, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(l in CreditLot, where: l.id == ^lot.id)
      |> Repo.update_all(set: [remaining_cents: lot.remaining_cents - used, updated_at: now])

      Repo.insert!(%CreditAllocation{
        credit_lot_id: lot.id,
        group_record_id: group.id,
        amount_cents: used
      })

      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp restore_credit!(allocations, occurred_on) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(allocations, fn allocation ->
      if Date.compare(allocation.credit_lot.expires_on, occurred_on) == :gt do
        from(l in CreditLot, where: l.id == ^allocation.credit_lot_id)
        |> Repo.update_all(
          inc: [remaining_cents: allocation.amount_cents],
          set: [updated_at: now]
        )
      end
    end)
  end

  defp update!(group, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
      |> Repo.update_all(set: Keyword.put(attrs, :updated_at, now), inc: [revision: 1])

    Repo.get!(Group, group.id)
  end

  defp outstanding(%Group{status: "active"} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding(_group), do: 0

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: "flex-14"} = group),
    do: Date.add(group.arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30"} = group),
    do: Date.add(group.arrival_on, -30)

  defp refundable_until(_group), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred_on, date) != :gt
    end
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp identifiers?(operation, keys),
    do: Enum.all?(keys, &valid_identifier?(operation[&1]))

  defp required_fields?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, options}} -> options[:constraint] == :unique
      _ -> false
    end)
  end

  defp normalize_apply_result({:error, reason}), do: {:error, reason}
  defp normalize_apply_result(result), do: {:ok, result}

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp deserialize_result(result) do
    Map.new(result, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp rejected(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}
end
