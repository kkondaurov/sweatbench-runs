defmodule GroupStay.Groups do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @flex30_start ~D[2027-01-01]

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_one/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        Repo.preload(group, rooms: from(r in Room, order_by: [asc: r.position]))
    end
  end

  def serialize_group(%Group{} = group) do
    rooms =
      group.rooms
      |> Enum.sort_by(& &1.position)
      |> Enum.map(fn room ->
        %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
      end)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents
    }
  end

  def parse_as_of(nil), do: Date.utc_today()

  def parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  def parse_as_of(_value), do: Date.utc_today()

  def guest_credit(guest_id, on_date) when is_binary(guest_id) do
    lots =
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on_date,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()
      |> Enum.map(fn lot ->
        %{
          source_operation_id: lot.source_operation_id,
          remaining_cents: lot.remaining_cents,
          expires_on: lot.expires_on
        }
      end)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end),
      lots: lots
    }
  end

  def ledger(on_date \\ nil) do
    on_date = on_date || Date.utc_today()

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
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      ) ||
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0
        }

    available_credit =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on_date,
          select: coalesce(sum(l.remaining_cents), 0)
      ) || 0

    applied_credit =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.credit_paid_cents), 0)
      ) || 0

    Map.put(totals, :credit_liability_cents, available_credit + applied_credit)
  end

  defp process_one(operation) do
    operation = stringify_keys(operation)

    case Repo.transaction(fn -> dispatch(operation) end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp dispatch(operation) when is_map(operation) do
    case field(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      _ -> rollback_rejected(operation, "invalid_operation")
    end
  end

  defp dispatch(operation), do: rollback_rejected(operation, "invalid_operation")

  defp open_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, guest_id} <- require_id(operation, "guest_id"),
         {:ok, property_id} <- require_id(operation, "property_id"),
         {:ok, booked_on} <- require_iso_date(operation, "occurred_on"),
         {:ok, rate_plan} <- require_present(operation, "rate_plan"),
         {:ok, rooms_input} <- require_present(operation, "rooms"),
         {:ok, arrival_on, departure_on, nights} <-
           require_stay(operation, "arrival_on", "departure_on"),
         :ok <- validate_rate_plan(operation, rate_plan),
         {:ok, rooms} <- validate_rooms(operation, rooms_input),
         :ok <- ensure_available(operation, group_id) do
      lodging_total_cents =
        Enum.reduce(rooms, 0, fn room, acc -> acc + nights * room.nightly_rate_cents end)

      deposit_due_cents =
        Enum.reduce(rooms, 0, fn room, acc ->
          lodging = nights * room.nightly_rate_cents
          acc + room_deposit(lodging, rate_plan)
        end)

      group = %Group{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: "active",
        revision: 1,
        policy_version: derive_policy_version(rate_plan, booked_on),
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        outstanding_deposit_cents: deposit_due_cents,
        refunded_cents: 0,
        retained_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_converted_to_credit_cents: 0
      }

      {:ok, inserted} = Repo.insert(group)

      rooms
      |> Enum.with_index()
      |> Enum.each(fn {room, position} ->
        Repo.insert!(%Room{
          group_id: inserted.group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        })
      end)

      applied(operation, %{
        group_id: inserted.group_id,
        deposit_due_cents: inserted.deposit_due_cents,
        revision: inserted.revision
      })
    else
      {:error, result} -> Repo.rollback(result)
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         :ok <- require_present_ok(operation, "amount_cents"),
         {:ok, group} <- load_group(operation, group_id),
         :ok <- check_revision(operation, group),
         :ok <- check_active(operation, group),
         {:ok, amount_cents} <-
           validate_payment_amount(operation, field(operation, "amount_cents")),
         :ok <- check_outstanding(operation, group, amount_cents) do
      paid = group.deposit_paid_cents + amount_cents
      outstanding = group.outstanding_deposit_cents - amount_cents

      group =
        group
        |> change(%{
          deposit_paid_cents: paid,
          cash_paid_cents: group.cash_paid_cents + amount_cents,
          outstanding_deposit_cents: outstanding,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: group.outstanding_deposit_cents,
        revision: group.revision
      })
    else
      {:error, result} -> Repo.rollback(result)
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, occurred_on} <- require_iso_date(operation, "occurred_on"),
         {:ok, _raw_arrival} <- require_present(operation, "new_arrival_on"),
         {:ok, group} <- load_group(operation, group_id),
         :ok <- check_revision(operation, group),
         :ok <- check_active(operation, group),
         {:ok, new_arrival_on} <- parse_stay_date(operation, field(operation, "new_arrival_on")),
         :ok <- ensure_arrival_after_operation(operation, new_arrival_on, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      group =
        group
        |> change(%{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: group.arrival_on,
        new_departure_on: group.departure_on,
        policy_version: policy_version(group),
        refundable_until: refundable_until(group),
        revision: group.revision
      })
    else
      {:error, result} -> Repo.rollback(result)
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, occurred_on} <- require_iso_date(operation, "occurred_on"),
         {:ok, group} <- load_group(operation, group_id),
         :ok <- check_revision(operation, group),
         :ok <- check_active(operation, group),
         {:ok, refund_method} <- parse_refund_method(operation),
         :ok <- check_refund_method_available(operation, group, occurred_on, refund_method) do
      refundable? = refundable_cancel?(group, occurred_on)
      cash_paid = group.cash_paid_cents

      {refunded_cents, retained_cents, converted_cents, credit_issued_cents, next_cash_paid} =
        cond do
          refundable? and refund_method == "hotel_credit" ->
            issued = credit_issue_amount(cash_paid)
            {0, 0, cash_paid, issued, 0}

          refundable? ->
            {cash_paid, 0, 0, 0, 0}

          true ->
            {0, cash_paid, 0, 0, cash_paid}
        end

      if refundable? do
        restore_applied_credit(group)
      else
        consume_applied_credit(group)
      end

      if credit_issued_cents > 0 do
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: field(operation, "operation_id"),
          remaining_cents: credit_issued_cents,
          expires_on: Date.add(occurred_on, 365)
        })
      end

      group =
        group
        |> change(%{
          status: "cancelled",
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents,
          cash_paid_cents: next_cash_paid,
          credit_paid_cents: 0,
          deposit_paid_cents: next_cash_paid,
          outstanding_deposit_cents: 0,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: group.refunded_cents,
        retained_cents: group.retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: group.revision
      })
    else
      {:error, result} -> Repo.rollback(result)
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         :ok <- require_present_ok(operation, "amount_cents"),
         {:ok, occurred_on} <- require_iso_date(operation, "occurred_on"),
         {:ok, group} <- load_group(operation, group_id),
         :ok <- check_revision(operation, group),
         :ok <- check_active(operation, group),
         {:ok, amount_cents} <-
           validate_payment_amount(operation, field(operation, "amount_cents")),
         :ok <- check_outstanding(operation, group, amount_cents),
         :ok <- consume_guest_credit(operation, group, amount_cents, occurred_on) do
      paid = group.deposit_paid_cents + amount_cents
      outstanding = group.outstanding_deposit_cents - amount_cents

      group =
        group
        |> change(%{
          deposit_paid_cents: paid,
          credit_paid_cents: group.credit_paid_cents + amount_cents,
          outstanding_deposit_cents: outstanding,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: group.outstanding_deposit_cents,
        revision: group.revision
      })
    else
      {:error, result} -> Repo.rollback(result)
    end
  end

  defp policy_version(%Group{policy_version: version}) when is_binary(version) and version != "",
    do: version

  defp policy_version(%Group{} = group),
    do: derive_policy_version(group.rate_plan, group.booked_on)

  defp derive_policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp derive_policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex30_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp derive_policy_version(_rate_plan, _booked_on), do: "advance-nonrefundable"

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30
  defp cancellation_window(_policy), do: nil

  defp refundable_until(group) do
    case cancellation_window(policy_version(group)) do
      nil -> nil
      days -> Date.add(group.arrival_on, -days)
    end
  end

  defp refundable_cancel?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until_date -> Date.compare(occurred_on, until_date) != :gt
    end
  end

  defp credit_issue_amount(0), do: 0

  defp credit_issue_amount(cash_cents) when cash_cents > 0 do
    cash_cents + round_percent(cash_cents, 10)
  end

  defp parse_refund_method(operation) do
    case field(operation, "refund_method") do
      nil -> {:ok, "cash"}
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _ -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp check_refund_method_available(_operation, _group, _occurred_on, "cash"), do: :ok

  defp check_refund_method_available(operation, group, occurred_on, "hotel_credit") do
    if refundable_cancel?(group, occurred_on) do
      :ok
    else
      {:error, rejected(operation, "refund_method_not_available")}
    end
  end

  defp consume_guest_credit(operation, group, amount_cents, occurred_on) do
    lots =
      from(l in CreditLot,
        where:
          l.guest_id == ^group.guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred_on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

    available = Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end)

    if available < amount_cents do
      {:error, rejected(operation, "insufficient_credit")}
    else
      take_from_lots(lots, amount_cents, group.group_id)
      :ok
    end
  end

  defp take_from_lots(lots, amount_cents, group_id) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining ->
      take = min(lot.remaining_cents, remaining)

      lot
      |> change(%{remaining_cents: lot.remaining_cents - take})
      |> Repo.update!()

      Repo.insert!(%CreditApplication{
        group_id: group_id,
        lot_id: lot.id,
        amount_cents: take
      })

      leftover = remaining - take
      if leftover == 0, do: {:halt, 0}, else: {:cont, leftover}
    end)
  end

  defp restore_applied_credit(group) do
    apps =
      from(a in CreditApplication, where: a.group_id == ^group.group_id)
      |> Repo.all()

    apps
    |> Enum.group_by(& &1.lot_id)
    |> Enum.each(fn {lot_id, lot_apps} ->
      restore = Enum.reduce(lot_apps, 0, fn app, acc -> acc + app.amount_cents end)
      lot = Repo.get!(CreditLot, lot_id)

      lot
      |> change(%{remaining_cents: lot.remaining_cents + restore})
      |> Repo.update!()
    end)

    from(a in CreditApplication, where: a.group_id == ^group.group_id)
    |> Repo.delete_all()
  end

  defp consume_applied_credit(group) do
    from(a in CreditApplication, where: a.group_id == ^group.group_id)
    |> Repo.delete_all()
  end

  defp room_deposit(lodging_cents, "flexible"), do: round_percent(lodging_cents, 20)
  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp round_percent(amount_cents, percent)
       when is_integer(amount_cents) and is_integer(percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp validate_rate_plan(_operation, rate_plan)
       when rate_plan in ["flexible", "advance_purchase"],
       do: :ok

  defp validate_rate_plan(operation, _rate_plan) do
    {:error, rejected(operation, "invalid_rate_plan")}
  end

  defp validate_rooms(operation, rooms) when is_list(rooms) and rooms != [] do
    validated = Enum.map(rooms, &validate_room/1)

    cond do
      Enum.any?(validated, &match?(:error, &1)) ->
        {:error, rejected(operation, "invalid_rooms")}

      true ->
        rooms = Enum.map(validated, fn {:ok, room} -> room end)
        ids = Enum.map(rooms, & &1.room_id)

        if ids == Enum.uniq(ids) do
          {:ok, rooms}
        else
          {:error, rejected(operation, "invalid_rooms")}
        end
    end
  end

  defp validate_rooms(operation, _rooms), do: {:error, rejected(operation, "invalid_rooms")}

  defp validate_room(room) when is_map(room) do
    room_id = field(room, "room_id")
    rate = field(room, "nightly_rate_cents")

    if is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
    else
      :error
    end
  end

  defp validate_room(_room), do: :error

  defp ensure_available(operation, group_id) do
    case Repo.get(Group, group_id) do
      nil -> :ok
      _group -> {:error, rejected(operation, "group_already_exists")}
    end
  end

  defp load_group(operation, group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, rejected(operation, "group_not_found")}
      group -> {:ok, group}
    end
  end

  defp check_revision(operation, group) do
    case field(operation, "expected_revision") do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:error,
         %{
           operation_id: field(operation, "operation_id"),
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}
    end
  end

  defp check_active(_operation, %Group{status: "active"}), do: :ok

  defp check_active(operation, _group) do
    {:error, rejected(operation, "group_not_active")}
  end

  defp validate_payment_amount(operation, amount_cents) do
    if is_integer(amount_cents) and amount_cents > 0 do
      {:ok, amount_cents}
    else
      {:error, rejected(operation, "invalid_amount")}
    end
  end

  defp check_outstanding(operation, group, amount_cents) do
    if amount_cents > group.outstanding_deposit_cents do
      {:error, rejected(operation, "payment_exceeds_outstanding")}
    else
      :ok
    end
  end

  defp require_stay(operation, arrival_key, departure_key) do
    arrival_raw = field(operation, arrival_key)
    departure_raw = field(operation, departure_key)

    if is_nil(arrival_raw) or is_nil(departure_raw) do
      {:error, rejected(operation, "invalid_operation")}
    else
      with {:ok, arrival_on} <- parse_date(arrival_raw),
           {:ok, departure_on} <- parse_date(departure_raw) do
        nights = Date.diff(departure_on, arrival_on)

        if nights >= 1 do
          {:ok, arrival_on, departure_on, nights}
        else
          {:error, rejected(operation, "invalid_stay")}
        end
      else
        _ -> {:error, rejected(operation, "invalid_stay")}
      end
    end
  end

  defp parse_stay_date(operation, raw) do
    case parse_date(raw) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, rejected(operation, "invalid_stay")}
    end
  end

  defp ensure_arrival_after_operation(operation, new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, rejected(operation, "invalid_stay")}
    end
  end

  defp require_id(operation, key) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp require_present(operation, key) do
    case field(operation, key) do
      nil -> {:error, rejected(operation, "invalid_operation")}
      value -> {:ok, value}
    end
  end

  defp require_present_ok(operation, key) do
    case require_present(operation, key) do
      {:ok, _value} -> :ok
      other -> other
    end
  end

  defp require_iso_date(operation, key) do
    case field(operation, key) do
      nil ->
        {:error, rejected(operation, "invalid_operation")}

      value ->
        case parse_date(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, rejected(operation, "invalid_operation")}
        end
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)

  defp parse_date(_value), do: :error

  defp rollback_rejected(operation, code), do: Repo.rollback(rejected(operation, code))

  defp rejected(operation, code) when is_map(operation) do
    %{operation_id: field(operation, "operation_id"), status: "rejected", code: code}
  end

  defp rejected(_operation, code) do
    %{operation_id: nil, status: "rejected", code: code}
  end

  defp applied(operation, attrs) do
    Map.merge(
      %{operation_id: field(operation, "operation_id"), status: "applied"},
      attrs
    )
  end

  defp field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  defp stringify_keys(other), do: other
end
