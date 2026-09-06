defmodule GroupStay.Reservations do
  @moduledoc "Processes ordered partner operations and maintains reservation deposit accounting."

  import Ecto.Query

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    Group,
    Operation,
    PaymentTransfer,
    Repo,
    RoomAccounting
  }

  @types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit)
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

  def get_payment(payment_id) do
    # The audit record and allocations are read from the same database snapshot.
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(Operation, operation_id: payment_id) do
          nil ->
            {:error, "operation_not_found"}

          operation ->
            if cash_payment?(operation) do
              slices = RoomAccounting.payment_slices(payment_id)

              totals =
                Map.new(
                  [
                    {"held", :held_cents},
                    {"refunded", :refunded_cents},
                    {"retained", :retained_cents},
                    {"converted_to_credit", :converted_to_credit_cents},
                    {"reduced", :reduced_cents},
                    {"charged_back", :charged_back_cents}
                  ],
                  fn {disposition, field} -> {field, disposition_total(slices, disposition)} end
                )

              totals =
                if Repo.get(PaymentTransfer, payment_id) do
                  held_by_group =
                    slices
                    |> Enum.filter(&(&1.disposition == "held"))
                    |> Enum.group_by(& &1.group_id)
                    |> Enum.sort_by(&elem(&1, 0))
                    |> Enum.map(fn {group_id, held} ->
                      %{
                        group_id: group_id,
                        amount_cents: Enum.sum(Enum.map(held, & &1.amount_cents))
                      }
                    end)

                  Map.put(totals, :held_by_group, held_by_group)
                else
                  totals
                end

              {:ok,
               Map.merge(totals, %{
                 payment_operation_id: payment_id,
                 original_group_id: operation.result["group_id"],
                 recorded_cents: operation.result["amount_cents"]
               })}
            else
              {:error, "payment_not_reconcilable"}
            end
        end
      end)

    result
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

        Map.merge(cash, %{
          credit_liability_cents: available + applied,
          cash_reduced_cents: RoomAccounting.cash_total("reduced"),
          cash_charged_back_cents: RoomAccounting.cash_total("charged_back"),
          credit_shortfall_cents: RoomAccounting.shortfall()
        })
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
    require_fields(operation, ~w(operation_id type))

    unless identifier?(operation["operation_id"]) and operation["type"] in @types,
      do: reject("invalid_operation")

    case operation["type"] do
      "transfer_deposit" ->
        transfer_deposit(operation)

      type when type in ~w(reduce_cash_payment charge_back_payment) ->
        adjust_payment(operation)

      _ ->
        require_fields(operation, ~w(group_id))
        unless identifier?(operation["group_id"]), do: reject("invalid_operation")

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
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp transfer_deposit(operation) do
    require_fields(operation, ~w(source_group_id destination_group_id))
    source = transfer_group(operation["source_group_id"])
    destination = transfer_group(operation["destination_group_id"])
    check_revision(source, operation)
    check_revision(destination, operation, "destination_expected_revision")

    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: reject("invalid_transfer")

    for group <- [source, destination] do
      unless group.status == "active",
        do: reject(%{code: "group_not_active", group_id: group.group_id})
    end

    require_fields(operation, ~w(occurred_on amount_cents))
    date(operation["occurred_on"], "invalid_operation")
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > source.deposit_paid_cents, do: reject("transfer_exceeds_held_funding")
    if amount > outstanding(destination), do: reject("transfer_exceeds_outstanding")

    {drawn, funded} = RoomAccounting.transfer(source, destination, amount)
    source = persist(source, RoomAccounting.totals(drawn.rooms))
    destination = persist(destination, RoomAccounting.totals(funded.rooms))

    %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding(source),
      destination_outstanding_deposit_cents: outstanding(destination),
      source_revision: source.revision,
      destination_revision: destination.revision
    }
  end

  defp transfer_group(id) do
    unless identifier?(id), do: reject("invalid_operation")
    Repo.get(Group, id) || reject(%{code: "group_not_found", group_id: id})
  end

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

    rooms = RoomAccounting.price_rooms(rooms, nights, operation["rate_plan"])
    lodging = Enum.sum(Enum.map(rooms, & &1["lodging_total_cents"]))
    deposit = Enum.sum(Enum.map(rooms, & &1["deposit_due_cents"]))

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
      group
      |> RoomAccounting.fund(amount, "cash", operation["operation_id"])
      |> then(&persist(group, RoomAccounting.totals(&1.rooms)))

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

    {funded, 0} =
      Enum.reduce_while(lots, {group, amount}, fn lot, {funded, needed} ->
        used = min(needed, lot.remaining_cents)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
        |> Repo.update!()

        funded = RoomAccounting.fund(funded, used, "credit", operation["operation_id"], lot.id)
        if used == needed, do: {:halt, {funded, 0}}, else: {:cont, {funded, needed - used}}
      end)

    RoomAccounting.sync_credit(group.group_id)
    updated = persist(group, RoomAccounting.totals(funded.rooms))

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

  defp update_group(group, %{"type" => type} = operation)
       when type in ~w(cancel_group cancel_rooms) do
    active_ids =
      group.rooms |> Enum.filter(&(&1["status"] == "active")) |> Enum.map(& &1["room_id"])

    selected =
      if type == "cancel_rooms" do
        require_fields(operation, ~w(room_ids))
        ids = operation["room_ids"]

        unless is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
                 Enum.all?(ids, &(&1 in active_ids)),
               do: reject("invalid_rooms")

        Enum.filter(active_ids, &(&1 in ids))
      else
        active_ids
      end

    occurred_on = date(operation["occurred_on"], "invalid_operation")
    method = Map.get(operation, "refund_method", "cash")
    unless method in ~w(cash hotel_credit), do: reject("invalid_operation")
    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred_on, cutoff) != :gt
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    slices = RoomAccounting.held(group.group_id) |> Enum.filter(&(&1.room_id in selected))
    cash_slices = Enum.filter(slices, &(&1.kind == "cash"))
    cash = Enum.sum(Enum.map(cash_slices, & &1.amount_cents))
    converted = if method == "hotel_credit", do: cash, else: 0
    issued = RoomAccounting.bonus_value(converted)
    if issued > @max_cents, do: reject("invalid_amount")

    if issued > 0 do
      if Date.diff(~D[9999-12-31], occurred_on) < 365, do: reject("invalid_operation")

      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, 365)
        })

      RoomAccounting.assign_entitlements(lot, cash_slices)
    end

    disposition =
      cond do
        method == "hotel_credit" -> "converted_to_credit"
        refundable -> "refunded"
        true -> "retained"
      end

    for slice <- slices do
      if slice.kind == "cash" do
        RoomAccounting.move(slice, slice.amount_cents, disposition)
      else
        if refundable, do: RoomAccounting.restore_credit(slice, occurred_on)
        Repo.delete!(slice)
      end
    end

    RoomAccounting.sync_credit(group.group_id)

    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] in selected,
          do:
            Map.merge(room, %{
              "status" => "cancelled",
              "cash_paid_cents" => 0,
              "credit_paid_cents" => 0
            }),
          else: room
      end)

    refunded = if disposition == "refunded", do: cash, else: 0
    retained = if disposition == "retained", do: cash, else: 0

    updated =
      persist(
        group,
        RoomAccounting.totals(rooms) ++
          [
            cash_refunded_cents: group.cash_refunded_cents + refunded,
            cash_retained_cents: group.cash_retained_cents + retained,
            cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
          ]
      )

    result = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: updated.revision
    }

    if type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, selected), else: result
  end

  defp cash_payment?(operation),
    do: operation.type == "record_cash_payment" and operation.result["status"] == "applied"

  defp disposition_total(slices, disposition),
    do:
      slices
      |> Enum.filter(&(&1.disposition == disposition))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

  defp adjust_payment(operation) do
    require_fields(operation, ~w(payment_operation_id))
    payment_id = operation["payment_operation_id"]
    unless identifier?(payment_id), do: reject("invalid_operation")
    target = Repo.get_by(Operation, operation_id: payment_id) || reject("operation_not_found")
    chargeback = operation["type"] == "charge_back_payment"
    invalid_code = if chargeback, do: "payment_not_chargeable", else: "payment_not_reducible"
    # Applied targets identify their group even if their type cannot accept a correction.
    group_id = target.result["group_id"] || target.payload["group_id"]
    group = if identifier?(group_id), do: Repo.get(Group, group_id)
    if group, do: check_revision(group, operation)
    unless cash_payment?(target), do: reject(invalid_code)
    unless group, do: reject("group_not_found")
    slices = RoomAccounting.payment_slices(payment_id)
    held = disposition_total(slices, "held")

    if chargeback do
      if disposition_total(slices, "charged_back") > 0 or
           target.result["amount_cents"] == disposition_total(slices, "reduced"),
         do: reject(invalid_code)

      require_fields(operation, ~w(occurred_on))
      date(operation["occurred_on"], "invalid_operation")
      groups = RoomAccounting.remove_held(slices, held, "charged_back")

      settled =
        Enum.filter(slices, &(&1.disposition in ~w(refunded retained converted_to_credit)))

      for slice <- settled, do: RoomAccounting.move(slice, slice.amount_cents, "charged_back")
      RoomAccounting.revoke_entitlements(payment_id)

      groups =
        Enum.reduce(settled, groups, fn slice, groups ->
          affected =
            Map.get_lazy(groups, slice.group_id, fn -> Repo.get!(Group, slice.group_id) end)

          field =
            case slice.disposition do
              "refunded" -> :cash_refunded_cents
              "retained" -> :cash_retained_cents
              "converted_to_credit" -> :cash_converted_to_credit_cents
            end

          Map.put(
            groups,
            slice.group_id,
            Map.update!(affected, field, &(&1 - slice.amount_cents))
          )
        end)

      updated = persist_adjusted_groups(groups, group)

      %{
        payment_operation_id: payment_id,
        group_id: group.group_id,
        charged_back_cents: held + Enum.sum(Enum.map(settled, & &1.amount_cents)),
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      }
    else
      if held == 0, do: reject(invalid_code)
      require_fields(operation, ~w(occurred_on amount_cents))
      date(operation["occurred_on"], "invalid_operation")
      amount = operation["amount_cents"]
      unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
      if amount > held, do: reject("reduction_exceeds_held_cash")
      groups = RoomAccounting.remove_held(slices, amount, "reduced")
      updated = persist_adjusted_groups(groups, group)

      %{
        payment_operation_id: payment_id,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      }
    end
  end

  defp persist_adjusted_groups(groups, addressed) do
    groups
    |> Map.put_new(addressed.group_id, addressed)
    |> Map.new(fn {id, changed} ->
      # Persist against the stored struct so Ecto detects changes to settlement counters too.
      original = Repo.get!(Group, id)

      changes =
        RoomAccounting.totals(changed.rooms) ++
          Keyword.take(
            Map.to_list(changed),
            [:cash_refunded_cents, :cash_retained_cents, :cash_converted_to_credit_cents]
          )

      {id, persist(original, changes)}
    end)
    |> Map.fetch!(addressed.group_id)
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

  defp check_revision(group, operation, key \\ "expected_revision") do
    if Map.has_key?(operation, key) and
         operation[key] !== group.revision do
      reject(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: operation[key],
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
