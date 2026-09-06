defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, Operation, Room}

  @rate_plans ["flexible", "advance_purchase"]

  def process(%{"operation_id" => operation_id} = operation)
      when is_binary(operation_id) and operation_id != "" do
    {:ok, result} =
      Repo.transact(
        fn -> {:ok, process_durable(operation_id, operation)} end,
        mode: :immediate
      )

    result
  end

  def process(operation) when is_map(operation),
    do: rejected_result(operation["operation_id"], %{"code" => "invalid_operation"})

  def process(_operation),
    do: %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}

  def get_operation(operation_id) when is_binary(operation_id) do
    Repo.get_by(Operation, operation_id: operation_id)
  end

  def get_operation(_operation_id), do: nil

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_group_id), do: nil

  def group_json(%Group{} = group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => format_date(refundable_until(group)),
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  def report_date(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def report_date(%{"on" => _}), do: :error
  def report_date(_params), do: {:ok, Date.utc_today()}

  def ledger(on \\ Date.utc_today()) do
    active_cash =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.cash_paid_cents), 0)
      )

    settlements =
      Repo.one(
        from g in Group,
          select:
            {coalesce(sum(g.refunded_cents), 0), coalesce(sum(g.retained_cents), 0),
             coalesce(sum(g.cash_converted_to_credit_cents), 0)}
      )

    {refunded, retained, converted} = settlements

    available_credit =
      Repo.one(
        from l in CreditLot,
          where: l.issued_on <= ^on and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    allocated_credit =
      Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))

    %{
      "cash_held_cents" => active_cash,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "credit_liability_cents" => available_credit + allocated_credit
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^guest_id and l.remaining_cents > 0 and l.issued_on <= ^on and
              l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum_by(lots, & &1.remaining_cents),
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

  defp process_durable(operation_id, submission) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{submission: stored_submission, result: result} ->
        if stored_submission === submission do
          result
        else
          rejected_result(operation_id, %{"code" => "operation_id_conflict"})
        end

      nil ->
        result = execute(submission, operation_id)
        operation_type = if is_binary(submission["type"]), do: submission["type"]

        Repo.insert!(
          Operation.changeset(%Operation{}, %{
            operation_id: operation_id,
            operation_type: operation_type,
            submission: submission,
            result: result
          })
        )

        result
    end
  end

  defp execute(operation, operation_id) do
    case apply_operation(operation) do
      {:ok, fields} ->
        fields |> Map.put("status", "applied") |> Map.put("operation_id", operation_id)

      {:error, fields} ->
        rejected_result(operation_id, fields)
    end
  end

  defp rejected_result(operation_id, fields) do
    fields |> Map.put("status", "rejected") |> Map.put("operation_id", operation_id)
  end

  defp apply_operation(
         %{"operation_id" => operation_id, "type" => type, "occurred_on" => occurred_on} = op
       )
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on) do
    with {:ok, date} <- Date.from_iso8601(occurred_on) do
      case type do
        "open_group" -> open_group(op, date)
        "record_cash_payment" -> with_group(op, &record_cash_payment(&1, op))
        "apply_hotel_credit" -> with_group(op, &apply_hotel_credit(&1, op, date))
        "reschedule_group" -> with_group(op, &reschedule_group(&1, op, date))
        "cancel_group" -> with_group(op, &cancel_group(&1, op, date))
        _ -> reject("invalid_operation")
      end
    else
      _ -> reject("invalid_operation")
    end
  end

  defp apply_operation(_operation), do: reject("invalid_operation")

  defp open_group(op, booked_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(op, &1)) do
      do_open_group(op, booked_on)
    else
      reject("invalid_operation")
    end
  end

  defp do_open_group(op, booked_on) do
    with :ok <- validate_identifier(op["group_id"]),
         :ok <- validate_identifier(op["guest_id"]),
         :ok <- validate_identifier(op["property_id"]),
         :ok <- validate_group_is_new(op["group_id"]),
         {:ok, arrival_on} <- parse_date(op["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(op["departure_on"], "invalid_stay"),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on),
         :ok <- validate_rate_plan(op["rate_plan"]),
         {:ok, rooms} <- validate_rooms(op["rooms"]) do
      lodging_total = Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))

      deposit_due =
        Enum.sum_by(rooms, fn room ->
          lodging = room["nightly_rate_cents"] * nights
          if op["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        end)

      attrs = %{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: op["rate_plan"],
        policy_version: policy_version(op["rate_plan"], booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          Enum.with_index(rooms)
          |> Enum.each(fn {room, position} ->
            room
            |> Map.put("position", position)
            |> Map.put("group_reservation_id", group.id)
            |> then(&Repo.insert!(Room.changeset(%Room{}, &1)))
          end)

          {:ok,
           %{
             "group_id" => group.group_id,
             "deposit_due_cents" => deposit_due,
             "revision" => 1
           }}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id),
            do: reject("group_already_exists"),
            else: reject("invalid_operation")
      end
    else
      {:error, code} -> reject(code)
      _ -> reject("invalid_stay")
    end
  end

  defp with_group(%{"group_id" => group_id} = op, callback)
       when is_binary(group_id) and group_id != "" do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject("group_not_found", %{"group_id" => group_id})

      group ->
        case check_revision(group, op) do
          :ok -> callback.(group)
          error -> error
        end
    end
  end

  defp with_group(_op, _callback), do: reject("invalid_operation")

  defp check_revision(group, %{"expected_revision" => expected}) when is_integer(expected) do
    if expected == group.revision do
      :ok
    else
      reject("stale_revision", %{
        "group_id" => group.group_id,
        "expected_revision" => expected,
        "actual_revision" => group.revision
      })
    end
  end

  defp check_revision(_group, %{"expected_revision" => _}), do: reject("invalid_operation")
  defp check_revision(_group, _op), do: :ok

  defp record_cash_payment(group, op) do
    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) ->
        reject("invalid_amount")

      op["amount_cents"] > outstanding(group) ->
        reject("payment_exceeds_outstanding")

      true ->
        amount = op["amount_cents"]

        updated =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })

        {:ok,
         %{
           "group_id" => group.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding(updated),
           "revision" => updated.revision
         }}
    end
  end

  defp reschedule_group(group, op, occurred_on) do
    cond do
      not Map.has_key?(op, "new_arrival_on") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      true ->
        with {:ok, new_arrival} <- parse_date(op["new_arrival_on"], "invalid_stay"),
             true <- Date.after?(new_arrival, occurred_on) do
          shift = Date.diff(new_arrival, group.arrival_on)
          new_departure = Date.add(group.departure_on, shift)
          updated = update_group!(group, %{arrival_on: new_arrival, departure_on: new_departure})

          {:ok,
           %{
             "group_id" => group.group_id,
             "new_arrival_on" => Date.to_iso8601(new_arrival),
             "new_departure_on" => Date.to_iso8601(new_departure),
             "policy_version" => updated.policy_version,
             "refundable_until" => format_date(refundable_until(updated)),
             "revision" => updated.revision
           }}
        else
          _ -> reject("invalid_stay")
        end
    end
  end

  defp apply_hotel_credit(group, op, occurred_on) do
    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) ->
        reject("invalid_amount")

      op["amount_cents"] > outstanding(group) ->
        reject("payment_exceeds_outstanding")

      true ->
        lots = available_lots(group.guest_id, occurred_on)
        amount = op["amount_cents"]

        if Enum.sum_by(lots, & &1.remaining_cents) < amount do
          reject("insufficient_credit")
        else
          consume_credit!(lots, group, amount)

          updated =
            update_group!(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: group.credit_paid_cents + amount
            })

          {:ok,
           %{
             "group_id" => group.group_id,
             "amount_cents" => amount,
             "outstanding_deposit_cents" => outstanding(updated),
             "revision" => updated.revision
           }}
        end
    end
  end

  defp cancel_group(group, op, occurred_on) do
    refund_method = Map.get(op, "refund_method", "cash")

    cond do
      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      refund_method not in ["cash", "hotel_credit"] ->
        reject("invalid_operation")

      refund_method == "hotel_credit" and not refundable?(group, occurred_on) ->
        reject("refund_method_not_available")

      true ->
        settle_cancellation(group, op["operation_id"], refund_method, occurred_on)
    end
  end

  defp settle_cancellation(group, operation_id, refund_method, occurred_on) do
    refundable = refundable?(group, occurred_on)
    refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    credit_issued =
      if refundable and refund_method == "hotel_credit" and group.cash_paid_cents > 0 do
        bonus = div(group.cash_paid_cents * 10 + 50, 100)
        amount = group.cash_paid_cents + bonus

        Repo.insert!(
          CreditLot.changeset(%CreditLot{}, %{
            guest_id: group.guest_id,
            source_operation_id: operation_id,
            remaining_cents: amount,
            issued_on: occurred_on,
            expires_on: Date.add(occurred_on, 365)
          })
        )

        amount
      else
        0
      end

    settle_allocated_credit!(group, refundable, occurred_on)

    converted =
      if refundable and refund_method == "hotel_credit", do: group.cash_paid_cents, else: 0

    updated =
      update_group!(group, %{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained,
        cash_converted_to_credit_cents: converted
      })

    {:ok,
     %{
       "group_id" => group.group_id,
       "refunded_cents" => refunded,
       "retained_cents" => retained,
       "credit_issued_cents" => credit_issued,
       "revision" => updated.revision
     }}
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where:
          l.guest_id == ^guest_id and l.remaining_cents > 0 and l.issued_on <= ^on and
            l.expires_on >= ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp consume_credit!(lots, group, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)

      lot
      |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - used})
      |> Repo.update!()

      Repo.insert!(
        CreditAllocation.changeset(%CreditAllocation{}, %{
          credit_lot_id: lot.id,
          group_reservation_id: group.id,
          amount_cents: used
        })
      )

      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp settle_allocated_credit!(group, refundable, occurred_on) do
    allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_reservation_id == ^group.id,
          preload: [:credit_lot]
      )

    Enum.each(allocations, fn allocation ->
      if refundable and not Date.before?(allocation.credit_lot.expires_on, occurred_on) do
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^allocation.credit_lot_id),
          inc: [remaining_cents: allocation.amount_cents]
        )
      end

      Repo.delete!(allocation)
    end)
  end

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    unique = Enum.uniq_by(rooms, &Map.get(&1, "room_id")) == rooms
    if valid and unique, do: {:ok, rooms}, else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_identifier(value) when is_binary(value) and value != "", do: :ok
  defp validate_identifier(_value), do: {:error, "invalid_operation"}

  defp validate_group_is_new(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, ~D[2027-01-01]), do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(%Group{}), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> not Date.after?(occurred_on, deadline)
    end
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_value, code), do: {:error, code}

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0

  defp reject(code, fields \\ %{}), do: {:error, Map.put(fields, "code", code)}
end
