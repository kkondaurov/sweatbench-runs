defmodule GroupStay.Reservations do
  @moduledoc "Processes ordered partner operations and maintains reservation deposit accounting."

  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo}

  @types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group)
  @max_cents 9_223_372_036_854_775_807
  @public_fields ~w(group_id guest_id property_id revision booked_on arrival_on departure_on
                    rate_plan policy_version status rooms lodging_total_cents deposit_due_cents
                    deposit_paid_cents cash_paid_cents credit_paid_cents)a

  def submit(operations), do: Enum.map(operations, &process/1)

  def get_operation(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def ledger(on \\ Date.utc_today()) do
    # Read all components from one snapshot while partner operations may be committing.
    {:ok, totals} =
      Repo.transaction(fn ->
        cash =
          Repo.one(
            from g in Group,
              select: %{
                cash_held_cents: coalesce(sum(g.cash_paid_cents), 0),
                cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
                cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
                cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
              }
          )

        available =
          Repo.one(
            from l in CreditLot,
              where: l.expires_on >= ^on,
              select: coalesce(sum(l.remaining_cents), 0)
          )

        applied = Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))
        Map.put(cash, :credit_liability_cents, available + applied)
      end)

    totals
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  defp process(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id")

    # Acquire the write lock before looking up the id, so independent connections
    # cannot both apply a first attempt. Results and domain writes commit together.
    {:ok, result} =
      Repo.transaction(
        fn ->
          if identifier?(operation_id) do
            case Repo.get_by(Operation, operation_id: operation_id) do
              nil ->
                result = apply_with_result(operation, operation_id)

                Repo.insert!(%Operation{
                  operation_id: operation_id,
                  type: if(is_binary(operation["type"]), do: operation["type"]),
                  payload: operation,
                  result: result
                })

                result

              %Operation{payload: payload, result: stored} when payload === operation ->
                restore_result(stored)

              %Operation{} ->
                %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
            end
          else
            # A malformed/missing identifier cannot name a durable retry record.
            apply_with_result(operation, operation_id)
          end
        end,
        mode: :immediate
      )

    result
  end

  defp apply_with_result(operation, operation_id) do
    Repo.query!("SAVEPOINT operation_domain")

    try do
      result = apply_operation(operation)
      Repo.query!("RELEASE SAVEPOINT operation_domain")
      Map.merge(result, %{operation_id: operation_id, status: "applied"})
    catch
      :throw, {:operation_rejected, error} ->
        Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
        Repo.query!("RELEASE SAVEPOINT operation_domain")
        Map.merge(error, %{operation_id: operation_id, status: "rejected"})
    end
  end

  # JSON stores dates as strings and object keys as strings. Preserve the context's
  # existing return types on replay; the HTTP representation remains identical.
  defp restore_result(stored) do
    Map.new(stored, fn {key, value} ->
      value =
        if key in ~w(new_arrival_on new_departure_on refundable_until) and value != nil,
          do: Date.from_iso8601!(value),
          else: value

      {String.to_existing_atom(key), value}
    end)
  end

  defp apply_operation(operation) when is_map(operation) do
    require_fields(operation, ~w(operation_id type group_id))

    unless Enum.all?(~w(operation_id group_id), &identifier?(operation[&1])) and
             operation["type"] in @types do
      reject("invalid_operation")
    end

    if operation["type"] == "open_group" do
      open_group(operation)
    else
      group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
      check_revision(group, operation)
      unless group.status == "active", do: reject("group_not_active")
      require_fields(operation, ~w(occurred_on))
      update_group(group, operation)
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp open_group(operation) do
    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    require_fields(
      operation,
      ~w(occurred_on guest_id property_id arrival_on departure_on rate_plan rooms)
    )

    unless identifier?(operation["guest_id"]) and identifier?(operation["property_id"]),
      do: reject("invalid_operation")

    booked_on = date(operation["occurred_on"], "invalid_operation")
    arrival_on = date(operation["arrival_on"], "invalid_stay")
    departure_on = date(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    unless nights > 0, do: reject("invalid_stay")

    unless operation["rate_plan"] in ~w(flexible advance_purchase),
      do: reject("invalid_rate_plan")

    rooms = rooms(operation["rooms"])

    {lodging, deposit} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging, deposit} ->
        amount = nights * room["nightly_rate_cents"]

        due =
          if operation["rate_plan"] == "flexible", do: div(amount * 20 + 50, 100), else: amount

        {lodging + amount, deposit + due}
      end)

    unless lodging <= @max_cents, do: reject("invalid_rooms")

    group =
      Repo.insert!(%Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version(operation["rate_plan"], booked_on),
        rooms: rooms,
        lodging_total_cents: lodging,
        deposit_due_cents: deposit
      })

    %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}
  end

  defp update_group(group, %{"type" => "record_cash_payment"} = operation) do
    require_fields(operation, ~w(amount_cents))
    date(operation["occurred_on"], "invalid_operation")
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    updated =
      persist(group,
        deposit_paid_cents: group.deposit_paid_cents + amount,
        cash_paid_cents: group.cash_paid_cents + amount
      )

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = operation) do
    require_fields(operation, ~w(amount_cents))
    on = date(operation["occurred_on"], "invalid_operation")
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    lots = Repo.all(available_lots(group.guest_id, on))
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(needed, lot.remaining_cents)
      lot |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used) |> Repo.update!()

      Repo.insert!(%CreditAllocation{
        group_id: group.group_id,
        credit_lot_id: lot.id,
        amount_cents: used
      })

      if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
    end)

    updated =
      persist(group,
        deposit_paid_cents: group.deposit_paid_cents + amount,
        credit_paid_cents: group.credit_paid_cents + amount
      )

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation) do
    require_fields(operation, ~w(new_arrival_on))
    occurred_on = date(operation["occurred_on"], "invalid_stay")
    arrival_on = date(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival_on, occurred_on) == :gt, do: reject("invalid_stay")
    nights = Date.diff(group.departure_on, group.arrival_on)

    # Do not let a valid arrival at the end of the calendar overflow Date's range.
    if Date.diff(~D[9999-12-31], arrival_on) < nights, do: reject("invalid_stay")
    departure_on = Date.add(arrival_on, nights)
    updated = persist(group, arrival_on: arrival_on, departure_on: departure_on)

    %{
      group_id: group.group_id,
      new_arrival_on: arrival_on,
      new_departure_on: departure_on,
      policy_version: updated.policy_version,
      refundable_until: refundable_until(updated),
      revision: updated.revision
    }
  end

  defp update_group(group, %{"type" => "cancel_group"} = operation) do
    occurred_on = date(operation["occurred_on"], "invalid_operation")
    method = Map.get(operation, "refund_method", "cash")
    unless method in ~w(cash hotel_credit), do: reject("invalid_operation")
    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred_on, cutoff) != :gt
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    converted = if method == "hotel_credit", do: group.cash_paid_cents, else: 0
    issued = converted + div(converted * 10 + 50, 100)
    if issued > @max_cents, do: reject("invalid_amount")

    if issued > 0 do
      if Date.diff(~D[9999-12-31], occurred_on) < 365, do: reject("invalid_operation")

      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    settle_credit(group, refundable, occurred_on)
    refunded = if refundable and method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    updated =
      persist(group,
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
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
      revision: updated.revision
    }
  end

  defp settle_credit(group, refundable, on) do
    allocations = from a in CreditAllocation, where: a.group_id == ^group.group_id

    if refundable do
      for allocation <- Repo.all(allocations) do
        # Redeemed credit keeps its original expiry. An expired restoration is forfeited.
        Repo.update_all(
          from(l in CreditLot,
            where: l.id == ^allocation.credit_lot_id and l.expires_on >= ^on
          ),
          inc: [remaining_cents: allocation.amount_cents]
        )
      end
    end

    Repo.delete_all(allocations)
  end

  defp available_lots(guest_id, on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    days = if group.policy_version == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -days)
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      reject(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    end
  end

  defp persist(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp rooms(rooms) when is_list(rooms) and rooms != [] do
    unless Enum.all?(rooms, fn
             %{"room_id" => id, "nightly_rate_cents" => rate} ->
               identifier?(id) and is_integer(rate) and rate >= 0 and rate <= @max_cents

             _ ->
               false
           end),
           do: reject("invalid_rooms")

    ids = Enum.map(rooms, & &1["room_id"])
    unless length(Enum.uniq(ids)) == length(ids), do: reject("invalid_rooms")
    Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents)))
  end

  defp rooms(_), do: reject("invalid_rooms")
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp require_fields(operation, fields) do
    unless Enum.all?(fields, &Map.has_key?(operation, &1)), do: reject("invalid_operation")
  end

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp date(_, code), do: reject(code)
  defp reject(error) when is_map(error), do: throw({:operation_rejected, error})
  defp reject(code), do: reject(%{code: code})
end
