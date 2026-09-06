defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo}

  @max_sqlite_integer 9_223_372_036_854_775_807
  @policy_cutoff ~D[2027-01-01]
  @rate_plans ["flexible", "advance_purchase"]

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_group_id), do: nil

  def present_group(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid(group),
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  def read_date(params) do
    result =
      case Map.fetch(params, "on") do
        :error -> {:ok, Date.utc_today()}
        {:ok, value} -> parse_read_date(value)
      end

    case result do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def guest_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(lot_cents(&1) + &2)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot_cents(lot),
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def ledger(on) do
    {:ok, totals} =
      Repo.transaction(fn ->
        cash_totals =
          from(g in Group,
            select:
              {g.status, g.deposit_paid_cents, g.credit_paid_cents, g.refunded_cents,
               g.retained_cents, g.cash_converted_to_credit_cents}
          )
          |> Repo.all()
          |> Enum.reduce(
            %{
              cash_held_cents: 0,
              cash_refunded_cents: 0,
              cash_retained_cents: 0,
              cash_converted_to_credit_cents: 0
            },
            fn {status, paid, credit_paid, refunded, retained, converted}, totals ->
              cash = paid - credit_paid

              %{
                cash_held_cents:
                  totals.cash_held_cents + if(status == "active", do: cash, else: 0),
                cash_refunded_cents: totals.cash_refunded_cents + refunded,
                cash_retained_cents: totals.cash_retained_cents + retained,
                cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents + converted
              }
            end
          )

        available_credit =
          from(l in CreditLot, where: l.expires_on >= ^on, select: l.remaining_cents)
          |> Repo.all()
          |> Enum.sum()

        applied_credit =
          from(a in CreditAllocation,
            join: g in assoc(a, :group),
            where: g.status == "active",
            select: a.amount_cents
          )
          |> Repo.all()
          |> Enum.sum()

        Map.put(cash_totals, :credit_liability_cents, available_credit + applied_credit)
      end)

    totals
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    with true <- valid_identifier?(operation_id),
         type when is_binary(type) <- Map.get(operation, "type"),
         {:ok, occurred_on} <- parse_common_date(operation) do
      process_type(type, operation, operation_id, occurred_on)
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_type("open_group", operation, operation_id, occurred_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      open_group(operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type(type, operation, operation_id, occurred_on)
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group"
            ] do
    required =
      case type do
        type when type in ["record_cash_payment", "apply_hotel_credit"] ->
          ["group_id", "amount_cents"]

        "reschedule_group" ->
          ["group_id", "new_arrival_on"]

        "cancel_group" ->
          ["group_id"]
      end

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) do
      update_group(type, operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type(_type, _operation, operation_id, _occurred_on) do
    rejected(operation_id, "invalid_operation")
  end

  defp open_group(operation, operation_id, occurred_on) do
    group_id = operation["group_id"]

    Repo.transaction(
      fn ->
        if Repo.get_by(Group, group_id: group_id) do
          rejected(operation_id, "group_already_exists", group_id: group_id)
        else
          with {:ok, arrival_on, departure_on, nights} <- validate_stay(operation),
               {:ok, rooms} <- validate_rooms(operation["rooms"]),
               {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
               {:ok, lodging_total, deposit_due} <- calculate_totals(rooms, nights, rate_plan) do
            attrs = %{
              group_id: group_id,
              guest_id: operation["guest_id"],
              property_id: operation["property_id"],
              booked_on: occurred_on,
              arrival_on: arrival_on,
              departure_on: departure_on,
              rate_plan: rate_plan,
              policy_version: policy_version(rate_plan, occurred_on),
              status: "active",
              revision: 1,
              lodging_total_cents: lodging_total,
              deposit_due_cents: deposit_due,
              rooms: rooms
            }

            case %Group{} |> Group.create_changeset(attrs) |> Repo.insert() do
              {:ok, _group} ->
                applied(operation_id,
                  group_id: group_id,
                  deposit_due_cents: deposit_due,
                  revision: 1
                )

              {:error, changeset} ->
                if Keyword.has_key?(changeset.errors, :group_id) do
                  rejected(operation_id, "group_already_exists", group_id: group_id)
                else
                  Repo.rollback(:invalid_operation)
                end
            end
          else
            {:error, code} -> rejected(operation_id, code, group_id: group_id)
          end
        end
      end,
      mode: :immediate
    )
    |> transaction_result(operation_id)
  end

  defp update_group(type, operation, operation_id, occurred_on) do
    group_id = operation["group_id"]

    Repo.transaction(
      fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            rejected(operation_id, "group_not_found", group_id: group_id)

          group ->
            with :ok <- validate_revision(group, operation, operation_id),
                 :ok <- validate_active(group, operation_id) do
              perform_update(type, group, operation, operation_id, occurred_on)
            else
              {:rejected, result} -> result
            end
        end
      end,
      mode: :immediate
    )
    |> transaction_result(operation_id)
  end

  defp perform_update("apply_hotel_credit", group, operation, operation_id, occurred_on) do
    apply_hotel_credit(group, operation, operation_id, occurred_on)
  end

  defp perform_update("cancel_group", group, operation, operation_id, occurred_on) do
    cancel_group(group, operation, operation_id, occurred_on)
  end

  defp perform_update(type, group, operation, operation_id, occurred_on) do
    case prepare_update(type, group, operation, occurred_on) do
      {:ok, updates, fields} -> apply_update(group, updates, operation_id, fields, operation)
      {:error, code} -> rejected(operation_id, code, group_id: group.group_id)
    end
  end

  defp prepare_update("record_cash_payment", group, operation, _occurred_on) do
    amount = operation["amount_cents"]

    cond do
      not valid_amount?(amount) ->
        {:error, "invalid_amount"}

      amount > outstanding(group) ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        paid = group.deposit_paid_cents + amount

        {:ok, [deposit_paid_cents: paid],
         [
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: group.deposit_due_cents - paid
         ]}
    end
  end

  defp prepare_update("reschedule_group", group, operation, occurred_on) do
    case parse_date(operation["new_arrival_on"]) do
      {:ok, new_arrival} ->
        if Date.compare(new_arrival, occurred_on) == :gt do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          new_departure = Date.add(new_arrival, stay_length)

          if new_departure.year <= 9999 do
            moved_group = %{group | arrival_on: new_arrival, departure_on: new_departure}

            {:ok, [arrival_on: new_arrival, departure_on: new_departure],
             [
               group_id: group.group_id,
               new_arrival_on: new_arrival,
               new_departure_on: new_departure,
               policy_version: policy_version(group),
               refundable_until: refundable_until(moved_group)
             ]}
          else
            {:error, "invalid_stay"}
          end
        else
          {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp apply_hotel_credit(group, operation, operation_id, occurred_on) do
    amount = operation["amount_cents"]

    cond do
      not valid_amount?(amount) ->
        rejected(operation_id, "invalid_amount", group_id: group.group_id)

      amount > outstanding(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group_id: group.group_id)

      true ->
        lots = available_lots(group.guest_id, occurred_on)

        if Enum.reduce(lots, 0, &(lot_cents(&1) + &2)) < amount do
          rejected(operation_id, "insufficient_credit", group_id: group.group_id)
        else
          paid = group.deposit_paid_cents + amount

          next_revision =
            persist_group_update(
              group,
              [deposit_paid_cents: paid, credit_paid_cents: group.credit_paid_cents + amount],
              operation_id,
              operation
            )

          consume_lots(lots, group, amount)

          applied(operation_id,
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: group.deposit_due_cents - paid,
            revision: next_revision
          )
        end
    end
  end

  defp cancel_group(group, operation, operation_id, occurred_on) do
    method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred_on)

    cond do
      method not in ["cash", "hotel_credit"] ->
        rejected(operation_id, "refund_method_not_available", group_id: group.group_id)

      method == "hotel_credit" and not refundable ->
        rejected(operation_id, "refund_method_not_available", group_id: group.group_id)

      true ->
        cash = cash_paid(group)
        refunded = if refundable and method == "cash", do: cash, else: 0
        retained = if refundable, do: 0, else: cash
        converted = if method == "hotel_credit", do: cash, else: 0
        issued = if method == "hotel_credit", do: cash + round_percentage(cash, 10), else: 0

        next_revision =
          persist_group_update(
            group,
            [
              status: "cancelled",
              refunded_cents: refunded,
              retained_cents: retained,
              cash_converted_to_credit_cents: converted
            ],
            operation_id,
            operation
          )

        settle_allocated_credit(group, refundable, occurred_on)

        if issued > 0 do
          %CreditLot{}
          |> CreditLot.changeset(%{
            guest_id: group.guest_id,
            source_operation_id: operation_id,
            remaining_cents: issued,
            expires_on: Date.add(occurred_on, 365)
          })
          |> Repo.insert!()
        end

        applied(operation_id,
          group_id: group.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: issued,
          revision: next_revision
        )
    end
  end

  defp consume_lots(lots, group, amount) do
    Enum.reduce_while(lots, amount, fn lot, left ->
      consumed = min(lot_cents(lot), left)
      remaining = lot_cents(lot) - consumed

      from(l in CreditLot, where: l.id == ^lot.id)
      |> Repo.update_all(set: [remaining_cents: remaining])

      %CreditAllocation{}
      |> CreditAllocation.changeset(%{
        credit_lot_id: lot.id,
        group_id: group.id,
        amount_cents: consumed
      })
      |> Repo.insert!()

      if consumed == left, do: {:halt, 0}, else: {:cont, left - consumed}
    end)
  end

  defp settle_allocated_credit(group, refundable, occurred_on) do
    allocations =
      from(a in CreditAllocation,
        where: a.group_id == ^group.id,
        select: {a.credit_lot_id, a.amount_cents}
      )
      |> Repo.all()

    if refundable do
      allocations
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.each(fn {lot_id, amounts} ->
        lot = Repo.get!(CreditLot, lot_id)

        if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt] do
          restored = lot_cents(lot) + Enum.sum(amounts)

          from(l in CreditLot, where: l.id == ^lot.id)
          |> Repo.update_all(set: [remaining_cents: restored])
        end
      end)
    end

    from(a in CreditAllocation, where: a.group_id == ^group.id) |> Repo.delete_all()
  end

  defp available_lots(guest_id, on) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
    |> Repo.all()
    |> Enum.filter(&(lot_cents(&1) > 0))
  end

  defp apply_update(group, updates, operation_id, fields, operation) do
    next_revision = persist_group_update(group, updates, operation_id, operation)
    applied(operation_id, Keyword.put(fields, :revision, next_revision))
  end

  defp persist_group_update(group, updates, operation_id, operation) do
    next_revision = group.revision + 1

    {count, _} =
      from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
      |> Repo.update_all(set: Keyword.put(updates, :revision, next_revision))

    if count == 1 do
      next_revision
    else
      actual_revision = Repo.get!(Group, group.id).revision

      result =
        if Map.has_key?(operation, "expected_revision") do
          stale(operation_id, group.group_id, operation["expected_revision"], actual_revision)
        else
          rejected(operation_id, "invalid_operation")
        end

      Repo.rollback({:operation_result, result})
    end
  end

  defp validate_revision(group, operation, operation_id) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when expected == group.revision ->
        :ok

      {:ok, expected} ->
        {:rejected, stale(operation_id, group.group_id, expected, group.revision)}
    end
  end

  defp validate_active(%Group{status: "active"}, _operation_id), do: :ok

  defp validate_active(group, operation_id) do
    {:rejected, rejected(operation_id, "group_not_active", group_id: group.group_id)}
  end

  defp validate_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0 and
          room["nightly_rate_cents"] <= @max_sqlite_integer
      end)

    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(room_ids) == room_ids do
      {:ok,
       rooms
       |> Enum.with_index()
       |> Enum.map(fn {room, position} ->
         %{
           room_id: room["room_id"],
           nightly_rate_cents: room["nightly_rate_cents"],
           position: position
         }
       end)}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp calculate_totals(rooms, nights, rate_plan) do
    room_lodging = Enum.map(rooms, &(&1.nightly_rate_cents * nights))
    lodging_total = Enum.sum(room_lodging)

    deposit_due =
      case rate_plan do
        "flexible" -> Enum.reduce(room_lodging, 0, &(round_percentage(&1, 20) + &2))
        "advance_purchase" -> lodging_total
      end

    if lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer do
      {:ok, lodging_total, deposit_due}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp policy_version(%Group{policy_version: nil} = group) do
    policy_version(group.rate_plan, group.booked_on)
  end

  defp policy_version(%Group{policy_version: version}), do: version

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred_on, date) in [:lt, :eq]
    end
  end

  defp parse_common_date(operation) do
    if Map.has_key?(operation, "occurred_on") do
      parse_date(operation["occurred_on"])
    else
      :error
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp parse_read_date(value) when is_binary(value) do
    case Regex.run(~r/^(\d{4,5})-(\d{2})-(\d{2})$/, value) do
      [_, year, month, day] ->
        Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))

      _ ->
        :error
    end
  end

  defp parse_read_date(_value), do: :error

  defp valid_identifier?(value), do: is_binary(value) and value != ""
  defp valid_amount?(amount), do: is_integer(amount) and amount > 0
  defp lot_cents(lot), do: lot.remaining_cents
  defp cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents
  defp round_percentage(value, percentage), do: div(value * percentage + 50, 100)

  defp outstanding(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding(%Group{}), do: 0

  defp applied(operation_id, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id, status: "applied"})
  end

  defp rejected(operation_id, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id, status: "rejected", code: code})
  end

  defp stale(operation_id, group_id, expected, actual) do
    rejected(operation_id, "stale_revision",
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    )
  end

  defp transaction_result({:ok, result}, _operation_id), do: result

  defp transaction_result({:error, {:operation_result, result}}, _operation_id), do: result

  defp transaction_result({:error, :invalid_operation}, operation_id),
    do: rejected(operation_id, "invalid_operation")
end
