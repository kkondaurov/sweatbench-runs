defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, LedgerEntry, Repo, Room}

  @operation_types ~w(
    open_group
    record_cash_payment
    apply_hotel_credit
    reschedule_group
    cancel_group
  )

  @spec process_batch([map()]) :: [map()]
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec get_group(String.t()) :: {:ok, map()} | :error
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :error

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group.id,
              order_by: [asc: room.position]
          )

        {:ok, render_group(group, rooms)}
    end
  end

  @spec credit_for_guest(String.t(), Date.t()) :: map()
  def credit_for_guest(guest_id, as_of) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0,
          where: lot.expires_on > ^as_of,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  @spec parse_report_date(term()) :: {:ok, Date.t()} | {:error, :invalid_date}
  def parse_report_date(nil), do: {:ok, Date.utc_today()}

  def parse_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def parse_report_date(_value), do: {:error, :invalid_date}

  @spec ledger_totals(Date.t()) :: map()
  def ledger_totals(as_of) do
    totals =
      Repo.all(
        from entry in LedgerEntry,
          group_by: entry.kind,
          select: {entry.kind, sum(entry.amount_cents)}
      )
      |> Map.new(fn {kind, amount} -> {kind, amount || 0} end)

    refunded = Map.get(totals, "refunded", 0)
    retained = Map.get(totals, "retained", 0)
    converted = Map.get(totals, "converted_to_credit", 0)

    %{
      "cash_held_cents" => Map.get(totals, "held", 0) - refunded - retained - converted,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "credit_liability_cents" => credit_liability(as_of)
    }
  end

  def ledger_totals, do: ledger_totals(Date.utc_today())

  defp process_operation(operation) when not is_map(operation) do
    rejection(operation, "invalid_operation")
  end

  defp process_operation(operation) do
    case Map.get(operation, "type") do
      "open_group" -> process_open_group(operation)
      type when type in @operation_types -> process_existing_group(operation, type)
      _ -> rejection(operation, "invalid_operation")
    end
  end

  defp process_open_group(operation) do
    with :ok <- validate_common_fields(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms, lodging_total, deposit_due} <-
           validate_rooms(operation["rooms"], arrival_on, departure_on, rate_plan) do
      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      }

      case Repo.transaction(fn -> insert_group(operation, attrs, rooms) end, mode: :immediate) do
        {:ok, result} -> result
        {:error, {:rejected, result}} -> result
      end
    else
      {:error, code} -> rejection(operation, code)
    end
  end

  defp insert_group(operation, attrs, rooms) do
    case Repo.get_by(Group, group_id: attrs.group_id) do
      nil ->
        group = Repo.insert!(struct(Group, attrs))

        Enum.each(rooms, fn room ->
          Repo.insert!(%Room{
            group_id: group.id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position
          })
        end)

        %{
          "operation_id" => operation["operation_id"],
          "status" => "applied",
          "group_id" => group.group_id,
          "deposit_due_cents" => group.deposit_due_cents,
          "revision" => group.revision
        }

      _group ->
        rollback_rejection(
          rejection(operation, "group_already_exists", %{"group_id" => attrs.group_id})
        )
    end
  end

  defp process_existing_group(operation, type) do
    case required_identifier(operation, "group_id") do
      {:ok, group_id} ->
        case Repo.transaction(fn -> apply_existing(operation, type, group_id) end,
               mode: :immediate
             ) do
          {:ok, result} -> result
          {:error, {:rejected, result}} -> result
        end

      {:error, code} ->
        rejection(operation, code)
    end
  end

  defp apply_existing(operation, type, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        rollback_rejection(rejection(operation, "group_not_found", %{"group_id" => group_id}))

      group ->
        case stale_revision(operation, group) do
          :ok ->
            apply_existing_with_revision(operation, type, group)

          {:error, result} ->
            rollback_rejection(result)
        end
    end
  end

  defp apply_existing_with_revision(operation, type, group) do
    with :ok <- validate_existing_fields(operation, type),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      case type do
        "record_cash_payment" -> apply_cash_payment(operation, group, occurred_on)
        "apply_hotel_credit" -> apply_hotel_credit(operation, group, occurred_on)
        "reschedule_group" -> apply_reschedule(operation, group, occurred_on)
        "cancel_group" -> apply_cancellation(operation, group, occurred_on)
      end
    else
      {:error, code} ->
        rollback_rejection(rejection(operation, code, %{"group_id" => group.group_id}))
    end
  end

  defp apply_cash_payment(operation, group, _occurred_on) do
    with :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- outstanding_deposit(group) do
      new_outstanding = outstanding - amount
      new_revision = group.revision + 1

      Repo.update!(
        Ecto.Changeset.change(group,
          deposit_paid_cents: group.deposit_paid_cents + amount,
          cash_paid_cents: group.cash_paid_cents + amount,
          revision: new_revision
        )
      )

      Repo.insert!(%LedgerEntry{group_id: group.id, kind: "held", amount_cents: amount})

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => new_outstanding,
        "revision" => new_revision
      }
    else
      {:error, code} ->
        rollback_rejection(rejection(operation, code, %{"group_id" => group.group_id}))

      _ ->
        rollback_rejection(
          rejection(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})
        )
    end
  end

  defp apply_hotel_credit(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- outstanding_deposit(group),
         lots <- available_credit_lots(group.guest_id, occurred_on),
         {:ok, allocations} <- allocate_credit(lots, amount) do
      new_outstanding = outstanding - amount
      new_revision = group.revision + 1

      Repo.update!(
        Ecto.Changeset.change(group,
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: new_revision
        )
      )

      Enum.each(allocations, fn {lot, allocated} ->
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - allocated))

        Repo.insert!(%CreditAllocation{
          group_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: allocated
        })
      end)

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => new_outstanding,
        "revision" => new_revision
      }
    else
      {:error, code} ->
        rollback_rejection(rejection(operation, code, %{"group_id" => group.group_id}))

      _ ->
        rollback_rejection(
          rejection(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})
        )
    end
  end

  defp apply_reschedule(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_reschedule_date(new_arrival_on, occurred_on) do
      day_shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, day_shift)
      new_revision = group.revision + 1

      Repo.update!(
        Ecto.Changeset.change(group,
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: new_revision
        )
      )

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival_on),
        "new_departure_on" => Date.to_iso8601(new_departure_on),
        "revision" => new_revision
      }
      |> Map.merge(policy_fields(%{group | arrival_on: new_arrival_on}))
    else
      {:error, code} ->
        rollback_rejection(rejection(operation, code, %{"group_id" => group.group_id}))
    end
  end

  defp apply_cancellation(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation) do
      refundable? = refundable?(group, occurred_on)

      if refundable? or refund_method == "cash" do
        settle_cancellation(operation, group, occurred_on, refund_method, refundable?)
      else
        rollback_rejection(
          rejection(operation, "refund_method_not_available", %{"group_id" => group.group_id})
        )
      end
    else
      {:error, code} ->
        rollback_rejection(rejection(operation, code, %{"group_id" => group.group_id}))
    end
  end

  defp settle_cancellation(operation, group, occurred_on, refund_method, refundable?) do
    cash_paid = group.cash_paid_cents || group.deposit_paid_cents
    new_revision = group.revision + 1

    {ledger_kind, refunded, retained} =
      cond do
        refundable? and refund_method == "hotel_credit" ->
          {"converted_to_credit", 0, 0}

        refundable? ->
          {"refunded", cash_paid, 0}

        true ->
          {"retained", 0, cash_paid}
      end

    Repo.update!(Ecto.Changeset.change(group, status: "cancelled", revision: new_revision))

    if cash_paid > 0 do
      Repo.insert!(%LedgerEntry{group_id: group.id, kind: ledger_kind, amount_cents: cash_paid})
    end

    credit_issued =
      if refundable? and refund_method == "hotel_credit" do
        issue_credit_lot(group, operation["operation_id"], occurred_on, cash_paid)
      else
        0
      end

    if refundable? do
      restore_credit_allocations(group, occurred_on)
    else
      consume_credit_allocations(group)
    end

    %{
      "operation_id" => operation["operation_id"],
      "status" => "applied",
      "group_id" => group.group_id,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "credit_issued_cents" => credit_issued,
      "revision" => new_revision
    }
  end

  defp stale_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:error,
         rejection(operation, "stale_revision", %{
           "group_id" => group.group_id,
           "expected_revision" => expected_revision,
           "actual_revision" => group.revision
         })}
    end
  end

  defp validate_common_fields(operation) do
    if valid_identifier(operation["operation_id"]) and is_binary(operation["occurred_on"]) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_existing_fields(operation, "record_cash_payment") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "amount_cents") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "reschedule_group") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "new_arrival_on") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "apply_hotel_credit") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "amount_cents") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "cancel_group") do
    with :ok <- validate_common_fields(operation),
         :ok <- validate_refund_method(operation) do
      :ok
    end
  end

  defp require_field(operation, field) do
    if Map.has_key?(operation, field), do: :ok, else: {:error, "invalid_operation"}
  end

  defp validate_refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> :ok
      {:ok, method} when method in ["cash", "hotel_credit"] -> :ok
      _ -> {:error, "invalid_operation"}
    end
  end

  defp cancellation_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, field) do
    if valid_identifier(operation[field]) do
      {:ok, operation[field]}
    else
      {:error, "invalid_operation"}
    end
  end

  defp valid_identifier(value), do: is_binary(value) and byte_size(value) > 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_reschedule_date(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"],
    do: {:ok, rate_plan}

  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms, arrival_on, departure_on, rate_plan) when is_list(rooms) do
    if rooms == [] do
      {:error, "invalid_rooms"}
    else
      nights = Date.diff(departure_on, arrival_on)

      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({[], 0, MapSet.new()}, fn {room, position},
                                                     {valid_rooms, lodging_total, room_ids} ->
        with {:ok, room_id} <- room_identifier(room),
             false <- MapSet.member?(room_ids, room_id),
             {:ok, nightly_rate_cents} <- nightly_rate(room) do
          lodging = nights * nightly_rate_cents
          deposit = deposit_for(lodging, rate_plan)

          {:cont,
           {[{room_id, nightly_rate_cents, position, deposit} | valid_rooms],
            lodging_total + lodging, MapSet.put(room_ids, room_id)}}
        else
          true -> {:halt, {:error, "invalid_rooms"}}
          {:error, _reason} -> {:halt, {:error, "invalid_rooms"}}
        end
      end)
      |> case do
        {valid_rooms, lodging_total, _room_ids} ->
          rooms =
            valid_rooms
            |> Enum.reverse()
            |> Enum.map(fn {room_id, nightly_rate_cents, position, _deposit} ->
              %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}
            end)

          deposit_due =
            valid_rooms
            |> Enum.map(fn {_room_id, _rate, _position, deposit} -> deposit end)
            |> Enum.sum()

          {:ok, rooms, lodging_total, deposit_due}

        {:error, code} ->
          {:error, code}
      end
    end
  end

  defp validate_rooms(_rooms, _arrival_on, _departure_on, _rate_plan),
    do: {:error, "invalid_rooms"}

  defp room_identifier(room) when is_map(room), do: required_identifier(room, "room_id")
  defp room_identifier(_room), do: {:error, "invalid_rooms"}

  defp nightly_rate(room) when is_map(room) do
    case room["nightly_rate_cents"] do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp deposit_for(lodging, "advance_purchase"), do: lodging
  defp deposit_for(lodging, "flexible"), do: div(lodging * 20 + 50, 100)

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(_group), do: {:error, "group_not_active"}

  defp usable_payment_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp usable_payment_amount(_amount), do: {:error, "invalid_amount"}

  defp available_credit_lots(guest_id, occurred_on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on > ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp allocate_credit(lots, amount) do
    {remaining, allocations} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, allocations} ->
        allocated = min(remaining, lot.remaining_cents)

        if allocated == remaining do
          {:halt, {0, [{lot, allocated} | allocations]}}
        else
          {:cont, {remaining - allocated, [{lot, allocated} | allocations]}}
        end
      end)

    if remaining == 0 do
      {:ok, Enum.reverse(allocations)}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp issue_credit_lot(_group, _source_operation_id, _occurred_on, 0), do: 0

  defp issue_credit_lot(group, source_operation_id, occurred_on, cash_paid) do
    credit_issued = cash_paid + div(cash_paid * 10 + 50, 100)

    Repo.insert!(%CreditLot{
      guest_id: group.guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: credit_issued,
      expires_on: Date.add(occurred_on, 366)
    })

    credit_issued
  end

  defp restore_credit_allocations(group, occurred_on) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.id
      )

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {credit_lot_id, amount} ->
      lot = Repo.get!(CreditLot, credit_lot_id)

      if Date.compare(lot.expires_on, occurred_on) == :gt do
        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + Enum.sum(Enum.map(amount, & &1.amount_cents))
          )
        )
      end
    end)

    consume_credit_allocations(group)
  end

  defp consume_credit_allocations(group) do
    Repo.delete_all(from allocation in CreditAllocation, where: allocation.group_id == ^group.id)
  end

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
          select: sum(lot.remaining_cents)
      ) || 0

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: group.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    available + applied
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_details(group) do
    case group.policy_version do
      "flex-14" ->
        {"flex-14", 14}

      "flex-30" ->
        {"flex-30", 30}

      "advance-nonrefundable" ->
        {"advance-nonrefundable", nil}

      _ ->
        case policy_version(group.rate_plan, group.booked_on) do
          "advance-nonrefundable" -> {"advance-nonrefundable", nil}
          version -> {version, if(version == "flex-14", do: 14, else: 30)}
        end
    end
  end

  defp policy_fields(group) do
    {version, window} = policy_details(group)

    %{
      "policy_version" => version,
      "refundable_until" =>
        if(window, do: Date.to_iso8601(Date.add(group.arrival_on, -window)), else: nil)
    }
  end

  defp refundable?(group, occurred_on) do
    {_version, window} = policy_details(group)
    is_integer(window) and Date.diff(group.arrival_on, occurred_on) >= window
  end

  defp render_group(group, rooms) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "revision" => group.revision,
      "rooms" =>
        Enum.map(rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents || group.deposit_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents || 0,
      "outstanding_deposit_cents" =>
        if(group.status == "active", do: outstanding_deposit(group), else: 0)
    }
    |> Map.merge(policy_fields(group))
  end

  defp rejection(operation, code, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id(operation),
        "status" => "rejected",
        "code" => code
      },
      extra
    )
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp rollback_rejection(result), do: Repo.rollback({:rejected, result})
end
