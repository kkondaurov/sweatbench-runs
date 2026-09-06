defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations to group reservations.

  Operations carrying an `operation_id` are durably idempotent: the first
  submission applies normally and its outcome, applied or rejected, is
  recorded in the same database transaction as the domain changes. Retries
  with an equivalent payload return the recorded outcome without reading or
  changing current domain state. An unexpected exception rolls back the
  current operation without recording it and aborts the HTTP request.
  """

  alias GroupStay.{
    Credit,
    CreditApplication,
    CreditLot,
    Group,
    Groups,
    Operation,
    Repo,
    Room
  }

  import Ecto.Query

  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)
  @policy_cutoff ~D[2027-01-01]
  @credit_availability_days 365

  @doc """
  Applies a batch of operations in array order, returning one result per
  operation in the same order.
  """
  @spec apply_all(list()) :: list(map())
  def apply_all(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  The recorded outcome for an operation identifier, or `nil` when no durable
  record exists.
  """
  @spec fetch_result(String.t()) :: map() | nil
  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      %Operation{result: result} -> result
    end
  end

  def fetch_result(_other), do: nil

  ## Idempotent application

  defp apply_operation(op) do
    case operation_key(op) do
      nil -> apply_without_record(op)
      operation_id -> apply_idempotent(operation_id, op)
    end
  end

  defp operation_key(%{"operation_id" => operation_id}) when is_binary(operation_id),
    do: operation_id

  defp operation_key(_op), do: nil

  defp apply_without_record(op) do
    {:ok, result} = Repo.transaction(fn -> apply(op) end)
    result
  end

  # The reservation insert and the domain changes commit in one transaction.
  # Inserting first takes SQLite's write lock, so concurrent retries with the
  # same identifier serialize and the loser replays the committed record.
  defp apply_idempotent(operation_id, op) do
    Repo.transaction(
      fn ->
        case reserve_operation(operation_id, op) do
          {:ok, record} ->
            result = apply(op)
            update_result(record, result)
            {:committed, result}

          {:existing, record} ->
            {:replay, record}
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, {:committed, result}} -> result
      {:ok, {:replay, record}} -> replay(record, op, operation_id)
    end
  end

  defp reserve_operation(operation_id, op) do
    %Operation{
      operation_id: operation_id,
      type: Map.get(op, "type"),
      payload: op,
      result: nil
    }
    |> Repo.insert!()
    |> then(&{:ok, &1})
  rescue
    Ecto.ConstraintError ->
      {:existing, Repo.get_by!(Operation, operation_id: operation_id)}
  end

  defp update_result(record, result) do
    record
    |> Ecto.Changeset.change(result: result)
    |> Repo.update!()
  end

  defp replay(record, op, operation_id) do
    if json_equiv?(record.payload, op) do
      record.result
    else
      %{
        "operation_id" => operation_id,
        "status" => "rejected",
        "code" => "operation_id_conflict"
      }
      |> put_group_id(op)
    end
  end

  # JSON object key order is irrelevant; array order and values are
  # significant. Numbers compare numerically, so `15000` and `15000.0`
  # are the same submitted value.
  defp json_equiv?(left, right) when is_map(left) and is_map(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        case Map.fetch(right, key) do
          {:ok, other} -> json_equiv?(value, other)
          :error -> false
        end
      end)
  end

  defp json_equiv?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      left
      |> Enum.zip(right)
      |> Enum.all?(fn {l, r} -> json_equiv?(l, r) end)
  end

  defp json_equiv?(left, right) when is_number(left) and is_number(right),
    do: left * 1.0 == right * 1.0

  defp json_equiv?(left, right), do: left === right

  defp apply(op) when not is_map(op), do: reject(nil, "invalid_operation")

  defp apply(%{"type" => type} = op) do
    case type do
      "open_group" -> apply_open_group(op)
      "record_cash_payment" -> apply_payment(op)
      "reschedule_group" -> apply_reschedule(op)
      "cancel_group" -> apply_cancel(op)
      "apply_hotel_credit" -> apply_credit(op)
      _other -> reject(op, "invalid_operation")
    end
  end

  defp apply(op), do: reject(op, "invalid_operation")

  ## Opening a group

  defp apply_open_group(op) do
    with {:ok, operation_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, guest_id} <- fetch_string(op, "guest_id"),
         {:ok, property_id} <- fetch_string(op, "property_id"),
         {:ok, rate_plan} <- fetch_string(op, "rate_plan", "invalid_rate_plan"),
         {:ok, booked_on} <- fetch_date(op, "occurred_on"),
         {:ok, arrival_on} <- fetch_date(op, "arrival_on"),
         {:ok, departure_on} <- fetch_date(op, "departure_on"),
         {:ok, rooms} <- fetch_rooms(op) do
      open_group(
        op,
        operation_id,
        group_id,
        guest_id,
        property_id,
        rate_plan,
        booked_on,
        arrival_on,
        departure_on,
        rooms
      )
    else
      {:error, code} -> reject(op, code)
    end
  end

  defp open_group(
         op,
         operation_id,
         group_id,
         guest_id,
         property_id,
         rate_plan,
         booked_on,
         arrival_on,
         departure_on,
         rooms
       ) do
    cond do
      Groups.fetch(group_id) ->
        reject(op, "group_already_exists")

      Date.diff(departure_on, arrival_on) < 1 ->
        reject(op, "invalid_stay")

      rate_plan not in @rate_plans ->
        reject(op, "invalid_rate_plan")

      not unique_room_ids?(rooms) ->
        reject(op, "invalid_rooms")

      true ->
        create_group(
          operation_id,
          group_id,
          guest_id,
          property_id,
          rate_plan,
          booked_on,
          arrival_on,
          departure_on,
          rooms
        )
    end
  end

  defp create_group(
         operation_id,
         group_id,
         guest_id,
         property_id,
         rate_plan,
         booked_on,
         arrival_on,
         departure_on,
         rooms
       ) do
    nights = Date.diff(departure_on, arrival_on)

    room_changesets =
      rooms
      |> Enum.with_index(1)
      |> Enum.map(fn {room, position} ->
        lodging_cents = nights * room["nightly_rate_cents"]

        %Room{
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          lodging_cents: lodging_cents,
          deposit_cents: room_deposit(lodging_cents, rate_plan),
          position: position
        }
      end)

    %Group{
      group_id: group_id,
      guest_id: guest_id,
      property_id: property_id,
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      status: "active",
      policy_version: policy_version(rate_plan, booked_on),
      revision: 1,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:rooms, room_changesets)
    |> Repo.insert!()

    %{
      "operation_id" => operation_id,
      "status" => "applied",
      "group_id" => group_id,
      "deposit_due_cents" => sum_deposits(room_changesets),
      "revision" => 1
    }
  end

  ## Recording cash

  defp apply_payment(op) do
    with {:ok, operation_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, _occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, amount_cents} <- fetch_positive_integer(op, "amount_cents", "invalid_amount") do
      pay_group(op, operation_id, group_id, amount_cents)
    else
      {:error, code} -> reject(op, code)
    end
  end

  defp pay_group(op, _operation_id, group_id, _amount_cents) do
    case Groups.fetch(group_id) do
      nil -> reject(op, "group_not_found")
      group -> payment_result(op, group)
    end
  end

  defp payment_result(op, group) do
    amount_cents = op["amount_cents"]

    with :ok <- expected_revision_check(op, group) do
      outstanding = Groups.outstanding_deposit_cents(group)

      cond do
        group.status != "active" ->
          reject(op, "group_not_active")

        amount_cents <= 0 ->
          reject(op, "invalid_amount")

        amount_cents > outstanding ->
          reject(op, "payment_exceeds_outstanding")

        true ->
          new_revision = group.revision + 1

          Repo.update_all(
            from(g in Group, where: g.id == ^group.id),
            inc: [revision: 1, deposit_paid_cents: amount_cents, cash_paid_cents: amount_cents]
          )

          %{
            "operation_id" => op["operation_id"],
            "status" => "applied",
            "group_id" => op["group_id"],
            "amount_cents" => amount_cents,
            "outstanding_deposit_cents" => outstanding - amount_cents,
            "revision" => new_revision
          }
      end
    else
      {:error, result} -> result
    end
  end

  ## Rescheduling

  defp apply_reschedule(op) do
    with {:ok, operation_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, new_arrival_on} <- fetch_date(op, "new_arrival_on") do
      reschedule_group(op, operation_id, group_id, occurred_on, new_arrival_on)
    else
      {:error, code} -> reject(op, code)
    end
  end

  defp reschedule_group(op, operation_id, group_id, occurred_on, new_arrival_on) do
    case Groups.fetch(group_id) do
      nil -> reject(op, "group_not_found")
      group -> reschedule_result(op, operation_id, group, occurred_on, new_arrival_on)
    end
  end

  defp reschedule_result(op, operation_id, group, occurred_on, new_arrival_on) do
    with :ok <- expected_revision_check(op, group) do
      cond do
        group.status != "active" ->
          reject(op, "group_not_active")

        Date.compare(new_arrival_on, occurred_on) != :gt ->
          reject(op, "invalid_stay")

        true ->
          nights = Date.diff(group.departure_on, group.arrival_on)
          new_departure_on = Date.add(new_arrival_on, nights)
          new_revision = group.revision + 1

          Repo.update_all(
            from(g in Group, where: g.id == ^group.id),
            set: [arrival_on: new_arrival_on, departure_on: new_departure_on],
            inc: [revision: 1]
          )

          %{
            "operation_id" => operation_id,
            "status" => "applied",
            "group_id" => group.group_id,
            "new_arrival_on" => new_arrival_on,
            "new_departure_on" => new_departure_on,
            "policy_version" => group.policy_version,
            "refundable_until" => refundable_until(group.policy_version, new_arrival_on),
            "revision" => new_revision
          }
      end
    else
      {:error, result} -> result
    end
  end

  ## Cancelling

  defp apply_cancel(op) do
    with {:ok, operation_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, refund_method} <- fetch_refund_method(op) do
      cancel_group(op, operation_id, group_id, occurred_on, refund_method)
    else
      {:error, code} -> reject(op, code)
    end
  end

  defp fetch_refund_method(op) do
    case op do
      %{"refund_method" => method} when method in @refund_methods -> {:ok, method}
      %{"refund_method" => _other} -> {:error, "invalid_operation"}
      _omitted -> {:ok, "cash"}
    end
  end

  defp cancel_group(op, operation_id, group_id, occurred_on, refund_method) do
    case Groups.fetch(group_id) do
      nil -> reject(op, "group_not_found")
      group -> cancel_result(op, operation_id, group, occurred_on, refund_method)
    end
  end

  defp cancel_result(op, operation_id, group, occurred_on, refund_method) do
    with :ok <- expected_revision_check(op, group) do
      cond do
        group.status != "active" ->
          reject(op, "group_not_active")

        refundable?(group, occurred_on) ->
          settle_refundable(op, operation_id, group, occurred_on, refund_method)

        refund_method == "hotel_credit" ->
          reject(op, "refund_method_not_available")

        true ->
          settle_retained(op, operation_id, group)
      end
    else
      {:error, result} -> result
    end
  end

  defp settle_refundable(op, operation_id, group, occurred_on, refund_method) do
    cash_paid = group.cash_paid_cents

    {refunded_cents, converted_cents, credit_issued_cents} =
      if refund_method == "hotel_credit" and cash_paid > 0 do
        credit_issued = cash_paid + credit_bonus(cash_paid)

        %CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          expires_on: Date.add(occurred_on, @credit_availability_days + 1),
          remaining_cents: credit_issued,
          applied_cents: 0
        }
        |> Repo.insert!()

        {0, cash_paid, credit_issued}
      else
        {cash_paid, 0, 0}
      end

    restore_applied_credit(group, occurred_on)

    cancel_group_record(
      op,
      operation_id,
      group,
      refunded_cents,
      0,
      converted_cents,
      credit_issued_cents
    )
  end

  defp settle_retained(op, operation_id, group) do
    consume_applied_credit(group)

    cancel_group_record(
      op,
      operation_id,
      group,
      0,
      group.cash_paid_cents,
      0,
      0
    )
  end

  defp cancel_group_record(
         _op,
         operation_id,
         group,
         refunded_cents,
         retained_cents,
         converted_cents,
         credit_issued_cents
       ) do
    new_revision = group.revision + 1

    Repo.update_all(
      from(g in Group, where: g.id == ^group.id),
      set: [
        status: "cancelled",
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        cash_converted_to_credit_cents: converted_cents
      ],
      inc: [revision: 1]
    )

    %{
      "operation_id" => operation_id,
      "status" => "applied",
      "group_id" => group.group_id,
      "refunded_cents" => refunded_cents,
      "retained_cents" => retained_cents,
      "credit_issued_cents" => credit_issued_cents,
      "revision" => new_revision
    }
  end

  defp restore_applied_credit(group, occurred_on) do
    Enum.each(group.credit_applications, fn application ->
      lot = application.lot

      if Date.diff(lot.expires_on, occurred_on) > 0 do
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot.id),
          inc: [
            remaining_cents: application.amount_cents,
            applied_cents: -application.amount_cents
          ]
        )

        settle_application(application, "restored")
      else
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot.id),
          inc: [applied_cents: -application.amount_cents]
        )

        settle_application(application, "expired")
      end
    end)
  end

  defp consume_applied_credit(group) do
    Enum.each(group.credit_applications, fn application ->
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^application.lot_id),
        inc: [applied_cents: -application.amount_cents]
      )

      settle_application(application, "consumed")
    end)
  end

  defp settle_application(application, settlement) do
    Repo.update_all(
      from(a in CreditApplication, where: a.id == ^application.id),
      set: [settlement: settlement]
    )
  end

  ## Applying hotel credit

  defp apply_credit(op) do
    with {:ok, operation_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, amount_cents} <- fetch_positive_integer(op, "amount_cents", "invalid_amount") do
      credit_group(op, operation_id, group_id, occurred_on, amount_cents)
    else
      {:error, code} -> reject(op, code)
    end
  end

  defp credit_group(op, _operation_id, group_id, _occurred_on, _amount_cents) do
    case Groups.fetch(group_id) do
      nil -> reject(op, "group_not_found")
      group -> credit_result(op, group)
    end
  end

  defp credit_result(op, group) do
    amount_cents = op["amount_cents"]
    operation_id = op["operation_id"]

    with :ok <- expected_revision_check(op, group) do
      occurred_on = Date.from_iso8601!(op["occurred_on"])
      outstanding = Groups.outstanding_deposit_cents(group)

      cond do
        group.status != "active" ->
          reject(op, "group_not_active")

        amount_cents <= 0 ->
          reject(op, "invalid_amount")

        amount_cents > outstanding ->
          reject(op, "payment_exceeds_outstanding")

        true ->
          apply_from_lots(op, operation_id, group, occurred_on, amount_cents, outstanding)
      end
    else
      {:error, result} -> result
    end
  end

  defp apply_from_lots(op, operation_id, group, occurred_on, amount_cents, outstanding) do
    lots = Credit.available_lots(group.guest_id, occurred_on)
    available = Enum.sum(Enum.map(lots, & &1.remaining_cents))

    if available < amount_cents do
      reject(op, "insufficient_credit")
    else
      {applications, lots_taken} = take_from_lots(lots, amount_cents)

      Enum.each(lots_taken, fn {lot_id, take} ->
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot_id),
          inc: [remaining_cents: -take, applied_cents: take]
        )
      end)

      Enum.each(applications, fn {lot_id, take} ->
        %CreditApplication{
          lot_id: lot_id,
          group_id: group.id,
          amount_cents: take,
          applied_on: occurred_on,
          settlement: "applied"
        }
        |> Repo.insert!()
      end)

      new_revision = group.revision + 1

      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        inc: [revision: 1, deposit_paid_cents: amount_cents, credit_paid_cents: amount_cents]
      )

      %{
        "operation_id" => operation_id,
        "status" => "applied",
        "group_id" => op["group_id"],
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => outstanding - amount_cents,
        "revision" => new_revision
      }
    end
  end

  defp take_from_lots(lots, wanted) do
    {applications_reversed, taken, _left} =
      Enum.reduce_while(lots, {[], %{}, wanted}, fn lot, {applications, taken, left} ->
        case min(lot.remaining_cents, left) do
          0 ->
            {:halt, {applications, taken, left}}

          take ->
            applications = [{lot.id, take} | applications]
            taken = Map.update(taken, lot.id, take, &(&1 + take))

            if take == left do
              {:halt, {applications, taken, 0}}
            else
              {:cont, {applications, taken, left - take}}
            end
        end
      end)

    {Enum.reverse(applications_reversed), taken}
  end

  ## Policy versions and refundability

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version(_rate_plan, booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(policy_version, arrival_on) do
    case Groups.cancellation_window(policy_version) do
      nil -> nil
      window -> Date.add(arrival_on, -window)
    end
  end

  defp refundable?(group, occurred_on) do
    case Groups.cancellation_window(group.policy_version) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp credit_bonus(cash_cents), do: div(cash_cents + 5, 10)

  ## Expected revision contract

  defp expected_revision_check(op, %Group{} = group) do
    case op do
      %{"expected_revision" => expected} when not is_nil(expected) ->
        if expected == group.revision do
          :ok
        else
          {:error,
           reject(op, "stale_revision",
             expected_revision: expected,
             actual_revision: group.revision
           )}
        end

      _ ->
        :ok
    end
  end

  ## Field extraction and validation

  defp fetch_string(op, key, invalid_code \\ "invalid_operation") do
    case op do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => nil} -> {:error, "invalid_operation"}
      %{^key => _value} -> {:error, invalid_code}
      _missing -> {:error, "invalid_operation"}
    end
  end

  defp fetch_date(op, key) do
    case op do
      %{^key => value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      %{^key => nil} ->
        {:error, "invalid_operation"}

      %{^key => _value} ->
        {:error, "invalid_stay"}

      _missing ->
        {:error, "invalid_operation"}
    end
  end

  defp fetch_positive_integer(op, key, invalid_code) do
    case op do
      %{^key => value} when is_integer(value) -> {:ok, value}
      %{^key => nil} -> {:error, "invalid_operation"}
      %{^key => _value} -> {:error, invalid_code}
      _missing -> {:error, "invalid_operation"}
    end
  end

  defp fetch_rooms(op) do
    case op do
      %{"rooms" => rooms} when is_list(rooms) -> parse_rooms(rooms)
      %{"rooms" => _rooms} -> {:error, "invalid_rooms"}
      _missing -> {:error, "invalid_operation"}
    end
  end

  defp parse_rooms(rooms) do
    case Enum.reduce_while(rooms, {:ok, []}, &collect_room/2) do
      {:ok, []} -> {:error, "invalid_rooms"}
      {:ok, rev_rooms} -> {:ok, Enum.reverse(rev_rooms)}
      {:error, _code} = error -> error
    end
  end

  defp collect_room(room, {:ok, acc}) do
    case parse_room(room) do
      {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
      {:error, code} -> {:halt, {:error, code}}
    end
  end

  defp parse_room(room) when is_map(room) do
    with {:ok, room_id} <- fetch_string(room, "room_id", "invalid_rooms"),
         {:ok, nightly_rate_cents} <-
           fetch_positive_integer(room, "nightly_rate_cents", "invalid_rooms"),
         true <- nightly_rate_cents > 0 do
      {:ok, %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}}
    else
      {:error, code} -> {:error, code}
      false -> {:error, "invalid_rooms"}
    end
  end

  defp parse_room(_not_a_map), do: {:error, "invalid_rooms"}

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) == ids |> Enum.uniq() |> length()
  end

  ## Deposit calculation

  # A flexible room requires 20% of its lodging amount, rounded per room to
  # the nearest cent with exact half-cents rounded upward.
  defp room_deposit(lodging_cents, "flexible"), do: div(lodging_cents * 2 + 5, 10)
  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp sum_deposits(rooms), do: rooms |> Enum.map(& &1.deposit_cents) |> Enum.sum()

  ## Rejections

  defp reject(op, code, extra \\ []) when is_list(extra) do
    %{"status" => "rejected", "code" => code}
    |> put_operation_id(op)
    |> put_group_id(op)
    |> Map.merge(Map.new(extra))
  end

  defp put_operation_id(result, %{"operation_id" => operation_id}) when is_binary(operation_id) do
    Map.put(result, "operation_id", operation_id)
  end

  defp put_operation_id(result, _op), do: result

  defp put_group_id(result, %{"group_id" => group_id}) when is_binary(group_id) do
    Map.put(result, "group_id", group_id)
  end

  defp put_group_id(result, _op), do: result
end
