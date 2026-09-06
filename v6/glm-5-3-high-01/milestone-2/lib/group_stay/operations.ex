defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and reports the outcome of each one.

  Each operation runs in its own transaction so a rejection leaves the database
  exactly as it was before that operation began while processing continues with
  the next operation in the batch.
  """

  alias Ecto.Changeset
  alias GroupStay.Groups
  alias GroupStay.Repo
  alias GroupStay.Schemas.{CreditApplication, CreditLot, Group, LedgerEntry, Room}

  import Ecto.Query, only: [from: 2]

  @operation_types [
    "open_group",
    "record_cash_payment",
    "reschedule_group",
    "cancel_group",
    "apply_hotel_credit"
  ]
  @rate_plans ["flexible", "advance_purchase"]
  @flexible_deposit_numerator 20
  @credit_bonus_numerator 110
  @credit_validity_days 365

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(raw) do
    case Repo.transaction(fn -> run(raw) end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp run(raw) when is_map(raw) do
    operation_id = raw["operation_id"]

    with :ok <- ensure_identifier(operation_id),
         {:ok, type} <- ensure_operation_type(raw["type"]),
         {:ok, occurred_on} <- fetch_occurred_on(raw["occurred_on"]),
         :ok <- ensure_identifier(raw["group_id"]) do
      dispatch(type, raw, operation_id, occurred_on, raw["group_id"])
    else
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp run(_raw), do: reject(nil, "invalid_operation")

  defp dispatch("open_group", raw, operation_id, occurred_on, group_ref) do
    with :ok <- ensure_absent(group_ref),
         :ok <- ensure_identifier(raw["guest_id"]),
         :ok <- ensure_identifier(raw["property_id"]),
         {:ok, arrival_on, departure_on} <- parse_stay(raw),
         {:ok, rooms} <- parse_rooms(raw["rooms"]),
         :ok <- ensure_rate_plan(raw["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = lodging_total_cents(nights, rooms)
      deposit_due = deposit_due_cents(raw["rate_plan"], nights, rooms)

      {:ok, group} =
        Repo.insert(%Group{
          group_id: group_ref,
          guest_id: raw["guest_id"],
          property_id: raw["property_id"],
          arrival_on: arrival_on,
          departure_on: departure_on,
          booked_on: occurred_on,
          rate_plan: raw["rate_plan"],
          policy_version: Groups.policy_version(raw["rate_plan"], occurred_on),
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0
        })

      rooms
      |> Enum.with_index(1)
      |> Enum.each(fn {{room_id, nightly_rate_cents}, position} ->
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: room_id,
          nightly_rate_cents: nightly_rate_cents,
          position: position
        })
      end)

      applied(operation_id, %{
        group_id: group_ref,
        deposit_due_cents: deposit_due,
        revision: group.revision
      })
    else
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("record_cash_payment", raw, operation_id, occurred_on, group_ref) do
    amount = raw["amount_cents"]

    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         :ok <- ensure_amount(amount),
         :ok <- ensure_within_outstanding(group, amount) do
      {:ok, updated} =
        group
        |> Changeset.change(
          deposit_paid_cents: group.deposit_paid_cents + amount,
          cash_paid_cents: group.cash_paid_cents + amount,
          revision: group.revision + 1
        )
        |> Repo.update()

      insert_ledger_entry(group, operation_id, occurred_on, "payment", amount)

      applied(operation_id, %{
        group_id: group_ref,
        amount_cents: amount,
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(updated),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("reschedule_group", raw, operation_id, occurred_on, group_ref) do
    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- parse_stay_date(raw["new_arrival_on"]),
         :ok <- ensure_after_occurrence(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      {:ok, updated} =
        group
        |> Changeset.change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        )
        |> Repo.update()

      applied(operation_id, %{
        group_id: group_ref,
        new_arrival_on: Date.to_iso8601(new_arrival_on),
        new_departure_on: Date.to_iso8601(new_departure_on),
        policy_version: updated.policy_version,
        refundable_until: iso_date(Groups.refundable_until(updated)),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("cancel_group", raw, operation_id, occurred_on, group_ref) do
    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- ensure_refund_method(raw["refund_method"]),
         :ok <- ensure_refund_method_available(refund_method, group, occurred_on) do
      refundable = Groups.refundable?(group, occurred_on)
      cash = group.cash_paid_cents

      {refunded, retained, converted, issued} =
        cond do
          not refundable -> {0, cash, 0, 0}
          refund_method == "hotel_credit" -> {0, 0, cash, credit_lot_amount(cash)}
          true -> {cash, 0, 0, 0}
        end

      if refundable, do: restore_applied_credit(group)

      if issued > 0 do
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, @credit_validity_days)
        })
      end

      {:ok, updated} =
        group
        |> Changeset.change(
          status: "cancelled",
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: group.converted_to_credit_cents + converted,
          revision: group.revision + 1
        )
        |> Repo.update()

      if refunded > 0,
        do: insert_ledger_entry(group, operation_id, occurred_on, "refund", refunded)

      if retained > 0,
        do: insert_ledger_entry(group, operation_id, occurred_on, "retention", retained)

      applied(operation_id, %{
        group_id: group_ref,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: issued,
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("apply_hotel_credit", raw, operation_id, occurred_on, group_ref) do
    amount = raw["amount_cents"]

    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         :ok <- ensure_amount(amount),
         :ok <- ensure_within_outstanding(group, amount),
         :ok <- ensure_sufficient_credit(group, amount, occurred_on) do
      consume_credit(group, available_credit_lots(group.guest_id, occurred_on), amount)

      {:ok, updated} =
        group
        |> Changeset.change(
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: group.revision + 1
        )
        |> Repo.update()

      applied(operation_id, %{
        group_id: group_ref,
        amount_cents: amount,
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(updated),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp ensure_refund_method(refund_method) when refund_method in [nil, "cash", "hotel_credit"],
    do: {:ok, refund_method || "cash"}

  defp ensure_refund_method(_refund_method), do: {:error, "invalid_operation"}

  defp ensure_refund_method_available("hotel_credit", group, occurred_on) do
    if Groups.refundable?(group, occurred_on),
      do: :ok,
      else: {:error, "refund_method_not_available"}
  end

  defp ensure_refund_method_available(_refund_method, _group, _occurred_on), do: :ok

  defp credit_lot_amount(cash), do: round_half_up_to_cent(cash * @credit_bonus_numerator)

  defp available_credit_lots(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  defp ensure_sufficient_credit(group, amount, occurred_on) do
    available =
      group.guest_id
      |> available_credit_lots(occurred_on)
      |> Enum.map(& &1.remaining_cents)
      |> Enum.sum()

    if available >= amount, do: :ok, else: {:error, "insufficient_credit"}
  end

  defp consume_credit(_group, _lots, 0), do: :ok

  defp consume_credit(group, [lot | rest], amount) do
    take = min(lot.remaining_cents, amount)

    lot
    |> Changeset.change(remaining_cents: lot.remaining_cents - take)
    |> Repo.update!()

    if take > 0 do
      Repo.insert!(%CreditApplication{
        group_id: group.id,
        credit_lot_id: lot.id,
        amount_cents: take
      })
    end

    consume_credit(group, rest, amount - take)
  end

  defp restore_applied_credit(group) do
    group_id = group.id

    from(a in CreditApplication, where: a.group_id == ^group_id, preload: [:credit_lot])
    |> Repo.all()
    |> Enum.each(fn application ->
      lot = application.credit_lot

      lot
      |> Changeset.change(remaining_cents: lot.remaining_cents + application.amount_cents)
      |> Repo.update!()
    end)
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp insert_ledger_entry(group, operation_id, occurred_on, kind, amount) do
    Repo.insert!(%LedgerEntry{
      group_id: group.id,
      operation_id: operation_id,
      kind: kind,
      amount_cents: amount,
      occurred_on: occurred_on
    })
  end

  defp lodging_total_cents(nights, rooms),
    do: rooms |> Enum.map(fn {_room_id, rate} -> nights * rate end) |> Enum.sum()

  defp deposit_due_cents("flexible", nights, rooms) do
    rooms
    |> Enum.map(fn {_room_id, rate} ->
      round_half_up_to_cent(nights * rate * @flexible_deposit_numerator)
    end)
    |> Enum.sum()
  end

  defp deposit_due_cents("advance_purchase", nights, rooms),
    do: lodging_total_cents(nights, rooms)

  defp round_half_up_to_cent(amount), do: div(amount + 50, 100)

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp reject(operation_id, code, extras \\ %{}) do
    base = %{status: "rejected", code: code}

    base =
      if is_binary(operation_id), do: Map.put(base, :operation_id, operation_id), else: base

    Map.merge(base, extras)
  end

  defp ensure_identifier(value) when is_binary(value) and value != "", do: :ok
  defp ensure_identifier(_value), do: {:error, "invalid_operation"}

  defp ensure_operation_type(type) when type in @operation_types, do: {:ok, type}
  defp ensure_operation_type(_type), do: {:error, "invalid_operation"}

  defp fetch_occurred_on(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp parse_stay(raw) do
    with {:ok, arrival_on} <- parse_stay_date(raw["arrival_on"]),
         {:ok, departure_on} <- parse_stay_date(raw["departure_on"]),
         :ok <- ensure_nights(arrival_on, departure_on) do
      {:ok, arrival_on, departure_on}
    end
  end

  defp parse_stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_stay"}
    end
  end

  defp ensure_nights(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: {:error, "invalid_stay"}
  end

  defp ensure_after_occurrence(new_arrival_on, occurred_on) do
    if Date.diff(new_arrival_on, occurred_on) >= 1, do: :ok, else: {:error, "invalid_stay"}
  end

  defp parse_rooms(rooms) when is_list(rooms) do
    parsed = Enum.map(rooms, &parse_room/1)

    if Enum.all?(parsed, &match?({:ok, _room}, &1)) do
      rooms = Enum.map(parsed, fn {:ok, room} -> room end)
      room_ids = Enum.map(rooms, fn {room_id, _rate} -> room_id end)

      if rooms != [] and Enum.uniq(room_ids) == room_ids,
        do: {:ok, rooms},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp parse_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp parse_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0,
       do: {:ok, {room_id, rate}}

  defp parse_room(_room), do: :error

  defp ensure_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp ensure_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp ensure_absent(group_ref) do
    if Repo.get_by(Group, group_id: group_ref) == nil,
      do: :ok,
      else: {:error, "group_already_exists"}
  end

  defp fetch_group(group_ref) do
    case Repo.get_by(Group, group_id: group_ref) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp ensure_revision(raw, group) do
    case raw do
      %{"expected_revision" => expected} when expected != group.revision ->
        {:error, "stale_revision",
         %{group_id: group.group_id, expected_revision: expected, actual_revision: group.revision}}

      _other ->
        :ok
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, "group_not_active"}

  defp ensure_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp ensure_amount(_amount), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount) do
    if amount <= Groups.outstanding_deposit_cents(group),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end
end
