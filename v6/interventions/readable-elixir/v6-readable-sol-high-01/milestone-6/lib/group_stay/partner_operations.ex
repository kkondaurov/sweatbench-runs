defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner operations in order with durable, transactional idempotency.

  Each identified operation owns an immediate transaction, with its domain
  work isolated in a savepoint. A handled rejection rolls back the savepoint
  and still commits its immutable operation record. Applied domain changes and
  their record commit together, while an exception rolls both back. The
  immediate transaction also serializes SQLite writers, giving concurrent
  retries at-most-once effects.
  """

  alias GroupStay.{Credits, FinanceReporting, Payments, Repo}
  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Reservations
  alias GroupStay.Reservations.{DepositPolicy, DepositTransfer, Group, Room, RoomAccounting}

  @rate_plans ~w(flexible advance_purchase)
  @group_operation_types ~w(
    record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms
  )
  @payment_operation_types ~w(reduce_cash_payment charge_back_payment)
  @transfer_operation_type "transfer_deposit"
  @domain_savepoint "group_stay_domain_operation"

  @doc "Applies operations sequentially and returns one result for each input."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process/1)
  end

  @doc "Returns the result stored for a previously handled operation."
  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record.result}
    end
  end

  def fetch_result(_operation_id), do: {:error, :operation_not_found}

  defp process(operation) do
    case durable_operation_id(operation) do
      {:ok, operation_id} -> process_durably(operation, operation_id)
      :error -> process_domain_operation(operation)
    end
  end

  defp process_durably(operation, operation_id) do
    transact(fn ->
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        nil -> process_and_remember(operation, operation_id)
        record -> replay_or_reject_conflict(record, operation)
      end
    end)
  end

  defp process_and_remember(operation, operation_id) do
    result = operation |> run_domain_savepoint() |> json_value()

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

  defp replay_or_reject_conflict(
         %OperationRecord{submission: submission, result: result},
         operation
       ) do
    if submission == operation do
      result
    else
      reject(operation, "operation_id_conflict")
    end
  end

  # The adapter's transaction API only tracks one nested savepoint. Tests add a
  # sandbox transaction, so explicit SQL keeps this domain boundary correct at
  # every runtime nesting depth supported by the application.
  defp run_domain_savepoint(operation) do
    Repo.query!("SAVEPOINT #{@domain_savepoint}")

    try do
      result = FinanceReporting.track(operation, fn -> process_domain_operation(operation) end)
      Repo.query!("RELEASE SAVEPOINT #{@domain_savepoint}")
      result
    catch
      {:handled_rejection, rejection} ->
        Repo.query!("ROLLBACK TO SAVEPOINT #{@domain_savepoint}")
        Repo.query!("RELEASE SAVEPOINT #{@domain_savepoint}")
        rejection
    end
  end

  defp process_domain_operation(%{"type" => "open_group"} = operation),
    do: open_group(operation)

  defp process_domain_operation(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp process_domain_operation(%{"type" => type} = operation)
       when type in @group_operation_types do
    mutate_group(operation, type)
  end

  defp process_domain_operation(%{"type" => type} = operation)
       when type in @payment_operation_types do
    mutate_payment(operation, type)
  end

  defp process_domain_operation(%{"type" => @transfer_operation_type} = operation) do
    mutate_transfer(operation)
  end

  defp process_domain_operation(operation), do: reject(operation, "invalid_operation")

  defp start_finance_reporting(operation) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} ->
        with :ok <- require_identifiers(operation, ~w(operation_id)) do
          case FinanceReporting.start(starts_on) do
            :ok ->
              applied(operation, starts_on: starts_on)

            {:error, :reporting_already_started} ->
              halt_with_rejection(operation, "reporting_already_started", [])
          end
        else
          _ -> reject(operation, "invalid_operation")
        end

      :error ->
        reject(operation, "invalid_reporting_date")
    end
  end

  defp open_group(operation) do
    with :ok <- require_identifiers(operation, ~w(operation_id group_id guest_id property_id)),
         :ok <-
           require_fields(
             operation,
             ~w(occurred_on arrival_on departure_on rate_plan rooms)
           ),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]) do
      if Repo.get_by(Group, group_id: operation["group_id"]) do
        halt_with_rejection(operation, "group_already_exists", group_id: operation["group_id"])
      else
        create_group(operation, booked_on)
      end
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp create_group(operation, booked_on) do
    with {:ok, arrival_on} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- required_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on, operation),
         :ok <- validate_rate_plan(operation),
         {:ok, rooms} <- validate_rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = lodging_total(rooms, nights)
      deposit_due = deposit_due(rooms, nights, operation["rate_plan"])

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: DepositPolicy.version(operation["rate_plan"], booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0
      }

      case %Group{} |> Group.open_changeset(attrs) |> Repo.insert() do
        {:ok, group} ->
          insert_rooms!(group, rooms, nights, group.rate_plan)

          applied(operation,
            group_id: group.group_id,
            deposit_due_cents: deposit_due,
            revision: group.revision
          )

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            halt_with_rejection(operation, "group_already_exists",
              group_id: operation["group_id"]
            )
          else
            raise "could not persist a validated group: #{inspect(changeset.errors)}"
          end
      end
    end
  end

  defp mutate_group(operation, type) do
    with :ok <- require_identifiers(operation, ~w(operation_id group_id)),
         :ok <- require_fields(operation, required_fields(type)) do
      case Repo.get_by(Group, group_id: operation["group_id"]) do
        nil ->
          halt_with_rejection(operation, "group_not_found", group_id: operation["group_id"])

        group ->
          with :ok <- check_revision(operation, group),
               {:ok, occurred_on} <-
                 required_date(operation, "occurred_on", "invalid_operation") do
            apply_group_operation(type, operation, group, occurred_on)
          end
      end
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp apply_group_operation(_type, operation, %Group{status: status}, _occurred_on)
       when status != "active" do
    halt_with_rejection(operation, "group_not_active", group_id: operation["group_id"])
  end

  defp apply_group_operation("record_cash_payment", operation, group, _occurred_on) do
    amount = operation["amount_cents"]
    outstanding = Reservations.outstanding_deposit(group)

    cond do
      not (is_integer(amount) and amount > 0) ->
        halt_with_rejection(operation, "invalid_amount", group_id: group.group_id)

      amount > outstanding ->
        halt_with_rejection(operation, "payment_exceeds_outstanding", group_id: group.group_id)

      true ->
        {_payment, group} = Payments.record!(group, operation["operation_id"], amount)
        group = update_group!(group, %{revision: group.revision + 1})

        applied(operation,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Reservations.outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp apply_group_operation("apply_hotel_credit", operation, group, occurred_on) do
    amount = operation["amount_cents"]
    outstanding = Reservations.outstanding_deposit(group)

    cond do
      not (is_integer(amount) and amount > 0) ->
        halt_with_rejection(operation, "invalid_amount", group_id: group.group_id)

      amount > outstanding ->
        halt_with_rejection(operation, "payment_exceeds_outstanding", group_id: group.group_id)

      Credits.available_balance(group.guest_id, occurred_on) < amount ->
        halt_with_rejection(operation, "insufficient_credit", group_id: group.group_id)

      true ->
        :ok =
          Credits.allocate(
            group,
            amount,
            occurred_on,
            operation["operation_id"],
            RoomAccounting.next_funding_order()
          )

        group = Repo.reload!(group)
        group = update_group!(group, %{revision: group.revision + 1})

        applied(operation,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Reservations.outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp apply_group_operation("reschedule_group", operation, group, occurred_on) do
    case required_date(operation, "new_arrival_on", "invalid_stay") do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          new_departure_on = Date.add(new_arrival_on, stay_length)

          group =
            update_group!(group, %{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            })

          applied(operation,
            group_id: group.group_id,
            new_arrival_on: new_arrival_on,
            new_departure_on: new_departure_on,
            policy_version: DepositPolicy.version(group),
            refundable_until: DepositPolicy.refundable_until(group),
            revision: group.revision
          )
        else
          halt_with_rejection(operation, "invalid_stay", group_id: group.group_id)
        end

      _ ->
        halt_with_rejection(operation, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_group_operation("cancel_group", operation, group, occurred_on) do
    settle_cancellation(
      operation,
      group,
      RoomAccounting.active_rooms(group),
      occurred_on,
      :group
    )
  end

  defp apply_group_operation("cancel_rooms", operation, group, occurred_on) do
    case RoomAccounting.select_active_rooms(group, operation["room_ids"]) do
      {:ok, rooms} ->
        settle_cancellation(operation, group, rooms, occurred_on, :rooms)

      {:error, :invalid_rooms} ->
        halt_with_rejection(operation, "invalid_rooms", group_id: group.group_id)
    end
  end

  defp mutate_transfer(operation) do
    with :ok <-
           require_identifiers(
             operation,
             ~w(operation_id source_group_id destination_group_id)
           ),
         :ok <- require_fields(operation, ~w(occurred_on amount_cents)) do
      source_group_id = operation["source_group_id"]
      destination_group_id = operation["destination_group_id"]

      case Repo.get_by(Group, group_id: source_group_id) do
        nil ->
          halt_with_rejection(operation, "group_not_found", group_id: source_group_id)

        source ->
          case Repo.get_by(Group, group_id: destination_group_id) do
            nil ->
              halt_with_rejection(operation, "group_not_found", group_id: destination_group_id)

            destination ->
              with :ok <- check_revision(operation, source),
                   :ok <-
                     check_revision(
                       operation,
                       destination,
                       "destination_expected_revision"
                     ) do
                case parse_date(operation["occurred_on"]) do
                  {:ok, _occurred_on} ->
                    apply_transfer(operation, source, destination)

                  :error ->
                    halt_with_rejection(operation, "invalid_operation", [])
                end
              end
          end
      end
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp apply_transfer(operation, source, destination) do
    amount = operation["amount_cents"]

    cond do
      source.status != "active" ->
        halt_with_rejection(operation, "group_not_active", group_id: source.group_id)

      destination.status != "active" ->
        halt_with_rejection(operation, "group_not_active", group_id: destination.group_id)

      source.id == destination.id or source.guest_id != destination.guest_id ->
        halt_with_rejection(operation, "invalid_transfer", [])

      not (is_integer(amount) and amount > 0) ->
        halt_with_rejection(operation, "invalid_amount", [])

      amount > source.deposit_paid_cents ->
        halt_with_rejection(operation, "transfer_exceeds_held_funding", [])

      amount > Reservations.outstanding_deposit(destination) ->
        halt_with_rejection(operation, "transfer_exceeds_outstanding", [])

      true ->
        {source, destination} = DepositTransfer.move!(source, destination, amount)
        groups = increment_revisions!([source, destination], source)
        source = Map.fetch!(groups, source.id)
        destination = Map.fetch!(groups, destination.id)

        applied(operation,
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: amount,
          source_outstanding_deposit_cents: Reservations.outstanding_deposit(source),
          destination_outstanding_deposit_cents: Reservations.outstanding_deposit(destination),
          source_revision: source.revision,
          destination_revision: destination.revision
        )
    end
  end

  defp settle_cancellation(operation, group, rooms, occurred_on, result_kind) do
    refund_method = Map.get(operation, "refund_method", "cash")
    refundable = DepositPolicy.refundable?(group, occurred_on)

    cond do
      refund_method not in ~w(cash hotel_credit) ->
        halt_with_rejection(operation, "invalid_operation", group_id: group.group_id)

      not refundable and refund_method == "hotel_credit" ->
        halt_with_rejection(operation, "refund_method_not_available", group_id: group.group_id)

      refundable ->
        settle_refundable_cancellation(
          operation,
          group,
          rooms,
          occurred_on,
          refund_method,
          result_kind
        )

      true ->
        settle_nonrefundable_cancellation(operation, group, rooms, result_kind)
    end
  end

  defp settle_refundable_cancellation(
         operation,
         group,
         rooms,
         occurred_on,
         refund_method,
         result_kind
       ) do
    disposition = if refund_method == "cash", do: :refunded, else: :converted
    cash = Payments.settle_rooms!(rooms, disposition)
    Credits.restore_room_allocations(rooms, occurred_on)

    {refunded, converted, credit_issued} =
      case refund_method do
        "cash" ->
          {cash.amount_cents, 0, 0}

        "hotel_credit" ->
          credit =
            Credits.issue_from_cash(
              group,
              operation["operation_id"],
              occurred_on,
              cash.amount_cents,
              cash.contributors
            )

          {0, cash.amount_cents, credit}
      end

    group = RoomAccounting.mark_cancelled!(group, rooms)

    group =
      update_group!(group, %{
        refunded_cents: group.refunded_cents + refunded,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
        revision: group.revision + 1
      })

    cancellation_applied(operation, group, rooms, refunded, 0, credit_issued, result_kind)
  end

  defp settle_nonrefundable_cancellation(operation, group, rooms, result_kind) do
    cash = Payments.settle_rooms!(rooms, :retained)
    Credits.consume_room_allocations(rooms)
    group = RoomAccounting.mark_cancelled!(group, rooms)

    group =
      update_group!(group, %{
        retained_cents: group.retained_cents + cash.amount_cents,
        revision: group.revision + 1
      })

    cancellation_applied(operation, group, rooms, 0, cash.amount_cents, 0, result_kind)
  end

  defp cancellation_applied(
         operation,
         group,
         rooms,
         refunded,
         retained,
         credit_issued,
         result_kind
       ) do
    fields =
      [
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: credit_issued,
        revision: group.revision
      ]

    fields =
      if result_kind == :rooms do
        Keyword.put(fields, :cancelled_room_ids, Enum.map(rooms, & &1.room_id))
      else
        fields
      end

    applied(operation, fields)
  end

  defp mutate_payment(operation, type) do
    with :ok <- require_identifiers(operation, ~w(operation_id payment_operation_id)),
         :ok <- require_fields(operation, required_fields(type)) do
      payment_operation_id = operation["payment_operation_id"]

      case Payments.operation_payment(payment_operation_id) do
        {:error, :operation_not_found} ->
          halt_with_rejection(operation, "operation_not_found",
            payment_operation_id: payment_operation_id
          )

        {:error, :not_payment} ->
          code =
            if type == "reduce_cash_payment",
              do: "payment_not_reducible",
              else: "payment_not_chargeable"

          halt_with_rejection(operation, code, payment_operation_id: payment_operation_id)

        {:ok, payment} ->
          with :ok <- check_revision(operation, payment.group) do
            case parse_date(operation["occurred_on"]) do
              {:ok, _occurred_on} ->
                apply_payment_operation(type, operation, payment)

              :error ->
                halt_with_rejection(operation, "invalid_operation",
                  payment_operation_id: payment.payment_operation_id,
                  group_id: payment.group.group_id
                )
            end
          end
      end
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp apply_payment_operation("reduce_cash_payment", operation, payment) do
    amount = operation["amount_cents"]

    cond do
      payment.held_cents == 0 ->
        halt_with_rejection(operation, "payment_not_reducible",
          payment_operation_id: payment.payment_operation_id,
          group_id: payment.group.group_id
        )

      not (is_integer(amount) and amount > 0) ->
        halt_with_rejection(operation, "invalid_amount",
          payment_operation_id: payment.payment_operation_id,
          group_id: payment.group.group_id
        )

      amount > payment.held_cents ->
        halt_with_rejection(operation, "reduction_exceeds_held_cash",
          payment_operation_id: payment.payment_operation_id,
          group_id: payment.group.group_id
        )

      true ->
        {_payment, changed_groups} = Payments.reduce!(payment, amount)
        groups = increment_revisions!(changed_groups, payment.group)
        group = Map.fetch!(groups, payment.group.id)

        applied(operation,
          payment_operation_id: payment.payment_operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Reservations.outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp apply_payment_operation("charge_back_payment", operation, payment) do
    if payment.charged_back_cents > 0 or payment.recorded_cents == payment.reduced_cents do
      halt_with_rejection(operation, "payment_not_chargeable",
        payment_operation_id: payment.payment_operation_id,
        group_id: payment.group.group_id
      )
    else
      Credits.revoke_payment_entitlements(payment)
      {_payment, changed_groups, charged_back} = Payments.charge_back!(payment)
      groups = increment_revisions!(changed_groups, payment.group)
      group = Map.fetch!(groups, payment.group.id)

      applied(operation,
        payment_operation_id: payment.payment_operation_id,
        group_id: group.group_id,
        charged_back_cents: charged_back,
        outstanding_deposit_cents: Reservations.outstanding_deposit(group),
        revision: group.revision
      )
    end
  end

  defp check_revision(operation, group, field \\ "expected_revision") do
    case Map.fetch(operation, field) do
      :error ->
        :ok

      {:ok, expected} when expected === group.revision ->
        :ok

      {:ok, expected} ->
        halt_with_rejection(operation, "stale_revision",
          group_id: group.group_id,
          expected_revision: expected,
          actual_revision: group.revision
        )
    end
  end

  defp increment_revisions!(changed_groups, addressed_group) do
    [addressed_group | changed_groups]
    |> Enum.uniq_by(& &1.id)
    |> Map.new(fn group ->
      group = Repo.get!(Group, group.id)
      group = update_group!(group, %{revision: group.revision + 1})
      {group.id, group}
    end)
  end

  defp validate_stay(arrival_on, departure_on, operation) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      halt_with_rejection(operation, "invalid_stay", group_id: operation["group_id"])
    end
  end

  defp validate_rate_plan(operation) do
    if operation["rate_plan"] in @rate_plans do
      :ok
    else
      halt_with_rejection(operation, "invalid_rate_plan", group_id: operation["group_id"])
    end
  end

  defp validate_rooms(%{"rooms" => rooms} = operation) when is_list(rooms) and rooms != [] do
    normalized =
      Enum.with_index(rooms)
      |> Enum.reduce_while([], fn
        {%{"room_id" => room_id, "nightly_rate_cents" => rate}, position}, acc
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          {:cont, [%{room_id: room_id, nightly_rate_cents: rate, position: position} | acc]}

        _, _acc ->
          {:halt, :invalid}
      end)

    case normalized do
      :invalid ->
        halt_with_rejection(operation, "invalid_rooms", group_id: operation["group_id"])

      rooms ->
        rooms = Enum.reverse(rooms)

        if Enum.uniq_by(rooms, & &1.room_id) == rooms do
          {:ok, rooms}
        else
          halt_with_rejection(operation, "invalid_rooms", group_id: operation["group_id"])
        end
    end
  end

  defp validate_rooms(operation) do
    halt_with_rejection(operation, "invalid_rooms", group_id: operation["group_id"])
  end

  defp deposit_due(rooms, nights, "advance_purchase") do
    lodging_total(rooms, nights)
  end

  defp deposit_due(rooms, nights, "flexible") do
    Enum.reduce(rooms, 0, fn room, total ->
      room_lodging = room.nightly_rate_cents * nights
      total + rounded_percentage(room_lodging, 20)
    end)
  end

  defp lodging_total(rooms, nights) do
    Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * nights + &2))
  end

  # Adding half the denominator before integer division implements nearest-cent
  # rounding with exact half cents rounded upward.
  defp rounded_percentage(cents, percentage) do
    div(cents * percentage + 50, 100)
  end

  defp insert_rooms!(group, rooms, nights, rate_plan) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(rooms, fn room ->
        room
        |> Map.put(:status, "active")
        |> Map.put(:lodging_total_cents, room.nightly_rate_cents * nights)
        |> Map.put(:deposit_due_cents, room_deposit_due(room, nights, rate_plan))
        |> Map.put(:cash_paid_cents, 0)
        |> Map.put(:credit_paid_cents, 0)
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:group_record_id, group.id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _} = Repo.insert_all(Room, entries)

    if count != length(entries), do: raise("not all rooms were persisted")
  end

  defp update_group!(group, attrs) do
    group
    |> Group.accounting_changeset(attrs)
    |> Repo.update!()
  end

  defp required_date(operation, field, error_code) do
    case parse_date(operation[field]) do
      {:ok, date} ->
        {:ok, date}

      :error ->
        halt_with_rejection(operation, error_code, group_id: operation["group_id"])
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp require_identifiers(operation, fields) do
    if Enum.all?(fields, fn field ->
         case operation[field] do
           value when is_binary(value) -> String.trim(value) != ""
           _ -> false
         end
       end) do
      :ok
    else
      :error
    end
  end

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)), do: :ok, else: :error
  end

  defp required_fields("record_cash_payment"), do: ~w(occurred_on amount_cents)
  defp required_fields("apply_hotel_credit"), do: ~w(occurred_on amount_cents)
  defp required_fields("reschedule_group"), do: ~w(occurred_on new_arrival_on)
  defp required_fields("cancel_group"), do: ~w(occurred_on)
  defp required_fields("cancel_rooms"), do: ~w(occurred_on room_ids)
  defp required_fields("reduce_cash_payment"), do: ~w(occurred_on amount_cents)
  defp required_fields("charge_back_payment"), do: ~w(occurred_on)

  defp room_deposit_due(room, nights, "advance_purchase"),
    do: room.nightly_rate_cents * nights

  defp room_deposit_due(room, nights, "flexible"),
    do: rounded_percentage(room.nightly_rate_cents * nights, 20)

  defp transact(fun) do
    {:ok, result} = Repo.transaction(fun, mode: :immediate)
    result
  end

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation["operation_id"], status: "applied"})
  end

  defp reject(operation, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{
      operation_id: operation_id(operation),
      status: "rejected",
      code: code
    })
  end

  defp halt_with_rejection(operation, code, fields) do
    throw({:handled_rejection, reject(operation, code, fields)})
  end

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_operation), do: nil

  defp durable_operation_id(%{"operation_id" => operation_id})
       when is_binary(operation_id) do
    if String.trim(operation_id) == "", do: :error, else: {:ok, operation_id}
  end

  defp durable_operation_id(_operation), do: :error

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  # Persist and return the same JSON-shaped value so first responses, retries,
  # and operation reads cannot differ because of Elixir key or date types.
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
