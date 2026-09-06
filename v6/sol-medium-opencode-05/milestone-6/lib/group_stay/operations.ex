defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{
    CashDisposition,
    CashDispositionBackfill,
    CreditAllocation,
    CreditEntitlement,
    CreditExpirySchedule,
    CreditLot,
    FinanceMovement,
    FinanceOpeningCash,
    FinanceReporting,
    Funding,
    Group,
    OperationRecord,
    Repo,
    Room,
    RoomAllocation
  }

  @rate_plans ["flexible", "advance_purchase"]
  @max_sqlite_integer 9_223_372_036_854_775_807
  @max_credit_convertible_principal 8_384_883_669_867_978_006
  @cash_movement_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_movement_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  def process_batch(operations) do
    Enum.map(operations, fn operation ->
      prepare_accounting(operation)

      case Repo.transaction(fn -> process_idempotently(operation) end, mode: :immediate) do
        {:ok, result} -> result
        {:error, result} -> result
      end
    end)
  end

  defp prepare_accounting(operation) do
    operation_id = rememberable_operation_id(operation)

    if is_nil(operation_id) or is_nil(Repo.get_by(OperationRecord, operation_id: operation_id)) do
      operation
      |> addressed_group_ids()
      |> Enum.each(&initialize_group/1)
    end
  end

  # Transfer accounting is initialized inside its operation transaction so source resolution
  # remains the first observable and state-changing step.
  defp addressed_group_ids(%{"type" => "transfer_deposit"}), do: []

  defp addressed_group_ids(%{"type" => type, "group_id" => group_id})
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group",
              "cancel_rooms"
            ] and
              is_binary(group_id),
       do: [group_id]

  defp addressed_group_ids(%{"type" => type, "payment_operation_id" => payment_id})
       when type in ["reduce_cash_payment", "charge_back_payment"] and is_binary(payment_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_id) do
      %OperationRecord{} = record when record.operation_type == "record_cash_payment" ->
        [record.result["group_id"]]

      _ ->
        []
    end
  end

  defp addressed_group_ids(_operation), do: []

  defp initialize_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{accounting_initialized: false} ->
        Repo.transaction(
          fn ->
            case Repo.get_by(Group, group_id: group_id) do
              nil -> :ok
              group -> ensure_accounting(group)
            end
          end,
          mode: :immediate
        )

        :ok

      _ ->
        :ok
    end
  end

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_operation_result(_), do: nil

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        Repo.transaction(fn -> ensure_accounting(group) end, mode: :immediate)
        |> elem(1)
        |> load_group()
    end
  end

  def get_group(_), do: nil

  def group_totals(group) do
    active_rooms = Enum.filter(group.rooms, &(&1.status == "active"))

    Enum.reduce(active_rooms, zero_room_totals(), fn room, totals ->
      amounts = room_amounts(room)

      %{
        lodging_total_cents: totals.lodging_total_cents + room.lodging_total_cents,
        deposit_due_cents: totals.deposit_due_cents + room.deposit_due_cents,
        cash_paid_cents: totals.cash_paid_cents + amounts.cash_paid_cents,
        credit_paid_cents: totals.credit_paid_cents + amounts.credit_paid_cents,
        deposit_paid_cents:
          totals.deposit_paid_cents + amounts.cash_paid_cents + amounts.credit_paid_cents,
        outstanding_deposit_cents:
          totals.outstanding_deposit_cents + room.deposit_due_cents - amounts.cash_paid_cents -
            amounts.credit_paid_cents
      }
    end)
  end

  def room_amounts(room) do
    Enum.reduce(room.allocations, %{cash_paid_cents: 0, credit_paid_cents: 0}, fn allocation,
                                                                                  totals ->
      Map.update!(totals, paid_key(allocation.funding.kind), &(&1 + allocation.amount_cents))
    end)
  end

  def payment_statement(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        :not_found

      record ->
        if applied_cash_record?(record) do
          group = Repo.get_by!(Group, group_id: record.result["group_id"])
          {:ok, group} = Repo.transaction(fn -> ensure_accounting(group) end, mode: :immediate)
          funding = Repo.get_by!(Funding, operation_id: operation_id, kind: "cash")
          held = held_cents(funding.id)

          statement = %{
            payment_operation_id: operation_id,
            original_group_id: group.group_id,
            recorded_cents: funding.original_amount_cents,
            held_cents: held,
            refunded_cents: funding.refunded_cents,
            retained_cents: funding.retained_cents,
            converted_to_credit_cents: funding.converted_cents,
            reduced_cents: funding.reduced_cents,
            charged_back_cents: funding.charged_back_cents
          }

          statement =
            if funding.participated_in_transfer,
              do: Map.put(statement, :held_by_group, held_by_group(funding.id)),
              else: statement

          {:ok, statement}
        else
          :not_reconcilable
        end
    end
  end

  def payment_statement(_), do: :not_found

  def ledger(on \\ Date.utc_today()) do
    initialize_all_groups()

    totals =
      Repo.all(from f in Funding, where: f.kind == "cash")
      |> Enum.reduce(
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0
        },
        fn funding, totals ->
          totals
          |> Map.update!(:cash_held_cents, &(&1 + held_cents(funding.id)))
          |> Map.update!(:cash_refunded_cents, &(&1 + funding.refunded_cents))
          |> Map.update!(:cash_retained_cents, &(&1 + funding.retained_cents))
          |> Map.update!(:cash_converted_to_credit_cents, &(&1 + funding.converted_cents))
          |> Map.update!(:cash_reduced_cents, &(&1 + funding.reduced_cents))
          |> Map.update!(:cash_charged_back_cents, &(&1 + funding.charged_back_cents))
        end
      )

    totals
    |> Map.put(:credit_liability_cents, credit_liability(on))
    |> Map.put(:credit_shortfall_cents, credit_shortfall())
  end

  def guest_credit(guest_id, on) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(
          lots,
          &%{
            source_operation_id: &1.source_operation_id,
            remaining_cents: &1.remaining_cents,
            expires_on: Date.to_iso8601(&1.expires_on)
          }
        )
    }
  end

  def report_date(nil), do: {:ok, Date.utc_today()}
  def report_date(value), do: parse_date(value)

  def daily_finance_report(value) do
    case parse_date(value) do
      {:ok, date} ->
        {:ok, result} =
          Repo.transaction(fn ->
            with %FinanceReporting{} = reporting <- reporting_config(),
                 true <- Date.compare(date, reporting.starts_on) != :lt do
              {:ok, build_daily_finance_report(reporting, date)}
            else
              _ -> {:error, :not_available}
            end
          end)

        result

      :error ->
        {:error, :invalid_date}
    end
  end

  def policy_version(%Group{policy_version: version}) when is_binary(version), do: version
  def policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version(%Group{booked_on: booked_on}),
    do: if(Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  def refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> group.arrival_on |> Date.add(-14) |> Date.to_iso8601()
      "flex-30" -> group.arrival_on |> Date.add(-30) |> Date.to_iso8601()
      "advance-nonrefundable" -> nil
    end
  end

  def outstanding(group),
    do: group |> load_group() |> group_totals() |> Map.fetch!(:outstanding_deposit_cents)

  defp process_idempotently(operation) do
    case rememberable_operation_id(operation) do
      nil ->
        process_operation(operation)

      operation_id ->
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          nil ->
            process_and_remember(operation_id, operation)

          record ->
            if(record.submission === operation,
              do: record.result,
              else: rejected(operation_id, "operation_id_conflict")
            )
        end
    end
  end

  defp process_and_remember(operation_id, operation) do
    previous = Process.put({__MODULE__, :operation}, operation)

    result =
      try do
        process_operation(operation)
      after
        if is_nil(previous),
          do: Process.delete({__MODULE__, :operation}),
          else: Process.put({__MODULE__, :operation}, previous)
      end

    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: operation_id,
      operation_type: submitted_type(operation),
      submission: operation,
      result: result
    })
    |> Repo.insert!()

    result
  end

  defp process_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp process_operation(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp process_operation(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp process_operation(%{"type" => type} = operation)
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group",
              "cancel_rooms"
            ] do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> rejected(operation_id, "group_not_found")
        group -> process_existing(operation, operation_id, ensure_accounting(group))
      end
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp process_operation(%{"type" => type} = operation)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, payment_id} <- required_string(operation, "payment_operation_id") do
      process_payment_adjustment(operation, operation_id, payment_id)
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp process_operation(operation) when is_map(operation),
    do: rejected(operation_id(operation), "invalid_operation")

  defp process_operation(_), do: rejected(nil, "invalid_operation")

  defp start_finance_reporting(operation) do
    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> start_finance_reporting(operation, operation_id)
      :error -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp start_finance_reporting(operation, operation_id) do
    with {:ok, starts_on_value} <- required_value(operation, "starts_on"),
         {:ok, starts_on} <- parse_date(starts_on_value) do
      case reporting_config() do
        nil ->
          initialize_all_groups()
          backfill_cash_dispositions()

          reporting =
            %FinanceReporting{}
            |> FinanceReporting.changeset(%{
              starts_on: starts_on,
              opening_credit_liability_cents: credit_liability(starts_on)
            })
            |> Repo.insert!()

          held_cash_by_property()
          |> Enum.each(fn {property_id, amount} ->
            %FinanceOpeningCash{}
            |> FinanceOpeningCash.changeset(%{
              reporting_id: reporting.id,
              property_id: property_id,
              opening_held_cents: amount
            })
            |> Repo.insert!()
          end)

          Repo.delete_all(CreditExpirySchedule)

          Repo.all(
            from l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^starts_on
          )
          |> Enum.each(&set_expiry_schedule(&1, &1.remaining_cents))

          applied(operation_id, %{starts_on: Date.to_iso8601(starts_on)})

        %FinanceReporting{} ->
          rejected(operation_id, "reporting_already_started")
      end
    else
      _ -> rejected(operation_id, "invalid_reporting_date")
    end
  end

  defp open_group(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, occurred} <- required_value(operation, "occurred_on"),
         {:ok, arrival} <- required_value(operation, "arrival_on"),
         {:ok, departure} <- required_value(operation, "departure_on"),
         {:ok, rate_plan} <- required_value(operation, "rate_plan"),
         {:ok, rooms} <- required_value(operation, "rooms") do
      cond do
        Repo.exists?(from g in Group, where: g.group_id == ^group_id) ->
          rejected(operation_id, "group_already_exists")

        rate_plan not in @rate_plans ->
          rejected(operation_id, "invalid_rate_plan")

        true ->
          create_group(operation_id, %{
            group_id: group_id,
            guest_id: guest_id,
            property_id: property_id,
            occurred_on: occurred,
            arrival_on: arrival,
            departure_on: departure,
            rate_plan: rate_plan,
            rooms: rooms
          })
      end
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, source_id} <- required_string(operation, "source_group_id") do
      case Repo.get_by(Group, group_id: source_id) do
        nil ->
          rejected_for_group(operation_id, "group_not_found", source_id)

        source ->
          source = ensure_accounting(source)

          case required_string(operation, "destination_group_id") do
            :error ->
              rejected(operation_id, "invalid_operation")

            {:ok, destination_id} ->
              case Repo.get_by(Group, group_id: destination_id) do
                nil ->
                  rejected_for_group(operation_id, "group_not_found", destination_id)

                destination ->
                  transfer_between_groups(
                    operation,
                    operation_id,
                    source,
                    ensure_accounting(destination)
                  )
              end
          end
      end
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp transfer_between_groups(operation, operation_id, source, destination) do
    with :ok <- validate_expected_revision(operation, source),
         :ok <-
           validate_expected_revision(operation, destination, "destination_expected_revision") do
      case Map.fetch(operation, "amount_cents") do
        :error ->
          rejected(operation_id, "invalid_operation")

        {:ok, amount} ->
          validate_and_transfer(operation_id, source, destination, amount)
      end
    else
      {:stale, expected} ->
        stale(operation_id, source, expected)

      {:stale, expected, "destination_expected_revision"} ->
        stale(operation_id, destination, expected)

      :invalid ->
        rejected(operation_id, "invalid_operation")
    end
  end

  defp validate_and_transfer(operation_id, source, destination, amount) do
    source_held = held_by_group_cents(source.id)
    destination_outstanding = outstanding(destination)

    cond do
      source.id == destination.id or source.guest_id != destination.guest_id ->
        rejected(operation_id, "invalid_transfer")

      source.status != "active" ->
        rejected_for_group(operation_id, "group_not_active", source.group_id)

      destination.status != "active" ->
        rejected_for_group(operation_id, "group_not_active", destination.group_id)

      not (is_integer(amount) and amount > 0) ->
        rejected(operation_id, "invalid_amount")

      amount > source_held ->
        rejected(operation_id, "transfer_exceeds_held_funding")

      amount > destination_outstanding ->
        rejected(operation_id, "transfer_exceeds_outstanding")

      true ->
        chunks = draw_group_allocations(source, amount)
        cash_moved = cash_chunk_total(chunks)
        allocate_chunks(destination, chunks)

        funding_ids = chunks |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        Repo.update_all(
          from(f in Funding, where: f.id in ^funding_ids and f.kind == "cash"),
          set: [participated_in_transfer: true]
        )

        updated_source = increment_revision(source)
        updated_destination = increment_revision(destination)

        if cash_moved > 0 do
          record_cash_movement(source.property_id, %{transferred_out_cents: cash_moved})
          record_cash_movement(destination.property_id, %{transferred_in_cents: cash_moved})
        end

        applied(operation_id, %{
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: amount,
          source_outstanding_deposit_cents: outstanding(updated_source),
          destination_outstanding_deposit_cents: outstanding(updated_destination),
          source_revision: updated_source.revision,
          destination_revision: updated_destination.revision
        })
    end
  end

  defp create_group(operation_id, attrs) do
    with {:ok, booked_on} <- parse_date(attrs.occurred_on),
         {:ok, arrival_on} <- parse_date(attrs.arrival_on),
         {:ok, departure_on} <- parse_date(attrs.departure_on),
         true <- Date.compare(departure_on, arrival_on) == :gt do
      nights = Date.diff(departure_on, arrival_on)

      case validate_rooms(attrs.rooms, nights, attrs.rate_plan) do
        {:ok, rooms, lodging_total, deposit_due} ->
          group =
            %Group{}
            |> Group.changeset(%{
              group_id: attrs.group_id,
              guest_id: attrs.guest_id,
              property_id: attrs.property_id,
              booked_on: booked_on,
              arrival_on: arrival_on,
              departure_on: departure_on,
              rate_plan: attrs.rate_plan,
              policy_version: policy_version(attrs.rate_plan, booked_on),
              lodging_total_cents: lodging_total,
              deposit_due_cents: deposit_due,
              accounting_initialized: true
            })
            |> Repo.insert!()

          now = DateTime.utc_now() |> DateTime.truncate(:second)

          rows =
            Enum.map(
              rooms,
              &Map.merge(&1, %{
                id: Ecto.UUID.generate(),
                group_ref: group.id,
                inserted_at: now,
                updated_at: now
              })
            )

          {count, _} = Repo.insert_all(Room, rows)
          if count != length(rows), do: raise("failed to persist every room")

          applied(operation_id, %{
            group_id: group.group_id,
            deposit_due_cents: deposit_due,
            revision: 1
          })

        :error ->
          rejected(operation_id, "invalid_rooms")
      end
    else
      _ -> rejected(operation_id, "invalid_stay")
    end
  end

  defp process_existing(operation, operation_id, group) do
    with :ok <- validate_expected_revision(operation, group) do
      case operation["type"] do
        "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id, group)
        "reschedule_group" -> reschedule_group(operation, operation_id, group)
        "cancel_group" -> cancel_group(operation, operation_id, group)
        "cancel_rooms" -> cancel_rooms(operation, operation_id, group)
      end
    else
      {:stale, expected} -> stale(operation_id, group, expected)
      :invalid -> rejected(operation_id, "invalid_operation")
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    with {:ok, occurred} <- required_value(operation, "occurred_on"),
         {:ok, _} <- parse_date(occurred),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        not (is_integer(amount) and amount > 0) ->
          rejected(operation_id, "invalid_amount")

        amount > outstanding(group) ->
          rejected(operation_id, "payment_exceeds_outstanding")

        true ->
          funding = create_funding(group, "cash", amount, operation_id)
          allocate_funding(group, funding, amount)
          updated = increment_revision(group)
          record_cash_movement(group.property_id, %{received_cents: amount})

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          })
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with {:ok, occurred} <- required_value(operation, "occurred_on"),
         {:ok, occurred_on} <- parse_date(occurred),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        not (is_integer(amount) and amount > 0) ->
          rejected(operation_id, "invalid_amount")

        amount > outstanding(group) ->
          rejected(operation_id, "payment_exceeds_outstanding")

        available_credit(group.guest_id, occurred_on) < amount ->
          rejected(operation_id, "insufficient_credit")

        true ->
          consume_credit(group, amount, occurred_on, operation_id)
          updated = increment_revision(group)

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          })
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with {:ok, occurred} <- required_value(operation, "occurred_on"),
         {:ok, arrival} <- required_value(operation, "new_arrival_on") do
      if group.status != "active" do
        rejected(operation_id, "group_not_active")
      else
        with {:ok, occurred_on} <- parse_date(occurred),
             {:ok, new_arrival} <- parse_date(arrival),
             true <- Date.compare(new_arrival, occurred_on) == :gt do
          departure = Date.add(new_arrival, Date.diff(group.departure_on, group.arrival_on))

          updated =
            group
            |> Group.changeset(%{
              arrival_on: new_arrival,
              departure_on: departure,
              revision: group.revision + 1
            })
            |> Repo.update!()

          applied(operation_id, %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival),
            new_departure_on: Date.to_iso8601(departure),
            policy_version: policy_version(updated),
            refundable_until: refundable_until(updated),
            revision: updated.revision
          })
        else
          _ -> rejected(operation_id, "invalid_stay")
        end
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp cancel_group(operation, operation_id, group) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      room_ids =
        Repo.all(
          from r in Room,
            where: r.group_ref == ^group.id and r.status == "active",
            select: r.room_id
        )

      settle_rooms(operation, operation_id, group, room_ids, false)
    end
  end

  defp cancel_rooms(operation, operation_id, group) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      case Map.fetch(operation, "room_ids") do
        {:ok, room_ids} when is_list(room_ids) ->
          settle_rooms(operation, operation_id, group, room_ids, true)

        _ ->
          rejected(operation_id, "invalid_operation")
      end
    end
  end

  defp settle_rooms(operation, operation_id, group, room_ids, selected?) do
    with {:ok, occurred} <- required_value(operation, "occurred_on"),
         {:ok, occurred_on} <- parse_date(occurred),
         {:ok, method} <- refund_method(operation) do
      cond do
        room_ids == [] or not Enum.all?(room_ids, &(is_binary(&1) and &1 != "")) or
            length(Enum.uniq(room_ids)) != length(room_ids) ->
          rejected(operation_id, "invalid_rooms")

        true ->
          settle_valid_room_ids(operation_id, group, room_ids, occurred_on, method, selected?)
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp settle_valid_room_ids(operation_id, group, room_ids, occurred_on, method, selected?) do
    rooms =
      Repo.all(
        from r in Room,
          where: r.group_ref == ^group.id and r.room_id in ^room_ids and r.status == "active",
          order_by: r.position
      )

    cond do
      length(rooms) != length(room_ids) ->
        rejected(operation_id, "invalid_rooms")

      method == "hotel_credit" and not refundable?(group, occurred_on) ->
        rejected(operation_id, "refund_method_not_available")

      true ->
        settlement =
          settle_room_allocations(
            rooms,
            group,
            occurred_on,
            refundable?(group, occurred_on),
            method,
            operation_id
          )

        Enum.each(rooms, &(&1 |> Ecto.Changeset.change(status: "cancelled") |> Repo.update!()))

        active_remain =
          Repo.exists?(from r in Room, where: r.group_ref == ^group.id and r.status == "active")

        updated =
          group
          |> Group.changeset(%{
            status: if(active_remain, do: "active", else: "cancelled"),
            revision: group.revision + 1,
            refunded_cents: group.refunded_cents + settlement.refunded_cents,
            retained_cents: group.retained_cents + settlement.retained_cents,
            cash_converted_to_credit_cents:
              group.cash_converted_to_credit_cents + settlement.converted_cents
          })
          |> Repo.update!()

        fields = %{
          group_id: group.group_id,
          refunded_cents: settlement.refunded_cents,
          retained_cents: settlement.retained_cents,
          credit_issued_cents: settlement.credit_issued_cents,
          revision: updated.revision
        }

        fields =
          if selected?,
            do: Map.put(fields, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
            else: fields

        applied(operation_id, fields)
    end
  end

  defp settle_room_allocations(rooms, group, occurred_on, refundable, method, operation_id) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(from a in RoomAllocation, where: a.room_id in ^room_ids, preload: [funding: :lot])

    {cash, credit} = Enum.split_with(allocations, &(&1.funding.kind == "cash"))
    cash_by_funding = Enum.group_by(cash, & &1.funding_id)
    cash_total = Enum.sum(Enum.map(cash, & &1.amount_cents))

    disposition =
      cond do
        not refundable -> :retained_cents
        method == "hotel_credit" -> :converted_cents
        true -> :refunded_cents
      end

    Enum.each(cash_by_funding, fn {_id, items} ->
      funding = hd(items).funding
      amount = Enum.sum(Enum.map(items, & &1.amount_cents))

      funding
      |> Funding.changeset(%{disposition => Map.fetch!(funding, disposition) + amount})
      |> Repo.update!()

      add_cash_disposition(funding.id, group.property_id, disposition, amount)

      Enum.each(items, &Repo.delete!/1)
    end)

    contributors =
      cash
      |> Enum.sort_by(& &1.allocation_order)
      |> Enum.map(&{&1.funding, &1.amount_cents})

    credit_movements = settle_credit_allocations(credit, occurred_on, refundable)
    Enum.each(credit, &Repo.delete!/1)

    issued =
      if refundable and method == "hotel_credit",
        do: issue_credit_lot(group, operation_id, occurred_on, contributors),
        else: 0

    if cash_total > 0 do
      field =
        if disposition == :converted_cents, do: :converted_to_credit_cents, else: disposition

      record_cash_movement(group.property_id, %{field => cash_total})
    end

    record_credit_movement(credit_movements)

    %{
      refunded_cents: if(disposition == :refunded_cents, do: cash_total, else: 0),
      retained_cents: if(disposition == :retained_cents, do: cash_total, else: 0),
      converted_cents: if(disposition == :converted_cents, do: cash_total, else: 0),
      credit_issued_cents: issued
    }
  end

  defp issue_credit_lot(_group, _operation_id, _occurred_on, []), do: 0

  defp issue_credit_lot(group, operation_id, occurred_on, contributors) do
    principal = Enum.sum(Enum.map(contributors, &elem(&1, 1)))
    issued = bonus_value(principal)

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()

    reporting = reporting_config()

    if reporting &&
         Date.compare(Date.add(lot.expires_on, 1), current_operation_posting_date(reporting)) !=
           :gt do
      record_credit_movement(%{issued_cents: issued, expired_cents: issued})
    else
      set_expiry_schedule(lot, issued)
      record_credit_movement(%{issued_cents: issued})
    end

    {entitlements, _running} =
      Enum.reduce(contributors, {%{}, 0}, fn {funding, amount}, {entitlements, running} ->
        entitlement = bonus_value(running + amount) - bonus_value(running)

        entry =
          Map.get(entitlements, funding.id, %{
            funding: funding,
            principal_cents: 0,
            entitlement_cents: 0
          })

        entry = %{
          entry
          | principal_cents: entry.principal_cents + amount,
            entitlement_cents: entry.entitlement_cents + entitlement
        }

        {Map.put(entitlements, funding.id, entry), running + amount}
      end)

    Enum.each(entitlements, fn {_funding_id, entry} ->
      %CreditEntitlement{}
      |> CreditEntitlement.changeset(%{
        lot_id: lot.id,
        funding_id: entry.funding.id,
        principal_cents: entry.principal_cents,
        entitlement_cents: entry.entitlement_cents
      })
      |> Repo.insert!()
    end)

    issued
  end

  defp settle_credit_allocations(allocations, occurred_on, true) do
    allocations
    |> Enum.group_by(& &1.funding.lot_id)
    |> Enum.reduce(zero_credit_movements(), fn {lot_id, allocations}, totals ->
      lot = Repo.get!(CreditLot, lot_id)
      amount = Enum.sum(Enum.map(allocations, & &1.amount_cents))
      absorbed = min(amount, lot.unrecovered_clawback_cents)
      excess = amount - absorbed
      available = if Date.compare(lot.expires_on, occurred_on) == :lt, do: 0, else: excess
      floor_expiry = if expiry_precedes_reporting_floor?(lot), do: available, else: 0
      expired = excess - available + floor_expiry

      lot
      |> CreditLot.changeset(%{
        remaining_cents: lot.remaining_cents + available,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      })
      |> Repo.update!()

      if available > 0 and floor_expiry == 0, do: adjust_expiry_schedule(lot, available)

      totals
      |> Map.update!(:absorbed_cents, &(&1 + absorbed))
      |> Map.update!(:expired_cents, &(&1 + expired))
    end)
  end

  defp settle_credit_allocations(allocations, _occurred_on, false) do
    %{
      zero_credit_movements()
      | consumed_cents: Enum.sum(Enum.map(allocations, & &1.amount_cents))
    }
  end

  defp process_payment_adjustment(operation, operation_id, payment_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_id) do
      nil ->
        rejected(operation_id, "operation_not_found")

      record ->
        if applied_cash_record?(record) do
          group = Repo.get_by!(Group, group_id: record.result["group_id"]) |> ensure_accounting()

          with :ok <- validate_expected_revision(operation, group) do
            funding = Repo.get_by!(Funding, operation_id: payment_id, kind: "cash")

            case operation["type"] do
              "reduce_cash_payment" -> reduce_payment(operation, operation_id, group, funding)
              "charge_back_payment" -> charge_back(operation_id, group, funding)
            end
          else
            {:stale, expected} -> stale(operation_id, group, expected)
            :invalid -> rejected(operation_id, "invalid_operation")
          end
        else
          code =
            if operation["type"] == "reduce_cash_payment",
              do: "payment_not_reducible",
              else: "payment_not_chargeable"

          rejected(operation_id, code)
        end
    end
  end

  defp reduce_payment(operation, operation_id, group, funding) do
    held = held_cents(funding.id)

    case Map.fetch(operation, "amount_cents") do
      :error ->
        rejected(operation_id, "invalid_operation")

      {:ok, amount} ->
        cond do
          not (is_integer(amount) and amount > 0) ->
            rejected(operation_id, "invalid_amount")

          held == 0 ->
            rejected(operation_id, "payment_not_reducible")

          amount > held ->
            rejected(operation_id, "reduction_exceeds_held_cash")

          true ->
            {affected_group_ids, removed_by_property} = remove_allocations(funding, amount)

            funding
            |> Funding.changeset(%{reduced_cents: funding.reduced_cents + amount})
            |> Repo.update!()

            Enum.each(removed_by_property, fn {property_id, removed} ->
              add_cash_disposition(funding.id, property_id, :reduced_cents, removed)
              record_cash_movement(property_id, %{reduced_cents: removed})
            end)

            updated = increment_changed_groups(group, affected_group_ids)

            applied(operation_id, %{
              payment_operation_id: funding.operation_id,
              group_id: group.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: outstanding(updated),
              revision: updated.revision
            })
        end
    end
  end

  defp charge_back(operation_id, group, funding) do
    chargeable =
      funding.original_amount_cents - funding.reduced_cents - funding.charged_back_cents

    if chargeable <= 0 or funding.charged_back_cents > 0 do
      rejected(operation_id, "payment_not_chargeable")
    else
      held = held_cents(funding.id)
      ensure_funding_dispositions(funding)
      {affected_group_ids, held_by_property} = remove_allocations(funding, held)
      revoke_entitlements(funding)

      dispositions = Repo.all(from d in CashDisposition, where: d.funding_id == ^funding.id)

      Enum.each(dispositions, fn disposition ->
        settled =
          disposition.refunded_cents + disposition.retained_cents + disposition.converted_cents

        if settled > 0 do
          record_cash_movement(disposition.property_id, %{
            refunded_cents: -disposition.refunded_cents,
            retained_cents: -disposition.retained_cents,
            converted_to_credit_cents: -disposition.converted_cents,
            charged_back_cents: settled
          })

          disposition
          |> CashDisposition.changeset(%{
            refunded_cents: 0,
            retained_cents: 0,
            converted_cents: 0,
            charged_back_cents: disposition.charged_back_cents + settled
          })
          |> Repo.update!()
        end
      end)

      Enum.each(held_by_property, fn {property_id, amount} ->
        add_cash_disposition(funding.id, property_id, :charged_back_cents, amount)
        record_cash_movement(property_id, %{charged_back_cents: amount})
      end)

      funding
      |> Funding.changeset(%{
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: funding.charged_back_cents + chargeable
      })
      |> Repo.update!()

      updated = increment_changed_groups(group, affected_group_ids)

      applied(operation_id, %{
        payment_operation_id: funding.operation_id,
        group_id: group.group_id,
        charged_back_cents: chargeable,
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      })
    end
  end

  defp revoke_entitlements(funding) do
    Repo.all(from e in CreditEntitlement, where: e.funding_id == ^funding.id, preload: [:lot])
    |> Enum.each(fn entitlement ->
      taken = min(entitlement.entitlement_cents, entitlement.lot.remaining_cents)
      missing = entitlement.entitlement_cents - taken
      revoked = removable_expiry_amount(entitlement.lot, taken)

      entitlement.lot
      |> CreditLot.changeset(%{
        remaining_cents: entitlement.lot.remaining_cents - taken,
        unrecovered_clawback_cents: entitlement.lot.unrecovered_clawback_cents + missing
      })
      |> Repo.update!()

      if revoked > 0 do
        adjust_expiry_schedule(entitlement.lot, -revoked)
        record_credit_movement(%{revoked_cents: revoked})
      end
    end)
  end

  defp remove_allocations(_funding, 0), do: {[], %{}}

  defp remove_allocations(funding, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          join: g in Group,
          on: g.id == r.group_ref,
          where: a.funding_id == ^funding.id,
          order_by: [desc: a.allocation_order],
          select: {a, g.id, g.property_id}
      )

    {_, group_ids, properties} =
      Enum.reduce_while(allocations, {amount, [], %{}}, fn {allocation, group_id, property_id},
                                                           {left, ids, properties} ->
        removed = min(left, allocation.amount_cents)

        if removed == allocation.amount_cents,
          do: Repo.delete!(allocation),
          else:
            allocation
            |> RoomAllocation.changeset(%{amount_cents: allocation.amount_cents - removed})
            |> Repo.update!()

        ids = [group_id | ids]
        properties = Map.update(properties, property_id, removed, &(&1 + removed))

        if removed == left,
          do: {:halt, {0, ids, properties}},
          else: {:cont, {left - removed, ids, properties}}
      end)

    {Enum.uniq(group_ids), properties}
  end

  defp draw_group_allocations(group, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          where: r.group_ref == ^group.id and r.status == "active",
          order_by: [desc: a.allocation_order]
      )

    {_, chunks} =
      Enum.reduce_while(allocations, {amount, []}, fn allocation, {left, chunks} ->
        moved = min(left, allocation.amount_cents)

        if moved == allocation.amount_cents,
          do: Repo.delete!(allocation),
          else:
            allocation
            |> RoomAllocation.changeset(%{amount_cents: allocation.amount_cents - moved})
            |> Repo.update!()

        state = {left - moved, [{allocation.funding_id, moved} | chunks]}
        if moved == left, do: {:halt, state}, else: {:cont, state}
      end)

    Enum.reverse(chunks)
  end

  defp allocate_chunks(group, chunks) do
    rooms =
      Repo.all(
        from r in Room,
          where: r.group_ref == ^group.id and r.status == "active",
          order_by: r.position,
          preload: [:allocations]
      )

    initial = {chunks, next_allocation_order()}

    {remaining, _order} =
      Enum.reduce_while(rooms, initial, fn room, {chunks, order} ->
        capacity =
          room.deposit_due_cents - Enum.sum(Enum.map(room.allocations, & &1.amount_cents))

        {chunks, order} = fill_room(room.id, capacity, chunks, order)

        if chunks == [], do: {:halt, {chunks, order}}, else: {:cont, {chunks, order}}
      end)

    if remaining != [], do: raise("failed to allocate complete transfer")
  end

  defp fill_room(_room_id, 0, chunks, order), do: {chunks, order}
  defp fill_room(_room_id, _capacity, [], order), do: {[], order}

  defp fill_room(room_id, capacity, [{funding_id, amount} | rest], order) do
    used = min(capacity, amount)

    %RoomAllocation{}
    |> RoomAllocation.changeset(%{
      room_id: room_id,
      funding_id: funding_id,
      amount_cents: used,
      allocation_order: order
    })
    |> Repo.insert!()

    chunks = if used == amount, do: rest, else: [{funding_id, amount - used} | rest]
    fill_room(room_id, capacity - used, chunks, order + 1)
  end

  defp create_funding(group, kind, amount, operation_id, lot_id \\ nil) do
    order =
      Repo.one(
        from f in Funding,
          where: f.group_ref == ^group.id,
          select: coalesce(max(f.funding_order), 0)
      ) + 1

    %Funding{}
    |> Funding.changeset(%{
      group_ref: group.id,
      kind: kind,
      original_amount_cents: amount,
      operation_id: operation_id,
      lot_id: lot_id,
      funding_order: order
    })
    |> Repo.insert!()
  end

  defp allocate_funding(group, funding, amount) do
    rooms =
      Repo.all(
        from r in Room,
          where: r.group_ref == ^group.id and r.status == "active",
          order_by: r.position,
          preload: [allocations: :funding]
      )

    Enum.reduce_while(rooms, {amount, next_allocation_order()}, fn room, {left, order} ->
      paid = Enum.sum(Enum.map(room.allocations, & &1.amount_cents))
      used = min(left, room.deposit_due_cents - paid)

      if used > 0,
        do:
          %RoomAllocation{}
          |> RoomAllocation.changeset(%{
            room_id: room.id,
            funding_id: funding.id,
            amount_cents: used,
            allocation_order: order
          })
          |> Repo.insert!()

      if used == left,
        do: {:halt, {0, order + 1}},
        else: {:cont, {left - used, if(used > 0, do: order + 1, else: order)}}
    end)
  end

  defp consume_credit(group, amount, on, operation_id) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^group.guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    Enum.reduce_while(lots, amount, fn lot, left ->
      used = min(left, lot.remaining_cents)
      lot |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - used}) |> Repo.update!()

      if expiry_precedes_reporting_floor?(lot) do
        record_credit_movement(%{expired_cents: -used})
      else
        adjust_expiry_schedule(lot, -used)
      end

      funding = create_funding(group, "credit", used, operation_id, lot.id)
      allocate_funding(group, funding, used)
      if used == left, do: {:halt, 0}, else: {:cont, left - used}
    end)
  end

  defp ensure_accounting(%Group{accounting_initialized: true} = group), do: group

  defp ensure_accounting(group) do
    records = Repo.all(from r in OperationRecord, order_by: r.id)

    cash_records =
      Enum.filter(
        records,
        &(applied_cash_record?(&1) and &1.result["group_id"] == group.group_id)
      )

    credit_records =
      Enum.filter(
        records,
        &(&1.operation_type == "apply_hotel_credit" and &1.result["status"] == "applied" and
            &1.result["group_id"] == group.group_id)
      )

    durable_cash = Enum.sum(Enum.map(cash_records, & &1.result["amount_cents"]))
    durable_credit = Enum.sum(Enum.map(credit_records, & &1.result["amount_cents"]))
    legacy_cash = max(group.cash_paid_cents - durable_cash, 0)
    legacy_credit = max(group.credit_paid_cents - durable_credit, 0)

    old_credit =
      Repo.all(
        from a in CreditAllocation,
          join: l in CreditLot,
          on: l.id == a.lot_id,
          where: a.group_ref == ^group.id,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id],
          select: a
      )

    legacy_cash_fundings =
      if legacy_cash > 0, do: [create_funding(group, "cash", legacy_cash, nil)], else: []

    chunks = Enum.map(old_credit, &{&1.lot_id, &1.amount_cents})
    {legacy_credit_fundings, chunks} = take_credit_chunks(group, nil, legacy_credit, chunks, [])

    durable_records = Enum.filter(records, &(&1 in cash_records or &1 in credit_records))

    {durable_fundings, _chunks} =
      Enum.reduce(durable_records, {[], chunks}, fn record, {fundings, chunks} ->
        amount = record.result["amount_cents"]

        if record.operation_type == "record_cash_payment" do
          {fundings ++ [create_funding(group, "cash", amount, record.operation_id)], chunks}
        else
          {made, remaining} = take_credit_chunks(group, record.operation_id, amount, chunks, [])
          {fundings ++ made, remaining}
        end
      end)

    all = legacy_cash_fundings ++ legacy_credit_fundings ++ durable_fundings
    cash_fundings = Enum.filter(all, &(&1.kind == "cash"))

    if group.status == "active" do
      Enum.each(
        Enum.sort_by(all, & &1.funding_order),
        &allocate_funding(group, &1, &1.original_amount_cents)
      )
    else
      settled_fundings = classify_legacy_settlement(cash_fundings, group)
      backfill_entitlements(group, records, settled_fundings)
    end

    group |> Group.changeset(%{accounting_initialized: true}) |> Repo.update!()
  end

  defp take_credit_chunks(_group, _operation_id, 0, chunks, made),
    do: {Enum.reverse(made), chunks}

  defp take_credit_chunks(group, operation_id, left, [{lot_id, amount} | rest], made) do
    used = min(left, amount)
    funding = create_funding(group, "credit", used, operation_id, lot_id)
    chunks = if used == amount, do: rest, else: [{lot_id, amount - used} | rest]
    take_credit_chunks(group, operation_id, left - used, chunks, [funding | made])
  end

  defp take_credit_chunks(_group, _operation_id, _left, [], made), do: {Enum.reverse(made), []}

  defp classify_legacy_settlement(fundings, group) do
    {fundings, _} = distribute_disposition(fundings, group.refunded_cents, :refunded_cents)
    {fundings, _} = distribute_disposition(fundings, group.retained_cents, :retained_cents)

    {fundings, _} =
      distribute_disposition(fundings, group.cash_converted_to_credit_cents, :converted_cents)

    fundings
  end

  defp backfill_entitlements(group, records, cash_fundings) do
    cancellation_ids =
      records
      |> Enum.filter(
        &(&1.operation_type == "cancel_group" and &1.result["status"] == "applied" and
            &1.result["group_id"] == group.group_id and &1.result["credit_issued_cents"] > 0)
      )
      |> Enum.map(& &1.operation_id)

    Repo.all(from l in CreditLot, where: l.source_operation_id in ^cancellation_ids)
    |> Enum.each(fn lot ->
      cash_fundings
      |> Enum.filter(&(&1.converted_cents > 0))
      |> Enum.sort_by(& &1.funding_order)
      |> Enum.reduce(0, fn funding, running ->
        entitlement = bonus_value(running + funding.converted_cents) - bonus_value(running)

        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          lot_id: lot.id,
          funding_id: funding.id,
          principal_cents: funding.converted_cents,
          entitlement_cents: entitlement
        })
        |> Repo.insert!()

        running + funding.converted_cents
      end)
    end)
  end

  defp distribute_disposition(fundings, amount, field) do
    Enum.map_reduce(fundings, amount, fn funding, left ->
      already = funding.refunded_cents + funding.retained_cents + funding.converted_cents
      used = min(left, funding.original_amount_cents - already)

      updated =
        if used > 0,
          do:
            funding
            |> Funding.changeset(%{field => Map.fetch!(funding, field) + used})
            |> Repo.update!(),
          else: funding

      {updated, left - used}
    end)
  end

  defp initialize_all_groups do
    Repo.all(from g in Group, where: g.accounting_initialized == false)
    |> Enum.each(fn group ->
      Repo.transaction(fn -> ensure_accounting(group) end, mode: :immediate)
    end)
  end

  defp build_daily_finance_report(reporting, date) do
    opening_cash =
      Repo.all(from o in FinanceOpeningCash, where: o.reporting_id == ^reporting.id)
      |> Map.new(&{&1.property_id, &1.opening_held_cents})

    movements =
      Repo.all(
        from m in FinanceMovement,
          where: m.posting_date >= ^reporting.starts_on and m.posting_date <= ^date
      )

    properties =
      (Map.keys(opening_cash) ++
         (movements
          |> Enum.map(& &1.property_id)
          |> Enum.reject(&is_nil/1)))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        before =
          movements
          |> Enum.filter(
            &(&1.property_id == property_id and Date.compare(&1.posting_date, date) == :lt)
          )
          |> sum_cash_movements()

        today =
          movements
          |> Enum.filter(&(&1.property_id == property_id and &1.posting_date == date))
          |> sum_cash_movements()

        opening = Map.get(opening_cash, property_id, 0) + cash_effect(before)
        closing = opening + cash_effect(today)

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: today,
          closing_held_cents: closing
        }
      end)
      |> Enum.reject(fn entry ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          Enum.all?(@cash_movement_fields, &(Map.fetch!(entry.movements, &1) == 0))
      end)

    prior_credit =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_date, date) == :lt))
      |> sum_credit_movements()
      |> add_expiry_movements(reporting.starts_on, Date.add(date, -1))

    today_credit =
      movements
      |> Enum.filter(&(&1.posting_date == date))
      |> sum_credit_movements()
      |> add_expiry_movements(date, date)

    opening_liability = reporting.opening_credit_liability_cents + credit_effect(prior_credit)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening_liability,
        movements: today_credit,
        closing_liability_cents: opening_liability + credit_effect(today_credit)
      }
    }
  end

  defp sum_cash_movements(movements) do
    Enum.reduce(movements, zero_cash_movements(), fn movement, totals ->
      Enum.reduce(@cash_movement_fields, totals, fn field, totals ->
        Map.update!(totals, field, &(&1 + Map.fetch!(movement, field)))
      end)
    end)
  end

  defp sum_credit_movements(movements) do
    Enum.reduce(movements, zero_credit_movements(), fn movement, totals ->
      Enum.reduce(@credit_movement_fields, totals, fn field, totals ->
        Map.update!(totals, field, &(&1 + Map.fetch!(movement, field)))
      end)
    end)
  end

  defp add_expiry_movements(movements, first, last) do
    if Date.compare(first, last) == :gt do
      movements
    else
      expired =
        Repo.all(
          from s in CreditExpirySchedule,
            where: s.expires_on >= ^first and s.expires_on <= ^last,
            select: s.amount_cents
        )
        |> Enum.sum()

      Map.update!(movements, :expired_cents, &(&1 + expired))
    end
  end

  defp cash_effect(movements) do
    movements.received_cents + movements.transferred_in_cents - movements.transferred_out_cents -
      movements.refunded_cents - movements.retained_cents -
      movements.converted_to_credit_cents - movements.reduced_cents -
      movements.charged_back_cents
  end

  defp credit_effect(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp zero_cash_movements,
    do: Map.new(@cash_movement_fields, &{&1, 0})

  defp zero_credit_movements,
    do: Map.new(@credit_movement_fields, &{&1, 0})

  defp record_cash_movement(property_id, fields) do
    record_finance_movement(Map.put(fields, :property_id, property_id))
  end

  defp record_credit_movement(fields) do
    if Enum.any?(@credit_movement_fields, &(Map.get(fields, &1, 0) != 0)),
      do: record_finance_movement(fields),
      else: :ok
  end

  defp record_finance_movement(fields) do
    with %FinanceReporting{} = reporting <- reporting_config(),
         %{"operation_id" => operation_id} = operation <- Process.get({__MODULE__, :operation}) do
      posting_date = operation_posting_date(operation, reporting.starts_on)

      %FinanceMovement{}
      |> FinanceMovement.changeset(
        fields
        |> Map.put(:posting_date, posting_date)
        |> Map.put(:operation_id, operation_id)
      )
      |> Repo.insert!()
    else
      _ -> :ok
    end
  end

  defp operation_posting_date(operation, starts_on) do
    occurred_on =
      case parse_date(operation["occurred_on"]) do
        {:ok, date} -> date
        :error -> starts_on
      end

    if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
  end

  defp current_operation_posting_date(reporting) do
    operation = Process.get({__MODULE__, :operation}) || %{}
    operation_posting_date(operation, reporting.starts_on)
  end

  defp reporting_config, do: Repo.get_by(FinanceReporting, singleton_key: 1)

  defp held_cash_by_property do
    Repo.all(
      from a in RoomAllocation,
        join: f in Funding,
        on: f.id == a.funding_id,
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == r.group_ref,
        where: f.kind == "cash" and r.status == "active",
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
  end

  defp cash_chunk_total(chunks) do
    ids = chunks |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    kinds = Repo.all(from f in Funding, where: f.id in ^ids, select: {f.id, f.kind}) |> Map.new()

    chunks
    |> Enum.filter(&(Map.fetch!(kinds, elem(&1, 0)) == "cash"))
    |> Enum.sum_by(&elem(&1, 1))
  end

  defp add_cash_disposition(funding_id, property_id, field, amount) do
    disposition =
      Repo.get_by(CashDisposition, funding_id: funding_id, property_id: property_id) ||
        %CashDisposition{funding_id: funding_id, property_id: property_id}

    disposition
    |> CashDisposition.changeset(%{field => Map.fetch!(disposition, field) + amount})
    |> Repo.insert_or_update!()
  end

  defp backfill_cash_dispositions do
    CashDispositionBackfill.backfill()
  end

  defp ensure_funding_dispositions(funding) do
    CashDispositionBackfill.backfill(funding.id)
  end

  defp set_expiry_schedule(lot, amount) do
    attrs = %{lot_id: lot.id, expires_on: Date.add(lot.expires_on, 1), amount_cents: amount}

    case Repo.get(CreditExpirySchedule, lot.id) do
      nil -> %CreditExpirySchedule{} |> CreditExpirySchedule.changeset(attrs) |> Repo.insert!()
      schedule -> schedule |> CreditExpirySchedule.changeset(attrs) |> Repo.update!()
    end
  end

  defp adjust_expiry_schedule(_lot, 0), do: :ok

  defp adjust_expiry_schedule(lot, delta) do
    case Repo.get(CreditExpirySchedule, lot.id) do
      nil ->
        if delta > 0, do: set_expiry_schedule(lot, delta), else: :ok

      schedule ->
        schedule
        |> CreditExpirySchedule.changeset(%{amount_cents: max(schedule.amount_cents + delta, 0)})
        |> Repo.update!()
    end
  end

  defp removable_expiry_amount(lot, amount) do
    case reporting_config() do
      nil ->
        amount

      reporting ->
        posting_date = current_operation_posting_date(reporting)
        if Date.compare(posting_date, lot.expires_on) == :gt, do: 0, else: amount
    end
  end

  defp expiry_precedes_reporting_floor?(lot) do
    case reporting_config() do
      nil -> false
      reporting -> Date.compare(Date.add(lot.expires_on, 1), reporting.starts_on) != :gt
    end
  end

  defp load_group(group) do
    Repo.preload(
      group,
      [rooms: {from(r in Room, order_by: r.position), [allocations: :funding]}],
      force: true
    )
  end

  defp held_cents(funding_id),
    do:
      Repo.one(
        from a in RoomAllocation,
          where: a.funding_id == ^funding_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp held_by_group_cents(group_ref),
    do:
      Repo.one(
        from a in RoomAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          where: r.group_ref == ^group_ref and r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp held_by_group(funding_id) do
    Repo.all(
      from a in RoomAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == r.group_ref,
        where: a.funding_id == ^funding_id and r.status == "active",
        group_by: g.group_id,
        order_by: g.group_id,
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  defp next_allocation_order,
    do:
      Repo.one(
        from a in RoomAllocation,
          select: coalesce(max(a.allocation_order), 0)
      ) + 1

  defp available_credit(guest_id, on),
    do:
      Repo.one(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

  defp credit_liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from a in RoomAllocation,
          join: f in Funding,
          on: f.id == a.funding_id,
          join: r in Room,
          on: r.id == a.room_id,
          where: f.kind == "credit" and r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + allocated
  end

  defp credit_shortfall do
    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, total ->
      allocated =
        Repo.one(
          from a in RoomAllocation,
            join: f in Funding,
            on: f.id == a.funding_id,
            join: r in Room,
            on: r.id == a.room_id,
            where: f.lot_id == ^lot.id and r.status == "active",
            select: coalesce(sum(a.amount_cents), 0)
        )

      total + min(lot.unrecovered_clawback_cents, allocated)
    end)
  end

  defp increment_revision(group),
    do: group |> Group.changeset(%{revision: group.revision + 1}) |> Repo.update!()

  defp increment_changed_groups(original_group, affected_group_ids) do
    affected_group_ids
    |> Enum.reject(&(&1 == original_group.id))
    |> Enum.each(fn group_id -> Repo.get!(Group, group_id) |> increment_revision() end)

    increment_revision(original_group)
  end

  defp refundable?(group, on) do
    case policy_version(group) do
      "flex-14" -> Date.compare(on, Date.add(group.arrival_on, -14)) != :gt
      "flex-30" -> Date.compare(on, Date.add(group.arrival_on, -30)) != :gt
      "advance-nonrefundable" -> false
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> :error
    end
  end

  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)
  defp paid_key("cash"), do: :cash_paid_cents
  defp paid_key("credit"), do: :credit_paid_cents

  defp zero_room_totals,
    do: %{
      lodging_total_cents: 0,
      deposit_due_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      deposit_paid_cents: 0,
      outstanding_deposit_cents: 0
    }

  defp applied_cash_record?(record),
    do: record.operation_type == "record_cash_payment" and record.result["status"] == "applied"

  defp rememberable_operation_id(%{"operation_id" => id}) when is_binary(id), do: id
  defp rememberable_operation_id(_), do: nil
  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_), do: nil
  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  defp validate_expected_revision(operation, group, key \\ "expected_revision") do
    case Map.fetch(operation, key) do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected > 0 ->
        if expected == group.revision do
          :ok
        else
          if key == "expected_revision", do: {:stale, expected}, else: {:stale, expected, key}
        end

      _ ->
        :invalid
    end
  end

  defp validate_rooms(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    parsed =
      Enum.with_index(rooms)
      |> Enum.reduce_while([], fn
        {%{"room_id" => id, "nightly_rate_cents" => rate}, position}, acc
        when is_binary(id) and id != "" and is_integer(rate) and rate > 0 ->
          lodging = rate * nights
          deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          {:cont,
           [
             %{
               room_id: id,
               nightly_rate_cents: rate,
               position: position,
               status: "active",
               lodging_total_cents: lodging,
               deposit_due_cents: deposit
             }
             | acc
           ]}

        _, _ ->
          {:halt, :error}
      end)

    case parsed do
      :error ->
        :error

      reversed ->
        rooms = Enum.reverse(reversed)
        lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
        deposit = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

        if Enum.uniq_by(rooms, & &1.room_id) == rooms and
             Enum.all?(rooms, &(&1.nightly_rate_cents <= @max_sqlite_integer)) and
             lodging <= @max_sqlite_integer and deposit <= @max_credit_convertible_principal,
           do: {:ok, rooms, lodging, deposit},
           else: :error
    end
  end

  defp validate_rooms(_, _, _), do: :error
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp required_value(map, key), do: Map.fetch(map, key)
  defp operation_id(%{"operation_id" => id}) when is_binary(id), do: id
  defp operation_id(_), do: nil

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejected(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}

  defp rejected_for_group(operation_id, code, group_id),
    do: %{operation_id: operation_id, status: "rejected", code: code, group_id: group_id}

  defp stale(operation_id, group, expected),
    do: %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: expected,
      actual_revision: group.revision
    }
end
