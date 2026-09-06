defmodule GroupStay.OperationalCore do
  import Ecto.Query

  alias GroupStay.OperationalCore.{CreditAllocation, CreditLot, Group, PartnerOperation, Room}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @max_sqlite_integer 9_223_372_036_854_775_807
  @policy_cutoff ~D[2027-01-01]

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_operation(_operation_id), do: nil

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> render_group(group)
    end
  end

  def get_group(_group_id), do: nil

  def report_date(nil), do: {:ok, Date.utc_today()}

  def report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> parse_expanded_date(value)
    end
  end

  def report_date(_value), do: :error

  def ledger(on \\ Date.utc_today()) do
    {:ok, ledger} = Repo.transaction(fn -> ledger_snapshot(on) end)
    ledger
  end

  defp ledger_snapshot(on) do
    {held, refunded, retained, converted} =
      from(group in Group,
        select: {
          group.status,
          group.cash_paid_cents,
          group.cash_refunded_cents,
          group.cash_retained_cents,
          group.cash_converted_to_credit_cents
        }
      )
      |> Repo.all()
      |> Enum.reduce({0, 0, 0, 0}, fn
        {status, paid, group_refunded, group_retained, group_converted},
        {held, refunded, retained, converted} ->
          held = if status == "active", do: held + paid, else: held

          {
            held,
            refunded + group_refunded,
            retained + group_retained,
            converted + group_converted
          }
      end)

    %{
      cash_held_cents: held,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: credit_liability(on)
    }
  end

  def guest_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: render_credit_lots(lots)
    }
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: update_group(operation, :record_cash_payment)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: update_group(operation, :apply_hotel_credit)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: update_group(operation, :reschedule_group)

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: update_group(operation, :cancel_group)

  defp apply_operation(operation) when is_map(operation),
    do: reject(operation, "invalid_operation")

  defp apply_operation(_operation), do: reject(%{}, "invalid_operation")

  defp open_group(operation) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with :ok <- validate_structure(operation, required),
         :ok <- validate_identifiers(operation, ~w(group_id guest_id property_id)),
         {:ok, booked_on} <- parse_stay_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_stay_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_stay_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         {:ok, {lodging_total, deposit_due}} <-
           calculate_totals(rooms, arrival_on, departure_on, operation["rate_plan"]),
         :ok <- ensure_group_is_new(operation["group_id"]),
         {:ok, group} <-
           insert_group(
             operation,
             booked_on,
             arrival_on,
             departure_on,
             rooms,
             lodging_total,
             deposit_due
           ) do
      %{
        operation_id: operation["operation_id"],
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:error, code} -> reject(operation, code, group_id(operation))
    end
  end

  defp update_group(operation, kind) do
    required = update_required_fields(kind)

    with :ok <- validate_structure(operation, required),
         :ok <- validate_identifiers(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- validate_expected_revision(operation),
         :ok <- compare_revision(operation, group),
         :ok <- ensure_active(group) do
      apply_group_update(operation, group, kind)
    else
      {:error, "stale_revision", group} ->
        reject(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation["expected_revision"],
          actual_revision: group.revision
        })

      {:error, code} ->
        reject(operation, code, group_id(operation))
    end
  end

  defp apply_group_update(operation, group, :record_cash_payment) do
    amount = operation["amount_cents"]
    outstanding = outstanding_deposit(group)

    cond do
      match?({:error, _reason}, parse_date(operation["occurred_on"])) ->
        reject(operation, "invalid_operation", %{group_id: group.group_id})

      not (is_integer(amount) and amount > 0) ->
        reject(operation, "invalid_amount", %{group_id: group.group_id})

      amount > outstanding ->
        reject(operation, "payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        group =
          update!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount,
            revision: group.revision + 1
          })

        %{
          operation_id: operation["operation_id"],
          status: "applied",
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        }
    end
  end

  defp apply_group_update(operation, group, :apply_hotel_credit) do
    amount = operation["amount_cents"]
    outstanding = outstanding_deposit(group)

    with {:ok, occurred_on} <- parse_operation_date(operation["occurred_on"]),
         :ok <- validate_payment_amount(amount),
         :ok <- validate_payment_outstanding(amount, outstanding),
         {:ok, lots} <- ensure_sufficient_credit(group.guest_id, occurred_on, amount) do
      allocate_credit(group, lots, amount)

      group =
        update!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: group.revision + 1
        })

      %{
        operation_id: operation["operation_id"],
        status: "applied",
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    else
      {:error, code} ->
        reject(operation, code, %{group_id: group.group_id})
    end
  end

  defp apply_group_update(operation, group, :reschedule_group) do
    with {:ok, occurred_on} <- parse_operation_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)

      if new_departure_on.year <= 9999 do
        group =
          update!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          })

        %{
          operation_id: operation["operation_id"],
          status: "applied",
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(group.arrival_on),
          new_departure_on: Date.to_iso8601(group.departure_on),
          policy_version: group.policy_version,
          refundable_until: refundable_until(group),
          revision: group.revision
        }
      else
        reject(operation, "invalid_stay", %{group_id: group.group_id})
      end
    else
      {:error, _reason} -> reject(operation, "invalid_stay", %{group_id: group.group_id})
    end
  end

  defp apply_group_update(operation, group, :cancel_group) do
    with {:ok, occurred_on} <- parse_operation_date(operation["occurred_on"]),
         {:ok, refund_method} <- validate_refund_method(operation),
         refundable = refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refund_method, refundable) do
      settle_allocated_credit(group, occurred_on, refundable)

      refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
      retained = if refundable, do: 0, else: group.cash_paid_cents

      converted =
        if refundable and refund_method == "hotel_credit", do: group.cash_paid_cents, else: 0

      credit_issued =
        if converted > 0 do
          issued = converted + round_percentage(converted, 10)

          create_credit_lot(
            group.guest_id,
            operation["operation_id"],
            issued,
            Date.add(occurred_on, 365)
          )

          issued
        else
          0
        end

      group =
        update!(group, %{
          status: "cancelled",
          cash_refunded_cents: refunded,
          cash_retained_cents: retained,
          cash_converted_to_credit_cents: converted,
          revision: group.revision + 1
        })

      %{
        operation_id: operation["operation_id"],
        status: "applied",
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: credit_issued,
        revision: group.revision
      }
    else
      {:error, code} ->
        reject(operation, code, %{group_id: group.group_id})
    end
  end

  defp validate_structure(operation, required) do
    valid_operation_id =
      is_binary(operation["operation_id"]) and operation["operation_id"] != ""

    all_fields_present = Enum.all?(required, &Map.has_key?(operation, &1))

    if valid_operation_id and all_fields_present,
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp validate_identifiers(operation, fields) do
    if Enum.all?(fields, fn field ->
         is_binary(operation[field]) and operation[field] != ""
       end) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, revision} when is_integer(revision) and revision > 0 -> :ok
      {:ok, _revision} -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_format}

  defp parse_operation_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_operation"}
    end
  end

  defp parse_stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate}
        when is_binary(room_id) and room_id != "" and is_integer(nightly_rate) and
               nightly_rate > 0 and nightly_rate <= @max_sqlite_integer ->
          true

        _room ->
          false
      end)

    if valid do
      room_ids = Enum.map(rooms, & &1["room_id"])

      if length(room_ids) == length(Enum.uniq(room_ids)),
        do: {:ok, rooms},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp ensure_group_is_new(group_id) do
    if Repo.exists?(from group in Group, where: group.group_id == ^group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp calculate_totals(rooms, arrival_on, departure_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    room_amounts =
      Enum.map(rooms, fn room ->
        lodging = nights * room["nightly_rate_cents"]
        deposit = room_deposit(lodging, rate_plan)
        {lodging, deposit}
      end)

    lodging_total = Enum.sum(Enum.map(room_amounts, &elem(&1, 0)))
    deposit_due = Enum.sum(Enum.map(room_amounts, &elem(&1, 1)))

    representable =
      Enum.all?(room_amounts, fn {lodging, deposit} ->
        lodging <= @max_sqlite_integer and deposit <= @max_sqlite_integer
      end) and lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer

    if representable,
      do: {:ok, {lodging_total, deposit_due}},
      else: {:error, "invalid_rooms"}
  end

  defp insert_group(
         operation,
         booked_on,
         arrival_on,
         departure_on,
         rooms,
         lodging_total,
         deposit_due
       ) do
    group = %Group{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      policy_version: policy_version(operation["rate_plan"], booked_on),
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    }

    with {:ok, group} <- Repo.insert(group) do
      room_rows =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          %{
            group_id: group.group_id,
            position: position,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"]
          }
        end)

      {_count, nil} = Repo.insert_all(Room, room_rows)
      {:ok, group}
    else
      {:error, _changeset} -> {:error, "group_already_exists"}
    end
  end

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp fetch_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp compare_revision(%{"expected_revision" => expected}, group)
       when expected != group.revision,
       do: {:error, "stale_revision", group}

  defp compare_revision(_operation, _group), do: :ok

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, "group_not_active"}

  defp update!(group, changes) do
    group
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp update_required_fields(:record_cash_payment),
    do: ~w(operation_id occurred_on group_id amount_cents)

  defp update_required_fields(:apply_hotel_credit),
    do: ~w(operation_id occurred_on group_id amount_cents)

  defp update_required_fields(:reschedule_group),
    do: ~w(operation_id occurred_on group_id new_arrival_on)

  defp update_required_fields(:cancel_group), do: ~w(operation_id occurred_on group_id)

  defp outstanding_deposit(%Group{status: "active"} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding_deposit(_group), do: 0

  defp render_group(group) do
    rooms =
      from(room in Room,
        where: room.group_id == ^group.group_id,
        order_by: room.position,
        select: %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents
        }
      )
      |> Repo.all()

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: arrival_on |> Date.add(-14) |> Date.to_iso8601()

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: arrival_on |> Date.add(-30) |> Date.to_iso8601()

  defp refundable_until(_group), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, Date.from_iso8601!(deadline)) != :gt
    end
  end

  defp validate_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _method -> {:error, "invalid_operation"}
    end
  end

  defp ensure_refund_method_available("hotel_credit", false),
    do: {:error, "refund_method_not_available"}

  defp ensure_refund_method_available(_method, _refundable), do: :ok

  defp validate_payment_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_payment_amount(_amount), do: {:error, "invalid_amount"}

  defp validate_payment_outstanding(amount, outstanding) when amount <= outstanding, do: :ok

  defp validate_payment_outstanding(_amount, _outstanding),
    do: {:error, "payment_exceeds_outstanding"}

  defp ensure_sufficient_credit(guest_id, on, amount) do
    lots = available_lots(guest_id, on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount,
      do: {:ok, lots},
      else: {:error, "insufficient_credit"}
  end

  defp available_lots(guest_id, on) do
    on_day = Date.to_gregorian_days(on)

    from(lot in CreditLot,
      where:
        lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
          lot.expires_on_day >= ^on_day,
      order_by: [asc: lot.expires_on_day, asc: lot.source_operation_id, asc: lot.id]
    )
    |> Repo.all()
  end

  defp allocate_credit(group, lots, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)

      update!(lot, %{remaining_cents: lot.remaining_cents - used})

      Repo.insert!(%CreditAllocation{
        group_id: group.group_id,
        credit_lot_id: lot.id,
        amount_cents: used
      })

      case remaining - used do
        0 -> {:halt, 0}
        rest -> {:cont, rest}
      end
    end)
  end

  defp settle_allocated_credit(group, occurred_on, refundable) do
    from(allocation in CreditAllocation, where: allocation.group_id == ^group.group_id)
    |> Repo.all()
    |> Enum.each(fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable and lot.expires_on_day >= Date.to_gregorian_days(occurred_on) do
        update!(lot, %{remaining_cents: lot.remaining_cents + allocation.amount_cents})
      end

      Repo.delete!(allocation)
    end)
  end

  defp create_credit_lot(guest_id, source_operation_id, amount, expires_on) do
    amount
    |> split_sqlite_integers()
    |> Enum.each(fn chunk ->
      Repo.insert!(%CreditLot{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: chunk,
        expires_on_day: Date.to_gregorian_days(expires_on)
      })
    end)
  end

  defp split_sqlite_integers(amount) when amount <= @max_sqlite_integer, do: [amount]

  defp split_sqlite_integers(amount),
    do: [@max_sqlite_integer | split_sqlite_integers(amount - @max_sqlite_integer)]

  defp round_percentage(amount, percentage), do: div(amount * percentage + 50, 100)

  defp credit_liability(on) do
    on_day = Date.to_gregorian_days(on)

    available =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on_day >= ^on_day,
        select: lot.remaining_cents
      )
      |> Repo.all()
      |> Enum.sum()

    allocated =
      from(allocation in CreditAllocation, select: allocation.amount_cents)
      |> Repo.all()
      |> Enum.sum()

    available + allocated
  end

  defp render_credit_lots(lots) do
    lots
    |> Enum.chunk_by(&{&1.expires_on_day, &1.source_operation_id})
    |> Enum.map(fn chunks ->
      lot = hd(chunks)

      %{
        source_operation_id: lot.source_operation_id,
        remaining_cents: Enum.sum(Enum.map(chunks, & &1.remaining_cents)),
        expires_on: lot.expires_on_day |> Date.from_gregorian_days() |> Date.to_iso8601()
      }
    end)
  end

  defp parse_expanded_date(value) do
    case Regex.run(~r/^(\d{5,})-(\d{2})-(\d{2})$/, value) do
      [_, year, month, day] ->
        case Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :error
        end

      _match ->
        :error
    end
  end

  defp group_id(operation) do
    case operation["group_id"] do
      group_id when is_binary(group_id) -> %{group_id: group_id}
      _group_id -> %{}
    end
  end

  defp process_operation(operation) do
    case Repo.transaction(fn -> process_operation_in_transaction(operation) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, reason} -> raise "operation transaction failed: #{inspect(reason)}"
    end
  end

  defp process_operation_in_transaction(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        result = operation |> apply_operation() |> normalize_json()

        Repo.insert!(%PartnerOperation{
          operation_id: operation_id,
          operation_type: operation_type(operation),
          submission: operation,
          result: result
        })

        result

      stored_operation ->
        if stored_operation.submission === operation do
          stored_operation.result
        else
          reject(operation, "operation_id_conflict")
        end
    end
  end

  defp process_operation_in_transaction(operation), do: apply_operation(operation)

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp normalize_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp reject(operation, code, extra \\ %{}) do
    %{operation_id: Map.get(operation, "operation_id"), status: "rejected", code: code}
    |> Map.merge(extra)
  end
end
