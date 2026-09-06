defmodule GroupStay do
  @moduledoc """
  Applies partner operations and reads reservation, cash and hotel-credit records.
  """

  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo, Room}

  @operation_fields %{
    "open_group" => ~w(occurred_on guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(occurred_on amount_cents),
    "apply_hotel_credit" => ~w(occurred_on amount_cents),
    "reschedule_group" => ~w(occurred_on new_arrival_on),
    "cancel_group" => ~w(occurred_on)
  }
  @max_cents 9_223_372_036_854_775_807

  @doc "Applies operations in order, committing each successful operation independently."
  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @doc "Returns the public group representation, or nil when it does not exist."
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> group_data()
    end
  end

  @doc "Returns cash settlements and credit liability, evaluating expiry on the given date."
  def ledger(on \\ Date.utc_today()) do
    # Both aggregates must observe the same snapshot during credit applications and settlements.
    {:ok, totals} =
      Repo.transaction(fn ->
        totals =
          Repo.one(
            from g in Group,
              select: %{
                cash_held_cents: coalesce(sum(g.deposit_paid_cents - g.credit_paid_cents), 0),
                cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
                cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
                cash_converted_to_credit_cents:
                  coalesce(sum(g.cash_converted_to_credit_cents), 0),
                credit_liability_cents: coalesce(sum(g.credit_paid_cents), 0)
              }
          )

        available =
          Repo.one(from lot in unexpired_lots(on), select: coalesce(sum(lot.remaining_cents), 0))

        Map.update!(totals, :credit_liability_cents, &(&1 + available))
      end)

    totals
  end

  @doc "Returns the guest's available credit in expiry and source-operation order."
  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      guest_lots(guest_id, on)
      |> Repo.all()
      |> Enum.map(&Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  defp unexpired_lots(on) do
    from lot in CreditLot, where: lot.remaining_cents > 0 and lot.expires_on >= ^on
  end

  defp guest_lots(guest_id, on) do
    from lot in unexpired_lots(on),
      where: lot.guest_id == ^guest_id,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp submit_operation(operation) do
    # SQLite must acquire its write lock before reading the revision. A deferred
    # transaction can read an obsolete snapshot before attempting to write.
    # Queue writers in this VM before entering SQLite: concurrent native busy
    # waits can block first-use code loading in the process holding the write lock.
    # The immediate transaction still coordinates writers in separate OS processes.
    result =
      :global.trans(
        {{__MODULE__, Repo.get_dynamic_repo()}, self()},
        fn -> Repo.transaction(fn -> apply_operation(operation) end, mode: :immediate) end,
        [node()]
      )

    case result do
      {:ok, result} ->
        Map.merge(result, %{operation_id: operation["operation_id"], status: "applied"})

      {:error, details} ->
        operation_id = if is_map(operation), do: operation["operation_id"]
        Map.merge(details, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    unless valid_identifier?(operation["operation_id"]) and
             valid_identifier?(operation["group_id"]) and
             is_map_key(@operation_fields, operation["type"]) do
      reject("invalid_operation")
    end

    case operation["type"] do
      "open_group" ->
        require_fields(operation)
        open_group(operation)

      type ->
        group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
        check_revision(group, operation)
        require_fields(operation)
        unless group.status == "active", do: reject("group_not_active")
        update_group(type, group, operation)
    end
  end

  defp apply_operation(_operation), do: reject("invalid_operation")

  defp require_fields(operation) do
    unless Enum.all?(@operation_fields[operation["type"]], &Map.has_key?(operation, &1)) do
      reject("invalid_operation")
    end
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      reject("stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    end
  end

  defp open_group(operation) do
    unless valid_identifier?(operation["guest_id"]) and
             valid_identifier?(operation["property_id"]) do
      reject("invalid_operation")
    end

    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    booked_on = date!(operation["occurred_on"], "invalid_stay")
    arrival_on = date!(operation["arrival_on"], "invalid_stay")
    departure_on = date!(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    unless nights > 0, do: reject("invalid_stay")

    rate_plan = operation["rate_plan"]
    unless rate_plan in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")
    rooms = validate_rooms(operation["rooms"])

    {lodging_total, deposit_due} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging, deposit} ->
        amount = nights * room["nightly_rate_cents"]
        due = if rate_plan == "flexible", do: round_percentage(amount, 20), else: amount
        {lodging + amount, deposit + due}
      end)

    unless lodging_total <= @max_cents, do: reject("invalid_rooms")

    group =
      Repo.insert!(%Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      })

    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        group_id: group.group_id,
        room_id: room["room_id"],
        position: position,
        nightly_rate_cents: room["nightly_rate_cents"]
      })
    end)

    %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: group.revision}
  end

  defp update_group("record_cash_payment", group, operation) do
    date!(operation["occurred_on"], "invalid_operation")
    amount = payment_amount!(group, operation)

    group = persist_update(group, deposit_paid_cents: group.deposit_paid_cents + amount)

    payment_result(group, amount)
  end

  defp update_group("apply_hotel_credit", group, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_operation")
    amount = payment_amount!(group, operation)
    lots = Repo.all(guest_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    Enum.reduce_while(lots, amount, fn lot, needed ->
      taken = min(lot.remaining_cents, needed)
      lot |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - taken) |> Repo.update!()

      Repo.insert!(
        %CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: taken
        },
        on_conflict: [inc: [amount_cents: taken]],
        conflict_target: [:group_id, :credit_lot_id]
      )

      if taken == needed, do: {:halt, 0}, else: {:cont, needed - taken}
    end)

    group =
      persist_update(group,
        deposit_paid_cents: group.deposit_paid_cents + amount,
        credit_paid_cents: group.credit_paid_cents + amount
      )

    payment_result(group, amount)
  end

  defp update_group("reschedule_group", group, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_stay")
    arrival_on = date!(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival_on, occurred_on) == :gt, do: reject("invalid_stay")
    departure_on = shift_departure(arrival_on, Date.diff(group.departure_on, group.arrival_on))
    group = persist_update(group, arrival_on: arrival_on, departure_on: departure_on)

    %{
      group_id: group.group_id,
      new_arrival_on: group.arrival_on,
      new_departure_on: group.departure_on,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      revision: group.revision
    }
  end

  defp update_group("cancel_group", group, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_operation")
    refund_method = Map.get(operation, "refund_method", "cash")
    unless refund_method in ~w(cash hotel_credit), do: reject("invalid_refund_method")
    deadline = refundable_until(group)
    refundable = deadline != nil and Date.compare(occurred_on, deadline) != :gt

    if refund_method == "hotel_credit" and not refundable,
      do: reject("refund_method_not_available")

    cash = cash_paid(group)
    refunded = if refundable and refund_method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash
    converted = if refundable and refund_method == "hotel_credit", do: cash, else: 0
    issued = if converted > 0, do: issue_credit(group, operation, occurred_on, converted), else: 0
    if refundable, do: restore_credit(group, occurred_on)

    group =
      persist_update(group,
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: refunded,
        cash_retained_cents: retained,
        cash_converted_to_credit_cents: converted
      )

    %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: group.revision
    }
  end

  defp issue_credit(group, operation, occurred_on, cash) do
    issued = cash + round_percentage(cash, 10)
    expires_on = Date.add(occurred_on, 365)
    unless expires_on.year in -9999..9999, do: reject("invalid_operation")

    Repo.insert!(%CreditLot{
      guest_id: group.guest_id,
      source_group_id: group.group_id,
      source_operation_id: operation["operation_id"],
      expires_on: expires_on,
      issued_cents: issued,
      remaining_cents: issued
    })

    issued
  end

  defp restore_credit(group, occurred_on) do
    allocations = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)

    for allocation <- allocations do
      # Applied credit has no expiry. Only restoration tests the original lot's expiry;
      # an already expired restoration is extinguished permanently at settlement.
      Repo.update_all(
        from(lot in CreditLot,
          where: lot.id == ^allocation.credit_lot_id and lot.expires_on >= ^occurred_on
        ),
        inc: [remaining_cents: allocation.amount_cents]
      )
    end
  end

  defp payment_amount!(group, operation) do
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    amount
  end

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    days = if group.policy_version == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -days)
  end

  defp persist_update(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0 and
          room["nightly_rate_cents"] <= @max_cents
      end)

    unless valid, do: reject("invalid_rooms")
    identifiers = Enum.map(rooms, & &1["room_id"])
    unless length(Enum.uniq(identifiers)) == length(rooms), do: reject("invalid_rooms")
    rooms
  end

  defp validate_rooms(_rooms), do: reject("invalid_rooms")

  # Integer arithmetic preserves cent precision, including half-cent rounding.
  defp round_percentage(amount, percent), do: div(amount * percent + 50, 100)
  defp valid_identifier?(value), do: is_binary(value) and value != ""
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents

  defp date!(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> reject(code)
    end
  end

  defp date!(_value, code), do: reject(code)

  defp shift_departure(arrival_on, nights) do
    departure_on = Date.add(arrival_on, nights)
    # Date.add/2 can produce years outside the API's ISO 8601 date format.
    unless departure_on.year in -9999..9999, do: reject("invalid_stay")
    departure_on
  end

  defp reject(code, details \\ %{}), do: Repo.rollback(Map.put(details, :code, code))

  defp group_data(group) do
    group
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :credit_paid_cents
    ])
    |> Map.put(:cash_paid_cents, cash_paid(group))
    |> Map.put(:refundable_until, refundable_until(group))
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
    |> Map.put(:rooms, Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
  end
end
