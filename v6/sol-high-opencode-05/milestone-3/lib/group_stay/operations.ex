defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{CreditApplication, CreditLot, Group, OperationRecord, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)
  @active "active"
  @cancelled "cancelled"
  @policy_cutoff ~D[2027-01-01]
  @max_integer 9_223_372_036_854_775_807

  def submit_batch(operations) do
    Enum.map(operations, &execute/1)
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_record_id == ^group.id,
              order_by: room.position
          )

        render_group(group, rooms)
    end
  end

  def get_operation(operation_id) do
    case operation_record(operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def guest_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on_days |> Date.from_gregorian_days() |> Date.to_iso8601()
          }
        end)
    }
  end

  def ledger(on) do
    on_days = Date.to_gregorian_days(on)

    cash_totals =
      Repo.all(Group)
      |> Enum.reduce(
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0
        },
        fn group, totals ->
          %{
            cash_held_cents:
              totals.cash_held_cents +
                if(group.status == @active, do: group.cash_paid_cents, else: 0),
            cash_refunded_cents: totals.cash_refunded_cents + group.cash_refunded_cents,
            cash_retained_cents: totals.cash_retained_cents + group.cash_retained_cents,
            cash_converted_to_credit_cents:
              totals.cash_converted_to_credit_cents + group.cash_converted_to_credit_cents
          }
        end
      )

    available_credit =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.remaining_cents > 0 and lot.issued_on_days <= ^on_days and
              lot.expires_on_days >= ^on_days,
          select: lot.remaining_cents
      )
      |> Enum.sum()

    applied_credit =
      Repo.all(
        from application in CreditApplication,
          join: group in Group,
          on: group.id == application.group_record_id,
          join: lot in CreditLot,
          on: lot.id == application.credit_lot_id,
          where: group.status == @active and lot.issued_on_days <= ^on_days,
          select: application.amount_cents
      )
      |> Enum.sum()

    Map.put(cash_totals, :credit_liability_cents, available_credit + applied_credit)
  end

  defp execute(operation) when is_map(operation) do
    operation_id = operation_id(operation)

    if valid_identifier?(operation_id) do
      case operation_record(operation_id) do
        nil -> execute_first_attempt(operation, operation_id)
        record -> replay_or_conflict(record, operation, operation_id)
      end
    else
      execute_without_record(operation)
    end
  end

  defp execute(operation), do: execute_without_record(operation)

  defp execute_first_attempt(operation, operation_id) do
    transaction(fn ->
      case operation_record(operation_id) do
        nil ->
          result = apply_operation(operation)

          Repo.insert!(%OperationRecord{
            operation_id: operation_id,
            operation_type: submitted_type(operation),
            submission: operation,
            result: result
          })

          result

        record ->
          replay_or_conflict(record, operation, operation_id)
      end
    end)
  end

  defp execute_without_record(operation) do
    transaction(fn -> apply_operation(operation) end)
  end

  defp transaction(callback) do
    case Repo.transaction(callback, mode: :immediate) do
      {:ok, result} -> result
      {:error, reason} -> raise "operation transaction rolled back: #{inspect(reason)}"
    end
  end

  defp replay_or_conflict(record, operation, operation_id) do
    if record.submission == operation do
      record.result
    else
      rejected(operation_id, "operation_id_conflict")
    end
  end

  defp operation_record(operation_id) do
    Repo.get_by(OperationRecord, operation_id: operation_id)
  end

  defp submitted_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      case Map.get(operation, "type") do
        "open_group" -> open_group(operation, operation_id)
        "record_cash_payment" -> record_cash_payment(operation, operation_id)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id)
        "reschedule_group" -> reschedule_group(operation, operation_id)
        "cancel_group" -> cancel_group(operation, operation_id)
        _ -> rejected(operation_id, "invalid_operation")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_operation(operation), do: rejected(operation_id(operation), "invalid_operation")

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> validate_and_open(operation, operation_id, group_id)
        _group -> rejected(operation_id, "group_already_exists")
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp validate_and_open(operation, operation_id, group_id) do
    with {:ok, booked_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, arrival_on, departure_on, nights} <- validate_stay(operation),
         {:ok, rooms} <- validate_rooms(operation, nights),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         {:ok, lodging_total, deposit_due} <- calculate_totals(rooms, rate_plan) do
      policy_version = policy_version(rate_plan, booked_on)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version,
        status: @active,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        revision: 1
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          now_rooms =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              %{
                id: Ecto.UUID.generate(),
                group_record_id: group.id,
                position: position,
                room_id: room.room_id,
                nightly_rate_cents: room.nightly_rate_cents
              }
            end)

          Repo.insert_all(Room, now_rooms)

          applied(operation_id, %{
            group_id: group_id,
            deposit_due_cents: deposit_due,
            revision: 1
          })

        {:error, changeset} ->
          if changeset.errors[:group_id] do
            rejected(operation_id, "group_already_exists")
          else
            rejected(operation_id, "invalid_operation")
          end
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp record_cash_payment(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, _occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, amount} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount) do
        revision = group.revision + 1
        paid = group.deposit_paid_cents + amount
        cash_paid = group.cash_paid_cents + amount

        update_group(group,
          deposit_paid_cents: paid,
          cash_paid_cents: cash_paid,
          revision: revision
        )

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - paid,
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp apply_hotel_credit(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, amount} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount),
           {:ok, lots} <- sufficient_credit(group.guest_id, occurred_on, amount) do
        consume_credit(lots, group, amount)

        revision = group.revision + 1
        paid = group.deposit_paid_cents + amount
        credit_paid = group.credit_paid_cents + amount

        update_group(group,
          deposit_paid_cents: paid,
          credit_paid_cents: credit_paid,
          revision: revision
        )

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - paid,
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp reschedule_group(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, new_arrival} <- required_date(operation, "new_arrival_on", "invalid_stay"),
           :ok <- arrival_after_operation(new_arrival, occurred_on) do
        nights = Date.diff(group.departure_on, group.arrival_on)
        new_departure = Date.add(new_arrival, nights)
        revision = group.revision + 1
        policy_version = group_policy_version(group)

        update_group(group,
          arrival_on: new_arrival,
          departure_on: new_departure,
          revision: revision
        )

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(new_arrival),
          new_departure_on: Date.to_iso8601(new_departure),
          policy_version: policy_version,
          refundable_until: refundable_until(policy_version, new_arrival),
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp cancel_group(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, refund_method} <- refund_method(operation),
           refundable = refundable?(group, occurred_on),
           :ok <- refund_method_available(refund_method, refundable) do
        {refunded, retained, converted, credit_issued} =
          settle_cancellation(group, operation_id, occurred_on, refund_method, refundable)

        revision = group.revision + 1

        update_group(group,
          status: @cancelled,
          cash_refunded_cents: refunded,
          cash_retained_cents: retained,
          cash_converted_to_credit_cents: converted,
          revision: revision
        )

        applied(operation_id, %{
          group_id: group.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: credit_issued,
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp sufficient_credit(guest_id, occurred_on, amount) do
    lots = available_lots(guest_id, occurred_on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp available_lots(guest_id, on) do
    on_days = Date.to_gregorian_days(on)

    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.issued_on_days <= ^on_days and lot.expires_on_days >= ^on_days,
        order_by: [lot.expires_on_days, lot.source_operation_id, lot.id]
    )
  end

  defp consume_credit(lots, group, amount) do
    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(lot.remaining_cents, needed)

      Repo.update_all(
        from(item in CreditLot, where: item.id == ^lot.id),
        set: [remaining_cents: lot.remaining_cents - used]
      )

      Repo.insert!(%CreditApplication{
        credit_lot_id: lot.id,
        group_record_id: group.id,
        amount_cents: used
      })

      if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
    end)
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _other -> :error
    end
  end

  defp refund_method_available("hotel_credit", false),
    do: {:error, "refund_method_not_available"}

  defp refund_method_available(_refund_method, _refundable), do: :ok

  defp refundable?(group, occurred_on) do
    case refundable_until_date(group_policy_version(group), group.arrival_on) do
      nil -> false
      last_refundable_day -> not Date.after?(occurred_on, last_refundable_day)
    end
  end

  defp settle_cancellation(group, operation_id, occurred_on, refund_method, refundable) do
    settle_applied_credit(group, occurred_on, refundable)

    case {refundable, refund_method} do
      {true, "cash"} ->
        {group.cash_paid_cents, 0, 0, 0}

      {true, "hotel_credit"} ->
        issued = issue_credit(group, operation_id, occurred_on)
        {0, 0, group.cash_paid_cents, issued}

      {false, "cash"} ->
        {0, group.cash_paid_cents, 0, 0}
    end
  end

  defp settle_applied_credit(group, occurred_on, refundable) do
    applications =
      Repo.all(
        from application in CreditApplication,
          join: lot in CreditLot,
          on: lot.id == application.credit_lot_id,
          where: application.group_record_id == ^group.id,
          select: {application, lot}
      )

    if refundable do
      Enum.each(applications, fn {application, lot} ->
        if Date.to_gregorian_days(occurred_on) <= lot.expires_on_days do
          Repo.update_all(
            from(item in CreditLot, where: item.id == ^lot.id),
            inc: [remaining_cents: application.amount_cents]
          )
        end
      end)
    end

    Repo.delete_all(
      from application in CreditApplication, where: application.group_record_id == ^group.id
    )
  end

  defp issue_credit(%Group{cash_paid_cents: 0}, _operation_id, _occurred_on), do: 0

  defp issue_credit(group, operation_id, occurred_on) do
    bonus = div(group.cash_paid_cents * 10 + 50, 100)
    issued = group.cash_paid_cents + bonus

    Repo.insert!(%CreditLot{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      issued_on_days: Date.to_gregorian_days(occurred_on),
      expires_on_days: occurred_on |> Date.add(365) |> Date.to_gregorian_days(),
      remaining_cents: issued
    })

    issued
  end

  defp with_group(operation, operation_id, callback) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          rejected(operation_id, "group_not_found")

        group ->
          case check_revision(operation, group) do
            :ok ->
              callback.(group)

            {:stale, expected} ->
              rejected(operation_id, "stale_revision", %{
                group_id: group.group_id,
                expected_revision: expected,
                actual_revision: group.revision
              })

            :error ->
              rejected(operation_id, "invalid_operation")
          end
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp check_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") do
      case Map.get(operation, "expected_revision") do
        expected when is_integer(expected) ->
          if expected == group.revision, do: :ok, else: {:stale, expected}

        _other ->
          :error
      end
    else
      :ok
    end
  end

  defp update_group(group, fields) do
    query = from item in Group, where: item.id == ^group.id and item.revision == ^group.revision
    {updated, _} = Repo.update_all(query, set: fields)

    if updated != 1, do: Repo.rollback(:concurrent_update)
  end

  defp active(%Group{status: @active}), do: :ok
  defp active(_group), do: {:error, "group_not_active"}

  defp payment_amount(operation) do
    if Map.has_key?(operation, "amount_cents") do
      case Map.get(operation, "amount_cents") do
        amount when is_integer(amount) and amount > 0 -> {:ok, amount}
        _other -> {:error, "invalid_amount"}
      end
    else
      :error
    end
  end

  defp payment_within_outstanding(group, amount) do
    if amount <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp arrival_after_operation(arrival, occurred_on) do
    if Date.after?(arrival, occurred_on), do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_stay(operation) do
    with {:ok, arrival} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure} <- required_date(operation, "departure_on", "invalid_stay") do
      nights = Date.diff(departure, arrival)
      if nights > 0, do: {:ok, arrival, departure, nights}, else: {:error, "invalid_stay"}
    else
      :error -> :error
      {:error, _code} -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(operation, nights) do
    if Map.has_key?(operation, "rooms") do
      case Map.get(operation, "rooms") do
        rooms when is_list(rooms) and rooms != [] ->
          parsed = Enum.map(rooms, &validate_room(&1, nights))

          with true <- Enum.all?(parsed, &match?({:ok, _}, &1)),
               valid_rooms = Enum.map(parsed, fn {:ok, room} -> room end),
               true <- unique_room_ids?(valid_rooms) do
            {:ok, valid_rooms}
          else
            _other -> {:error, "invalid_rooms"}
          end

        _other ->
          {:error, "invalid_rooms"}
      end
    else
      :error
    end
  end

  defp validate_room(room, nights) when is_map(room) do
    with {:ok, room_id} <- required_identifier(room, "room_id"),
         rate when is_integer(rate) and rate > 0 <- Map.get(room, "nightly_rate_cents"),
         lodging = nights * rate,
         true <- lodging <= @max_integer do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate, lodging_cents: lodging}}
    else
      _other -> :error
    end
  end

  defp validate_room(_room, _nights), do: :error

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp validate_rate_plan(operation) do
    if Map.has_key?(operation, "rate_plan") do
      case Map.get(operation, "rate_plan") do
        rate_plan when rate_plan in @rate_plans -> {:ok, rate_plan}
        _other -> {:error, "invalid_rate_plan"}
      end
    else
      :error
    end
  end

  defp calculate_totals(rooms, rate_plan) do
    lodging_total = Enum.sum(Enum.map(rooms, & &1.lodging_cents))

    deposit_due =
      case rate_plan do
        "flexible" ->
          Enum.sum(Enum.map(rooms, &div(&1.lodging_cents * 20 + 50, 100)))

        "advance_purchase" ->
          lodging_total
      end

    if lodging_total <= @max_integer and deposit_due <= @max_integer do
      {:ok, lodging_total, deposit_due}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, @policy_cutoff), do: "flex-14", else: "flex-30"
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp group_policy_version(group), do: policy_version(group.rate_plan, group.booked_on)

  defp refundable_until_date("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until_date("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until_date("advance-nonrefundable", _arrival_on), do: nil

  defp refundable_until(policy_version, arrival_on) do
    case refundable_until_date(policy_version, arrival_on) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp required_identifier(map, key) do
    if Map.has_key?(map, key) and valid_identifier?(Map.get(map, key)) do
      {:ok, Map.get(map, key)}
    else
      :error
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp required_date(map, key, invalid_code) do
    if Map.has_key?(map, key) do
      case Map.get(map, key) do
        value when is_binary(value) ->
          case Date.from_iso8601(value) do
            {:ok, date} -> {:ok, date}
            {:error, _reason} -> {:error, invalid_code}
          end

        _other ->
          {:error, invalid_code}
      end
    else
      :error
    end
  end

  defp render_group(group, rooms) do
    policy_version = group_policy_version(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version,
      refundable_until: refundable_until(policy_version, group.arrival_on),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents:
        if(group.status == @active,
          do: group.deposit_due_cents - group.deposit_paid_cents,
          else: 0
        )
    }
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejected(operation_id, code, fields \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil
end
