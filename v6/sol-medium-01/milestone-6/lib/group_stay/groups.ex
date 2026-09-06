defmodule GroupStay.Groups do
  @moduledoc "The group-deposit domain and its ordered partner operations."

  import Ecto.Query

  alias GroupStay.Groups.{
    CreditEntitlement,
    CreditLot,
    FundingAllocation,
    Group,
    PartnerOperation,
    Room
  }

  alias GroupStay.Repo
  alias GroupStay.Finance

  @rate_plans ["flexible", "advance_purchase"]
  @top_level_open ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
  @cash_dispositions ~w(held refunded retained converted reduced charged_back)

  def process_batch(operations), do: Enum.map(operations, &process_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_), do: nil

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_operation_result(_), do: nil

  def payment_statement(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        {:error, :not_found}

      operation ->
        if applied_cash_payment?(operation) do
          result = operation.result
          dispositions = cash_dispositions(operation_id)

          statement = %{
            payment_operation_id: operation_id,
            original_group_id: value(result, "group_id"),
            recorded_cents: value(result, "amount_cents"),
            held_cents: dispositions["held"],
            refunded_cents: dispositions["refunded"],
            retained_cents: dispositions["retained"],
            converted_to_credit_cents: dispositions["converted"],
            reduced_cents: dispositions["reduced"],
            charged_back_cents: dispositions["charged_back"]
          }

          statement =
            if payment_transferred?(operation_id),
              do: Map.put(statement, :held_by_group, held_cash_by_group(operation_id)),
              else: statement

          {:ok, statement}
        else
          {:error, :not_reconcilable}
        end
    end
  end

  def payment_statement(_), do: {:error, :not_found}

  def ledger(on \\ Date.utc_today()) do
    sums =
      Repo.all(
        from allocation in FundingAllocation,
          where: allocation.funding_type == "cash",
          group_by: allocation.disposition,
          select: {allocation.disposition, sum(allocation.amount_cents)}
      )
      |> Map.new()

    %{
      cash_held_cents: Map.get(sums, "held", 0),
      cash_refunded_cents: Map.get(sums, "refunded", 0),
      cash_retained_cents: Map.get(sums, "retained", 0),
      cash_converted_to_credit_cents: Map.get(sums, "converted", 0),
      cash_reduced_cents: Map.get(sums, "reduced", 0),
      cash_charged_back_cents: Map.get(sums, "charged_back", 0),
      credit_liability_cents: credit_liability(on),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def parse_read_date(nil), do: {:ok, Date.utc_today()}
  def parse_read_date(value), do: parse_date(value)

  def parse_reporting_date(value), do: parse_date(value)

  def daily_finance_report(date), do: Finance.daily_report(date)

  def group_json(%Group{} = group) do
    rooms = Enum.sort_by(group.rooms, & &1.position)
    active = Enum.filter(rooms, &(&1.status == "active"))
    lodging = sum_field(active, :lodging_total_cents)
    due = sum_field(active, :deposit_due_cents)
    cash = sum_field(active, :cash_paid_cents)
    credit = sum_field(active, :credit_paid_cents)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: max(due - cash - credit, 0)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if nonempty_string?(operation_id),
      do: transact_operation(operation, operation_id),
      else: rejected(operation_id, "invalid_operation")
  end

  defp process_operation(_), do: rejected(nil, "invalid_operation")

  defp transact_operation(operation, operation_id) do
    case Repo.transaction(fn -> process_durable_operation(operation, operation_id) end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, reason} -> raise "partner operation transaction rolled back: #{inspect(reason)}"
    end
  end

  defp process_durable_operation(operation, operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        result = operation |> execute_domain_operation(operation_id) |> canonical_json()

        %PartnerOperation{}
        |> PartnerOperation.changeset(%{
          operation_id: operation_id,
          operation_type: submitted_operation_type(operation),
          submission: canonical_json(operation),
          result: result
        })
        |> Repo.insert!()

        result

      remembered ->
        if remembered.submission === canonical_json(operation),
          do: remembered.result,
          else: rejected(operation_id, "operation_id_conflict")
    end
  end

  defp execute_domain_operation(operation, operation_id) do
    Repo.query!("SAVEPOINT partner_operation_domain")

    try do
      finance_context = Finance.before_operation(operation)

      result =
        if nonempty_string?(operation["operation_id"]) and nonempty_string?(operation["type"]),
          do: dispatch(operation, operation_id),
          else: reject(operation_id, "invalid_operation")

      result = Finance.after_operation(operation, operation_id, result, finance_context)

      Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
      result
    catch
      :throw, {:partner_operation_rejected, result} ->
        Repo.query!("ROLLBACK TO SAVEPOINT partner_operation_domain")
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
        result
    end
  end

  defp canonical_json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp submitted_operation_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_operation_type(_), do: nil

  defp dispatch(%{"type" => "open_group"} = operation, operation_id),
    do: open_group(operation, operation_id)

  defp dispatch(%{"type" => "record_cash_payment"} = operation, operation_id),
    do: with_group(operation, operation_id, &record_cash_payment(&1, operation, operation_id))

  defp dispatch(%{"type" => "reschedule_group"} = operation, operation_id),
    do: with_group(operation, operation_id, &reschedule_group(&1, operation, operation_id))

  defp dispatch(%{"type" => "cancel_group"} = operation, operation_id),
    do: with_group(operation, operation_id, &cancel_group(&1, operation, operation_id))

  defp dispatch(%{"type" => "cancel_rooms"} = operation, operation_id),
    do: with_group(operation, operation_id, &cancel_rooms(&1, operation, operation_id))

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation, operation_id),
    do: with_group(operation, operation_id, &apply_hotel_credit(&1, operation, operation_id))

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation, operation_id),
    do:
      with_payment(
        operation,
        operation_id,
        "payment_not_reducible",
        &reduce_cash(&1, &2, operation, operation_id)
      )

  defp dispatch(%{"type" => "charge_back_payment"} = operation, operation_id),
    do:
      with_payment(
        operation,
        operation_id,
        "payment_not_chargeable",
        &charge_back(&1, &2, operation, operation_id)
      )

  defp dispatch(%{"type" => "transfer_deposit"} = operation, operation_id),
    do: with_transfer_groups(operation, operation_id)

  defp dispatch(%{"type" => "start_finance_reporting"} = operation, operation_id),
    do: start_finance_reporting(operation, operation_id)

  defp dispatch(_operation, operation_id), do: reject(operation_id, "invalid_operation")

  defp start_finance_reporting(operation, operation_id) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} ->
        case Finance.start(starts_on) do
          {:ok, _reporting} ->
            %{operation_id: operation_id, status: "applied", starts_on: starts_on}

          {:error, :already_started} ->
            reject(operation_id, "reporting_already_started")
        end

      {:error, :date} ->
        reject(operation_id, "invalid_reporting_date")
    end
  end

  defp open_group(operation, operation_id) do
    cond do
      not Enum.all?(@top_level_open, &Map.has_key?(operation, &1)) ->
        reject(operation_id, "invalid_operation")

      not valid_open_identifiers?(operation) ->
        reject(operation_id, "invalid_operation")

      Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) ->
        reject(operation_id, "group_already_exists", operation["group_id"])

      operation["rate_plan"] not in @rate_plans ->
        reject(operation_id, "invalid_rate_plan", operation["group_id"])

      true ->
        create_group(operation, operation_id)
    end
  end

  defp create_group(operation, operation_id) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(arrival_on, departure_on) == :lt || :invalid_stay,
         {:ok, input_rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)

      rooms =
        Enum.map(input_rooms, fn room ->
          lodging = room.nightly_rate_cents * nights

          deposit =
            if operation["rate_plan"] == "flexible",
              do: round_percentage(lodging, 20),
              else: lodging

          Map.merge(room, %{lodging_total_cents: lodging, deposit_due_cents: deposit})
        end)

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version(operation["rate_plan"], booked_on),
        lodging_total_cents: sum_field(rooms, :lodging_total_cents),
        deposit_due_cents: sum_field(rooms, :deposit_due_cents)
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          now = DateTime.utc_now()

          rows =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              Map.merge(room, %{
                group_id: group.id,
                position: position,
                status: "active",
                cash_paid_cents: 0,
                credit_paid_cents: 0,
                inserted_at: now,
                updated_at: now
              })
            end)

          {_count, nil} = Repo.insert_all(Room, rows)

          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          }

        {:error, changeset} ->
          if changeset.errors[:group_id],
            do: reject(operation_id, "group_already_exists", operation["group_id"]),
            else: reject(operation_id, "invalid_operation")
      end
    else
      :invalid_stay -> reject(operation_id, "invalid_stay", operation["group_id"])
      {:error, :date} -> reject(operation_id, "invalid_stay", operation["group_id"])
      {:error, :rooms} -> reject(operation_id, "invalid_rooms", operation["group_id"])
    end
  end

  defp with_group(operation, operation_id, function) do
    group_id = operation["group_id"]

    if not nonempty_string?(group_id), do: reject(operation_id, "invalid_operation")

    case Repo.get_by(Group, group_id: group_id) do
      nil -> reject(operation_id, "group_not_found", group_id)
      group -> check_revision(group, operation, operation_id, function)
    end
  end

  defp with_payment(operation, operation_id, unsuitable_code, function) do
    payment_id = operation["payment_operation_id"]
    if not nonempty_string?(payment_id), do: reject(operation_id, "invalid_operation")

    case Repo.get_by(PartnerOperation, operation_id: payment_id) do
      nil ->
        reject(operation_id, "operation_not_found")

      payment ->
        if not applied_cash_payment?(payment), do: reject(operation_id, unsuitable_code)
        group = Repo.get_by!(Group, group_id: value(payment.result, "group_id"))

        check_revision(group, operation, operation_id, fn current ->
          function.(current, payment)
        end)
    end
  end

  defp check_revision(group, operation, operation_id, function) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      reject(operation_id, "stale_revision", group.group_id, %{
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      function.(group)
    end
  end

  defp with_transfer_groups(operation, operation_id) do
    source_id = operation["source_group_id"]
    destination_id = operation["destination_group_id"]

    if not (nonempty_string?(source_id) and nonempty_string?(destination_id)),
      do: reject(operation_id, "invalid_operation")

    source =
      Repo.get_by(Group, group_id: source_id) ||
        reject(operation_id, "group_not_found", source_id)

    destination =
      Repo.get_by(Group, group_id: destination_id) ||
        reject(operation_id, "group_not_found", destination_id)

    check_revision(source, operation, operation_id, fn current_source ->
      check_named_revision(
        destination,
        operation,
        "destination_expected_revision",
        operation_id,
        fn current_destination ->
          transfer_deposit(current_source, current_destination, operation, operation_id)
        end
      )
    end)
  end

  defp check_named_revision(group, operation, field, operation_id, function) do
    if Map.has_key?(operation, field) and operation[field] != group.revision do
      reject(operation_id, "stale_revision", group.group_id, %{
        expected_revision: operation[field],
        actual_revision: group.revision
      })
    else
      function.(group)
    end
  end

  defp transfer_deposit(source, destination, operation, operation_id) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      source.status != "active" ->
        reject(operation_id, "group_not_active", source.group_id)

      destination.status != "active" ->
        reject(operation_id, "group_not_active", destination.group_id)

      source.id == destination.id or source.guest_id != destination.guest_id ->
        reject(operation_id, "invalid_transfer")

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(amount) and amount > 0) ->
        reject(operation_id, "invalid_amount")

      amount > held_funding(source.id) ->
        reject(operation_id, "transfer_exceeds_held_funding")

      amount > outstanding(destination) ->
        reject(operation_id, "transfer_exceeds_outstanding")

      true ->
        chunks = draw_transfer_chunks!(source.id, amount)
        Enum.each(chunks, &allocate_transfer_chunk!(destination, &1))

        source = sync_group!(source)
        destination = sync_group!(destination)

        %{
          operation_id: operation_id,
          status: "applied",
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: amount,
          source_outstanding_deposit_cents: outstanding(source),
          destination_outstanding_deposit_cents: outstanding(destination),
          source_revision: source.revision,
          destination_revision: destination.revision
        }
    end
  end

  defp record_cash_payment(group, operation, operation_id) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(amount) and amount > 0) ->
        reject(operation_id, "invalid_amount", group.group_id)

      amount > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        allocate_to_rooms!(group, "cash", amount, operation_id, nil)
        group = sync_group!(group)

        %{
          operation_id: operation_id,
          status: "applied",
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        }
    end
  end

  defp reschedule_group(group, operation, operation_id) do
    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "new_arrival_on") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
             true <- Date.compare(new_arrival, occurred_on) == :gt do
          departure = Date.add(new_arrival, Date.diff(group.departure_on, group.arrival_on))
          group = update_group!(group, %{arrival_on: new_arrival, departure_on: departure})

          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            new_arrival_on: new_arrival,
            new_departure_on: departure,
            policy_version: policy_version(group),
            refundable_until: refundable_until(group),
            revision: group.revision
          }
        else
          _ -> reject(operation_id, "invalid_stay", group.group_id)
        end
    end
  end

  defp cancel_group(group, operation, operation_id) do
    cond do
      not Map.has_key?(operation, "occurred_on") -> reject(operation_id, "invalid_operation")
      group.status != "active" -> reject(operation_id, "group_not_active", group.group_id)
      true -> settle_rooms(group, active_rooms(group.id), operation, operation_id, :group)
    end
  end

  defp cancel_rooms(group, operation, operation_id) do
    room_ids = operation["room_ids"]

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "room_ids") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      not (is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &nonempty_string?/1) and
               Enum.uniq(room_ids) == room_ids) ->
        reject(operation_id, "invalid_rooms", group.group_id)

      true ->
        rooms =
          Repo.all(
            from room in Room,
              where:
                room.group_id == ^group.id and room.status == "active" and
                  room.room_id in ^room_ids,
              order_by: [asc: room.position]
          )

        if length(rooms) != length(room_ids),
          do: reject(operation_id, "invalid_rooms", group.group_id)

        settle_rooms(group, rooms, operation, operation_id, :rooms)
    end
  end

  defp settle_rooms(group, rooms, operation, operation_id, result_kind) do
    refund_method = Map.get(operation, "refund_method", "cash")

    if refund_method not in ["cash", "hotel_credit"],
      do: reject(operation_id, "invalid_operation", group.group_id)

    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} ->
        refundable = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable,
          do: reject(operation_id, "refund_method_not_available", group.group_id)

        room_db_ids = Enum.map(rooms, & &1.id)
        cash_allocations = held_allocations(room_db_ids, "cash")
        credit_allocations = held_allocations(room_db_ids, "credit")
        cash = sum_field(cash_allocations, :amount_cents)

        cash_disposition =
          cond do
            refundable and refund_method == "cash" -> "refunded"
            refundable -> "converted"
            true -> "retained"
          end

        Enum.each(cash_allocations, &set_disposition!(&1, cash_disposition))
        settle_credit_allocations(credit_allocations, refundable, occurred_on)

        credit_issued =
          if cash_disposition == "converted",
            do: issue_credit_lot(group, cash_allocations, cash, occurred_on, operation_id),
            else: 0

        Enum.each(rooms, fn room ->
          room
          |> Room.changeset(%{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
          |> Repo.update!()
        end)

        remaining? =
          Repo.exists?(
            from room in Room, where: room.group_id == ^group.id and room.status == "active"
          )

        extras = %{
          status: if(remaining?, do: "active", else: "cancelled"),
          cash_refunded_cents:
            group.cash_refunded_cents + if(cash_disposition == "refunded", do: cash, else: 0),
          cash_retained_cents:
            group.cash_retained_cents + if(cash_disposition == "retained", do: cash, else: 0),
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents +
              if(cash_disposition == "converted", do: cash, else: 0)
        }

        group = sync_group!(group, extras)

        base = %{
          operation_id: operation_id,
          status: "applied",
          group_id: group.group_id,
          refunded_cents: if(cash_disposition == "refunded", do: cash, else: 0),
          retained_cents: if(cash_disposition == "retained", do: cash, else: 0),
          credit_issued_cents: credit_issued,
          revision: group.revision
        }

        if result_kind == :rooms,
          do: Map.put(base, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
          else: base

      {:error, :date} ->
        reject(operation_id, "invalid_operation")
    end
  end

  defp apply_hotel_credit(group, operation, operation_id) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(amount) and amount > 0) ->
        reject(operation_id, "invalid_amount", group.group_id)

      amount > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        apply_credit_lots(group, amount, occurred_on, operation_id)
    end
  end

  defp apply_credit_lots(group, amount, occurred_on, operation_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    if sum_field(lots, :remaining_cents) < amount,
      do: reject(operation_id, "insufficient_credit", group.group_id)

    {chunks, 0} = consume_lots(lots, amount, [])

    Enum.each(chunks, fn {lot_id, cents} ->
      allocate_to_rooms!(group, "credit", cents, operation_id, lot_id)
    end)

    group = sync_group!(group)

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp consume_lots(_lots, 0, chunks), do: {Enum.reverse(chunks), 0}

  defp consume_lots([lot | rest], amount, chunks) do
    consumed = min(lot.remaining_cents, amount)

    lot
    |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - consumed})
    |> Repo.update!()

    consume_lots(rest, amount - consumed, [{lot.id, consumed} | chunks])
  end

  defp reduce_cash(group, payment, operation, operation_id) do
    amount = operation["amount_cents"]
    held = payment_allocations(payment.operation_id, "held")
    held_total = sum_field(held, :amount_cents)

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(amount) and amount > 0) ->
        reject(operation_id, "invalid_amount", group.group_id)

      held_total == 0 ->
        reject(operation_id, "payment_not_reducible", group.group_id)

      amount > held_total ->
        reject(operation_id, "reduction_exceeds_held_cash", group.group_id)

      true ->
        changed_group_ids = remove_held_cash(Enum.reverse(held), amount, "reduced")
        group = sync_changed_groups!(group, changed_group_ids)

        %{
          operation_id: operation_id,
          status: "applied",
          payment_operation_id: payment.operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        }
    end
  end

  defp charge_back(group, payment, operation, operation_id) do
    if not Map.has_key?(operation, "occurred_on") or not valid_date?(operation["occurred_on"]) do
      reject(operation_id, "invalid_operation")
    end

    allocations = payment_allocations(payment.operation_id)
    chargeable = Enum.reject(allocations, &(&1.disposition == "reduced"))

    if Enum.any?(allocations, &(&1.disposition == "charged_back")) or chargeable == [],
      do: reject(operation_id, "payment_not_chargeable", group.group_id)

    Enum.each(Enum.reverse(chargeable), fn allocation ->
      if allocation.disposition == "held",
        do: decrement_room_cash!(allocation.room_id, allocation.amount_cents)

      set_disposition!(allocation, "charged_back")
    end)

    revoke_payment_entitlements(payment.operation_id)

    changed_group_ids = MapSet.new(chargeable, & &1.group_id)
    group = sync_changed_groups!(group, changed_group_ids)

    %{
      operation_id: operation_id,
      status: "applied",
      payment_operation_id: payment.operation_id,
      group_id: group.group_id,
      charged_back_cents: sum_field(chargeable, :amount_cents),
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp allocate_to_rooms!(group, type, amount, operation_id, lot_id),
    do: allocate_room_chunks(active_rooms(group.id), group, type, amount, operation_id, lot_id)

  defp allocate_room_chunks(_rooms, _group, _type, 0, _operation_id, _lot_id), do: :ok

  defp allocate_room_chunks([room | rest], group, type, amount, operation_id, lot_id) do
    allocated =
      min(max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0), amount)

    if allocated > 0 do
      %FundingAllocation{}
      |> FundingAllocation.changeset(%{
        group_id: group.id,
        room_id: room.id,
        credit_lot_id: lot_id,
        funding_type: type,
        funding_operation_id: operation_id,
        payment_operation_id: if(type == "cash", do: operation_id, else: nil),
        amount_cents: allocated,
        disposition: "held"
      })
      |> Repo.insert!()

      field = if type == "cash", do: :cash_paid_cents, else: :credit_paid_cents
      room |> Room.changeset(%{field => Map.fetch!(room, field) + allocated}) |> Repo.update!()
    end

    allocate_room_chunks(rest, group, type, amount - allocated, operation_id, lot_id)
  end

  defp held_funding(group_id) do
    Repo.one(
      from allocation in FundingAllocation,
        where: allocation.group_id == ^group_id and allocation.disposition == "held",
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp draw_transfer_chunks!(group_id, amount) do
    allocations =
      Repo.all(
        from allocation in FundingAllocation,
          where: allocation.group_id == ^group_id and allocation.disposition == "held",
          order_by: [desc: allocation.id]
      )

    {chunks, 0} = draw_transfer_chunks!(allocations, amount, [])
    Enum.reverse(chunks)
  end

  defp draw_transfer_chunks!(_allocations, 0, chunks), do: {chunks, 0}

  defp draw_transfer_chunks!([allocation | rest], amount, chunks) do
    moved = min(allocation.amount_cents, amount)
    decrement_room_funding!(allocation, moved)

    if moved == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> FundingAllocation.changeset(%{
        amount_cents: allocation.amount_cents - moved,
        transferred: true
      })
      |> Repo.update!()
    end

    chunk = %{
      credit_lot_id: allocation.credit_lot_id,
      funding_type: allocation.funding_type,
      funding_operation_id: allocation.funding_operation_id,
      payment_operation_id: allocation.payment_operation_id,
      amount_cents: moved
    }

    draw_transfer_chunks!(rest, amount - moved, [chunk | chunks])
  end

  defp allocate_transfer_chunk!(destination, chunk) do
    allocate_transfer_chunk!(active_rooms(destination.id), destination, chunk, chunk.amount_cents)
  end

  defp allocate_transfer_chunk!(_rooms, _destination, _chunk, 0), do: :ok

  defp allocate_transfer_chunk!([room | rest], destination, chunk, amount) do
    available = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
    allocated = min(available, amount)

    if allocated > 0 do
      %FundingAllocation{}
      |> FundingAllocation.changeset(%{
        group_id: destination.id,
        room_id: room.id,
        credit_lot_id: chunk.credit_lot_id,
        funding_type: chunk.funding_type,
        funding_operation_id: chunk.funding_operation_id,
        payment_operation_id: chunk.payment_operation_id,
        amount_cents: allocated,
        disposition: "held",
        transferred: true
      })
      |> Repo.insert!()

      increment_room_funding!(room, chunk.funding_type, allocated)
    end

    allocate_transfer_chunk!(rest, destination, chunk, amount - allocated)
  end

  defp increment_room_funding!(room, "cash", amount),
    do:
      room
      |> Room.changeset(%{cash_paid_cents: room.cash_paid_cents + amount})
      |> Repo.update!()

  defp increment_room_funding!(room, "credit", amount),
    do:
      room
      |> Room.changeset(%{credit_paid_cents: room.credit_paid_cents + amount})
      |> Repo.update!()

  defp decrement_room_funding!(%FundingAllocation{funding_type: "cash"} = allocation, amount),
    do: decrement_room_cash!(allocation.room_id, amount)

  defp decrement_room_funding!(%FundingAllocation{funding_type: "credit"} = allocation, amount) do
    room = Repo.get!(Room, allocation.room_id)

    room
    |> Room.changeset(%{credit_paid_cents: room.credit_paid_cents - amount})
    |> Repo.update!()
  end

  defp held_allocations([], _type), do: []

  defp held_allocations(room_ids, type),
    do:
      Repo.all(
        from allocation in FundingAllocation,
          where:
            allocation.room_id in ^room_ids and allocation.funding_type == ^type and
              allocation.disposition == "held",
          order_by: [asc: allocation.id]
      )

  defp settle_credit_allocations(allocations, true, occurred_on) do
    Enum.each(allocations, fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)
      absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)
      excess = allocation.amount_cents - absorbed
      restored = if Date.compare(lot.expires_on, occurred_on) == :lt, do: 0, else: excess

      lot
      |> CreditLot.changeset(%{
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        remaining_cents: lot.remaining_cents + restored
      })
      |> Repo.update!()

      Repo.delete!(allocation)
    end)
  end

  defp settle_credit_allocations(allocations, false, _occurred_on),
    do: Enum.each(allocations, &Repo.delete!/1)

  defp issue_credit_lot(_group, _allocations, 0, _occurred_on, _operation_id), do: 0

  defp issue_credit_lot(group, allocations, cash, occurred_on, operation_id) do
    issued = cash + round_percentage(cash, 10)

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()

    allocations
    |> cash_principals_in_order()
    |> create_entitlements(lot.id, 0)

    issued
  end

  defp cash_principals_in_order(allocations) do
    {payment_ids, totals} =
      Enum.reduce(allocations, {[], %{}}, fn allocation, {payment_ids, totals} ->
        payment_id = allocation.payment_operation_id

        payment_ids =
          if Map.has_key?(totals, payment_id), do: payment_ids, else: payment_ids ++ [payment_id]

        {payment_ids,
         Map.update(totals, payment_id, allocation.amount_cents, &(&1 + allocation.amount_cents))}
      end)

    Enum.map(payment_ids, &{&1, Map.fetch!(totals, &1)})
  end

  defp create_entitlements([], _lot_id, _running), do: :ok

  defp create_entitlements([{payment_id, principal} | rest], lot_id, running) do
    entitlement =
      principal + round_percentage(running + principal, 10) - round_percentage(running, 10)

    %CreditEntitlement{}
    |> CreditEntitlement.changeset(%{
      credit_lot_id: lot_id,
      payment_operation_id: payment_id,
      principal_cents: principal,
      entitlement_cents: entitlement,
      revoked_cents: 0
    })
    |> Repo.insert!()

    create_entitlements(rest, lot_id, running + principal)
  end

  defp remove_held_cash(allocations, amount, disposition),
    do: remove_held_cash(allocations, amount, disposition, MapSet.new())

  defp remove_held_cash(_allocations, 0, _disposition, group_ids), do: group_ids

  defp remove_held_cash([allocation | rest], amount, disposition, group_ids) do
    removed = min(allocation.amount_cents, amount)
    decrement_room_cash!(allocation.room_id, removed)

    if removed == allocation.amount_cents do
      set_disposition!(allocation, disposition)
    else
      allocation
      |> FundingAllocation.changeset(%{amount_cents: allocation.amount_cents - removed})
      |> Repo.update!()

      %FundingAllocation{}
      |> FundingAllocation.changeset(%{
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        funding_type: "cash",
        funding_operation_id: allocation.funding_operation_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: removed,
        disposition: disposition,
        transferred: allocation.transferred
      })
      |> Repo.insert!()
    end

    remove_held_cash(
      rest,
      amount - removed,
      disposition,
      MapSet.put(group_ids, allocation.group_id)
    )
  end

  defp decrement_room_cash!(room_id, amount) do
    room = Repo.get!(Room, room_id)
    room |> Room.changeset(%{cash_paid_cents: room.cash_paid_cents - amount}) |> Repo.update!()
  end

  defp set_disposition!(allocation, disposition),
    do: allocation |> FundingAllocation.changeset(%{disposition: disposition}) |> Repo.update!()

  defp revoke_payment_entitlements(payment_id) do
    Repo.all(
      from entitlement in CreditEntitlement,
        where:
          entitlement.payment_operation_id == ^payment_id and
            entitlement.revoked_cents < entitlement.entitlement_cents
    )
    |> Enum.each(fn entitlement ->
      amount = entitlement.entitlement_cents - entitlement.revoked_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, amount)

      lot
      |> CreditLot.changeset(%{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - removed
      })
      |> Repo.update!()

      entitlement
      |> CreditEntitlement.changeset(%{revoked_cents: entitlement.entitlement_cents})
      |> Repo.update!()
    end)
  end

  defp payment_allocations(payment_id, disposition \\ nil) do
    query =
      from allocation in FundingAllocation,
        where:
          allocation.funding_type == "cash" and allocation.payment_operation_id == ^payment_id,
        order_by: [asc: allocation.id]

    Repo.all(
      if disposition, do: from(a in query, where: a.disposition == ^disposition), else: query
    )
  end

  defp cash_dispositions(payment_id) do
    base = Map.new(@cash_dispositions, &{&1, 0})

    Repo.all(
      from allocation in FundingAllocation,
        where:
          allocation.payment_operation_id == ^payment_id and allocation.funding_type == "cash",
        group_by: allocation.disposition,
        select: {allocation.disposition, sum(allocation.amount_cents)}
    )
    |> Enum.into(base)
  end

  defp payment_transferred?(payment_id) do
    Repo.exists?(
      from allocation in FundingAllocation,
        where:
          allocation.payment_operation_id == ^payment_id and allocation.funding_type == "cash" and
            allocation.transferred == true
    )
  end

  defp held_cash_by_group(payment_id) do
    Repo.all(
      from allocation in FundingAllocation,
        join: group in Group,
        on: group.id == allocation.group_id,
        where:
          allocation.payment_operation_id == ^payment_id and allocation.funding_type == "cash" and
            allocation.disposition == "held",
        group_by: group.group_id,
        order_by: [asc: group.group_id],
        select: %{group_id: group.group_id, amount_cents: sum(allocation.amount_cents)}
    )
  end

  defp applied_cash_payment?(operation),
    do:
      operation.operation_type == "record_cash_payment" and
        value(operation.result, "status") == "applied"

  defp active_rooms(group_id),
    do:
      Repo.all(
        from room in Room,
          where: room.group_id == ^group_id and room.status == "active",
          order_by: room.position
      )

  defp sync_group!(group, extras \\ %{}) do
    rooms = active_rooms(group.id)
    cash = sum_field(rooms, :cash_paid_cents)
    credit = sum_field(rooms, :credit_paid_cents)

    attrs =
      Map.merge(
        %{
          lodging_total_cents: sum_field(rooms, :lodging_total_cents),
          deposit_due_cents: sum_field(rooms, :deposit_due_cents),
          deposit_paid_cents: cash + credit,
          cash_paid_cents: cash,
          credit_paid_cents: credit,
          cash_refunded_cents: group_cash_disposition(group.id, "refunded"),
          cash_retained_cents: group_cash_disposition(group.id, "retained"),
          cash_converted_to_credit_cents: group_cash_disposition(group.id, "converted")
        },
        extras
      )

    update_group!(group, attrs)
  end

  defp sync_changed_groups!(addressed_group, changed_group_ids) do
    group_ids =
      changed_group_ids
      |> MapSet.put(addressed_group.id)
      |> MapSet.to_list()

    updated =
      Enum.map(group_ids, fn group_id ->
        group_id |> then(&Repo.get!(Group, &1)) |> sync_group!()
      end)

    Enum.find(updated, &(&1.id == addressed_group.id))
  end

  defp group_cash_disposition(group_id, disposition) do
    Repo.one(
      from allocation in FundingAllocation,
        where:
          allocation.group_id == ^group_id and allocation.funding_type == "cash" and
            allocation.disposition == ^disposition,
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp credit_liability(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from allocation in FundingAllocation,
          where: allocation.funding_type == "credit" and allocation.disposition == "held",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp credit_shortfall do
    Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.map(fn lot ->
      allocated =
        Repo.one(
          from allocation in FundingAllocation,
            where:
              allocation.credit_lot_id == ^lot.id and allocation.funding_type == "credit" and
                allocation.disposition == "held",
            select: coalesce(sum(allocation.amount_cents), 0)
        )

      min(lot.unrecovered_clawback_cents, allocated)
    end)
    |> Enum.sum()
  end

  defp policy_version(%Group{policy_version: version}) when is_binary(version), do: version
  defp policy_version(%Group{} = group), do: policy_version(group.rate_plan, group.booked_on)
  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, deadline) != :gt
    end
  end

  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)

  defp update_group!(group, attrs),
    do:
      group
      |> Group.changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:revision)
      |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())
      |> Repo.update!()

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          nonempty_string?(room_id) and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(room_ids) == room_ids,
      do:
        {:ok,
         Enum.map(rooms, &%{room_id: &1["room_id"], nightly_rate_cents: &1["nightly_rate_cents"]})},
      else: {:error, :rooms}
  end

  defp validate_rooms(_), do: {:error, :rooms}

  defp valid_open_identifiers?(operation),
    do: Enum.all?(~w(group_id guest_id property_id), &nonempty_string?(operation[&1]))

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :date}
    end
  end

  defp parse_date(_), do: {:error, :date}
  defp valid_date?(value), do: match?({:ok, _}, parse_date(value))
  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0
  defp sum_field(items, field), do: items |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum()
  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp reject(operation_id, code, group_id \\ nil, extra \\ %{}),
    do: throw({:partner_operation_rejected, rejected(operation_id, code, group_id, extra)})

  defp rejected(operation_id, code, group_id \\ nil, extra \\ %{}),
    do:
      %{operation_id: operation_id, status: "rejected", code: code}
      |> maybe_put(:group_id, group_id)
      |> Map.merge(extra)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
