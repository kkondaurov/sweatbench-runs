defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in batch order.

  Every operation runs in its own transaction: a rejection leaves the
  database exactly as it was before the operation began, and processing
  continues with the next operation. An operation observes changes made by
  earlier operations in the same batch.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Groups
  alias GroupStay.Groups.{CashPayment, CreditApplication, CreditLot, Group, Room}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_validity_days 365
  @max_attempts 3

  @doc """
  Applies each operation in order and returns one result per operation.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(%{"type" => "open_group"} = op), do: run(fn -> open_group(op) end)

  defp apply_operation(%{"type" => "record_cash_payment"} = op),
    do: run(fn -> record_cash_payment(op) end)

  defp apply_operation(%{"type" => "reschedule_group"} = op),
    do: run(fn -> reschedule_group(op) end)

  defp apply_operation(%{"type" => "cancel_group"} = op), do: run(fn -> cancel_group(op) end)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = op),
    do: run(fn -> apply_hotel_credit(op) end)

  defp apply_operation(op) when is_map(op),
    do: rejected(Map.get(op, "operation_id"), "invalid_operation")

  defp apply_operation(_other), do: rejected(nil, "invalid_operation")

  # Each operation gets its own transaction. A rejection performs no writes,
  # so committing it leaves the database unchanged. A concurrent writer can
  # trip the revision guard; the operation is then retried against fresh
  # state.
  defp run(fun, attempt \\ 1) do
    case Repo.transaction(fun) do
      {:ok, result} ->
        result

      {:error, :stale_group} when attempt < @max_attempts ->
        run(fun, attempt + 1)

      {:error, reason} ->
        raise "operation could not be applied: #{inspect(reason)}"
    end
  end

  ## open_group

  defp open_group(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, guest_id} <- fetch_string(op, "guest_id"),
         {:ok, property_id} <- fetch_string(op, "property_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, arrival_on} <- fetch_date(op, "arrival_on"),
         {:ok, departure_on} <- fetch_date(op, "departure_on"),
         {:ok, rate_plan} <- fetch_string(op, "rate_plan"),
         {:ok, rooms} <- fetch_rooms(op),
         :ok <- ensure_group_absent(group_id),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rooms(rooms),
         :ok <- validate_rate_plan(rate_plan) do
      create_group(op_id, %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        occurred_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    else
      {:error, code} -> rejected(Map.get(op, "operation_id"), code)
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) do
    cond do
      rooms == [] ->
        {:error, "invalid_rooms"}

      Enum.any?(rooms, &invalid_room?/1) ->
        {:error, "invalid_rooms"}

      length(Enum.uniq_by(rooms, & &1["room_id"])) != length(rooms) ->
        {:error, "invalid_rooms"}

      true ->
        :ok
    end
  end

  defp invalid_room?(room) when not is_map(room), do: true

  defp invalid_room?(room) do
    not valid_identifier?(room["room_id"]) or not positive_integer?(room["nightly_rate_cents"])
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      {:error, "invalid_rate_plan"}
    end
  end

  defp create_group(op_id, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms =
      Enum.map(attrs.rooms, fn room ->
        nightly_rate_cents = room["nightly_rate_cents"]
        lodging_cents = nights * nightly_rate_cents

        %{
          room_id: room["room_id"],
          nightly_rate_cents: nightly_rate_cents,
          lodging_cents: lodging_cents,
          deposit_cents: room_deposit(lodging_cents, attrs.rate_plan)
        }
      end)

    lodging_total_cents = rooms |> Enum.map(& &1.lodging_cents) |> Enum.sum()
    deposit_due_cents = rooms |> Enum.map(& &1.deposit_cents) |> Enum.sum()

    changeset =
      %Group{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        booked_on: attrs.occurred_on,
        rate_plan: attrs.rate_plan,
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        rooms:
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            %Room{
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: position
            }
          end)
      }
      |> Changeset.change()
      |> Changeset.unique_constraint(:group_id)

    case Repo.insert(changeset) do
      {:ok, group} ->
        applied(op_id, %{
          "group_id" => group.group_id,
          "deposit_due_cents" => deposit_due_cents,
          "revision" => group.revision
        })

      {:error, _changeset} ->
        rejected(op_id, "group_already_exists")
    end
  end

  # Flexible rooms deposit a percentage of their own lodging amount, rounded
  # per room; advance-purchase rooms deposit their full lodging amount.
  defp room_deposit(lodging_cents, "flexible") do
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  # Rounds numerator / denominator to the nearest integer; an exact half
  # rounds upward.
  defp round_half_up(numerator, denominator) do
    div(2 * numerator + denominator, 2 * denominator)
  end

  ## record_cash_payment

  defp record_cash_payment(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, amount_cents} <- fetch_present(op, "amount_cents"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_amount(amount_cents),
         :ok <- validate_outstanding(group, amount_cents) do
      apply_payment(op_id, group, amount_cents, occurred_on)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  defp validate_amount(amount_cents) do
    if positive_integer?(amount_cents) do
      :ok
    else
      {:error, "invalid_amount"}
    end
  end

  defp validate_outstanding(group, amount_cents) do
    if amount_cents <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp apply_payment(op_id, group, amount_cents, occurred_on) do
    Repo.insert!(%CashPayment{
      group_id: group.id,
      amount_cents: amount_cents,
      occurred_on: occurred_on,
      operation_id: stored_operation_id(op_id)
    })

    group = bump_group!(group, deposit_paid_cents: group.deposit_paid_cents + amount_cents)

    applied(op_id, %{
      "group_id" => group.group_id,
      "amount_cents" => amount_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
      "revision" => group.revision
    })
  end

  ## reschedule_group

  defp reschedule_group(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, new_arrival_on} <- fetch_date(op, "new_arrival_on"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      apply_reschedule(op_id, group, new_arrival_on)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp apply_reschedule(op_id, group, new_arrival_on) do
    # The departure shifts by the same number of days, so the length and
    # price of the stay are unchanged.
    stay_length = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, stay_length)

    group =
      bump_group!(group,
        arrival_on: new_arrival_on,
        departure_on: new_departure_on
      )

    applied(op_id, %{
      "group_id" => group.group_id,
      "new_arrival_on" => Date.to_iso8601(new_arrival_on),
      "new_departure_on" => Date.to_iso8601(new_departure_on),
      "policy_version" => Groups.policy_version(group),
      "refundable_until" => Date.to_iso8601(Groups.refundable_until(group)),
      "revision" => group.revision
    })
  end

  ## cancel_group

  defp cancel_group(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, refund_method} <- fetch_refund_method(op),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_refund_method_available(group, occurred_on, refund_method) do
      apply_cancellation(op_id, group, occurred_on, refund_method)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  # Omitting the refund method preserves the existing cash behavior.
  defp fetch_refund_method(op) do
    case Map.get(op, "refund_method") do
      nil -> {:ok, "cash"}
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _other -> {:error, "invalid_operation"}
    end
  end

  # Hotel credit is not a way around a non-refundable policy.
  defp validate_refund_method_available(group, occurred_on, "hotel_credit") do
    if Groups.refundable?(group, occurred_on) do
      :ok
    else
      {:error, "refund_method_not_available"}
    end
  end

  defp validate_refund_method_available(_group, _occurred_on, "cash"), do: :ok

  defp apply_cancellation(op_id, group, occurred_on, refund_method) do
    cash_paid = Groups.cash_paid_cents(group)
    refundable = Groups.refundable?(group, occurred_on)
    applications = credit_applications_for(group)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      settle(group, cash_paid, refundable, refund_method, op_id, occurred_on)

    if refundable do
      restore_credit(applications, occurred_on)
    else
      consume_credit(applications)
    end

    group =
      bump_group!(group,
        status: "cancelled",
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        converted_cents: converted_cents
      )

    applied(op_id, %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded_cents,
      "retained_cents" => retained_cents,
      "credit_issued_cents" => credit_issued_cents,
      "revision" => group.revision
    })
  end

  # On a refundable cancellation cash is refunded, or converted to a credit
  # lot worth 110% of the cash when hotel credit is selected; the converted
  # cash is then neither refunded nor retained. A non-refundable
  # cancellation retains the cash.
  defp settle(_group, cash_paid, true, "cash", _op_id, _occurred_on) do
    {cash_paid, 0, 0, 0}
  end

  defp settle(group, cash_paid, true, "hotel_credit", op_id, occurred_on) do
    credit_issued_cents = issue_credit_lot(group.guest_id, op_id, cash_paid, occurred_on)
    {0, 0, cash_paid, credit_issued_cents}
  end

  defp settle(_group, cash_paid, false, "cash", _op_id, _occurred_on) do
    {0, cash_paid, 0, 0}
  end

  # The lot is worth the cash plus a 10% bonus (the standard rounding rule
  # applies to the bonus), is available through 365 days after the
  # cancellation, and expires the following day. Nothing is issued when the
  # cancellation converted no cash.
  defp issue_credit_lot(_guest_id, _op_id, 0, _occurred_on), do: 0

  defp issue_credit_lot(guest_id, op_id, cash_cents, occurred_on) do
    bonus_cents = round_half_up(cash_cents * @credit_bonus_percent, 100)
    amount_cents = cash_cents + bonus_cents

    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: op_id,
      original_cents: amount_cents,
      remaining_cents: amount_cents,
      expires_on: Date.add(occurred_on, @credit_validity_days)
    })

    amount_cents
  end

  defp credit_applications_for(group) do
    Repo.all(
      from a in CreditApplication,
        where: a.group_id == ^group.id,
        order_by: [asc: a.id],
        preload: [:lot]
    )
  end

  # Applied credit returns to its original lot with its original expiry and
  # never receives a second bonus. A lot whose expiry is already past on the
  # cancellation date expires immediately instead of becoming available
  # again.
  defp restore_credit(applications, occurred_on) do
    Enum.each(applications, fn application ->
      if Date.compare(application.lot.expires_on, occurred_on) != :lt do
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^application.lot_id),
          inc: [remaining_cents: application.amount_cents]
        )
      end

      Repo.delete!(application)
    end)
  end

  # On a non-refundable cancellation applied hotel credit is consumed.
  defp consume_credit(applications) do
    Enum.each(applications, &Repo.delete!/1)
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, amount_cents} <- fetch_present(op, "amount_cents"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_amount(amount_cents),
         :ok <- validate_outstanding(group, amount_cents),
         {:ok, lots} <- fetch_usable_lots(group.guest_id, occurred_on, amount_cents) do
      apply_credit(op_id, group, amount_cents, lots)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  # Credit application evaluates expiry using the operation's occurred_on
  # date. Lots are consumed by earliest expiry, then by source operation for
  # equal expiries.
  defp fetch_usable_lots(guest_id, occurred_on, amount_cents) do
    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    if lots |> Enum.map(& &1.remaining_cents) |> Enum.sum() >= amount_cents do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp apply_credit(op_id, group, amount_cents, lots) do
    lots
    |> allocate(amount_cents)
    |> Enum.each(fn {lot, applied_cents} ->
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [remaining_cents: -applied_cents]
      )

      Repo.insert!(%CreditApplication{
        lot_id: lot.id,
        group_id: group.id,
        amount_cents: applied_cents
      })
    end)

    group =
      bump_group!(group,
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        credit_paid_cents: group.credit_paid_cents + amount_cents
      )

    applied(op_id, %{
      "group_id" => group.group_id,
      "amount_cents" => amount_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
      "revision" => group.revision
    })
  end

  defp allocate(_lots, 0), do: []

  defp allocate([lot | lots], remaining_cents) do
    take = min(lot.remaining_cents, remaining_cents)
    [{lot, take} | allocate(lots, remaining_cents - take)]
  end

  ## Shared helpers

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  # Group existence is resolved before comparing revisions; a stale revision
  # is rejected before the operation's other domain rules.
  defp check_expected_revision(op, group) do
    case Map.get(op, "expected_revision") do
      nil ->
        :ok

      expected ->
        if expected == group.revision do
          :ok
        else
          {:stale, expected, group.revision, group}
        end
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(%Group{}), do: {:error, "group_not_active"}

  defp fetch_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp fetch_date(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, "invalid_operation"}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  defp fetch_present(op, key) do
    case Map.fetch(op, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp fetch_rooms(op) do
    case Map.get(op, "rooms") do
      rooms when is_list(rooms) -> {:ok, rooms}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp stored_operation_id(op_id) when is_binary(op_id), do: op_id
  defp stored_operation_id(_op_id), do: nil

  # Applies the given field changes and increments the group's revision
  # exactly once. The revision guard keeps concurrent updates from
  # clobbering each other.
  defp bump_group!(%Group{} = group, fields) do
    now = NaiveDateTime.utc_now(:second)

    {updated, _} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision),
        set: fields ++ [revision: group.revision + 1, updated_at: now]
      )

    if updated != 1 do
      Repo.rollback(:stale_group)
    end

    Repo.get!(Group, group.id)
  end

  defp applied(op_id, fields) do
    Map.merge(%{"operation_id" => op_id, "status" => "applied"}, fields)
  end

  defp rejected(op_id, code) do
    %{"operation_id" => op_id, "status" => "rejected", "code" => code}
  end

  defp stale_rejected(op_id, group, expected_revision, actual_revision) do
    %{
      "operation_id" => op_id,
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group.group_id,
      "expected_revision" => expected_revision,
      "actual_revision" => actual_revision
    }
  end
end
