defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations one at a time, in order, and makes every
  operation durably idempotent on its `operation_id`.

  Each operation runs inside its own database transaction. The first operation
  received for an identifier is processed normally and its complete result is
  stored in an operation record that commits in the same transaction as the
  domain changes. A later operation with the same identifier and an equivalent
  payload returns the stored result verbatim, without reading or changing
  current domain state; a different payload is rejected with
  `operation_id_conflict` and does not replace the stored record.

  A handled rejection leaves domain state unchanged (its writes are undone
  through a savepoint inside the operation's transaction) but still commits
  its operation record, so a retry receives the original rejection even if the
  operation would now be valid. Operations without a usable identifier cannot
  be recorded and are processed as before.

  An unexpected exception rolls back the whole operation transaction, is not
  remembered, and propagates so the HTTP layer can abort the batch with `500`;
  the caller may retry the batch, replaying the already committed operations.

  Result values are plain maps rendered directly to the partner:

      %{"operation_id" => "...", "status" => "applied" | "rejected", ...fields}

  Ordering rules shared by every operation addressed to an existing group:

    1. group existence is resolved first (`group_not_found`);
    2. a stale `expected_revision` is rejected before any other domain rule;
    3. only then are the operation's own domain rules evaluated.

  Operations that address a group through a payment identifier
  (`reduce_cash_payment`, `charge_back_payment`) resolve the durable operation
  record and its payment first, then follow the same ordering for the derived
  group. `transfer_deposit` resolves the source group's existence, then the
  destination's, then checks the source revision and the destination revision
  (through `destination_expected_revision`) before its own transfer rules.

  An applied operation increments the revision of every group whose state it
  changes, and always the group it is addressed to; a reduction or chargeback
  whose payment holds funding in several groups (after a deposit transfer)
  advances each of them, even though only the addressed group is guarded by
  the request's `expected_revision`.
  """

  alias GroupStay.Accounting
  alias GroupStay.Credit
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  import Ecto.Query, only: [order_by: 2]

  @known_types [
    "open_group",
    "record_cash_payment",
    "reschedule_group",
    "cancel_group",
    "apply_hotel_credit",
    "cancel_rooms",
    "reduce_cash_payment",
    "charge_back_payment",
    "transfer_deposit"
  ]

  @refund_methods ["cash", "hotel_credit"]

  @savepoint "gs_operation"

  @doc """
  Applies a single operation and returns its complete partner-facing result
  map (`status` is `"applied"` or `"rejected"`). Unexpected faults are raised
  so the HTTP layer can abort the batch with `500`.
  """
  def apply(op) when is_map(op) do
    case record_key(Map.get(op, "operation_id")) do
      nil -> apply_unrecorded(op)
      operation_key -> apply_recorded(op, operation_key)
    end
  end

  def apply(_op) do
    result(nil, "rejected", %{"code" => "invalid_operation"})
  end

  @doc """
  The stored result for `operation_id`, or `nil` when no operation was
  recorded under it. Only the stored result is exposed, never the retained
  submission or the commit order.
  """
  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_key: record_key(operation_id)) do
      nil -> nil
      record -> Jason.decode!(record.result)
    end
  end

  @doc """
  All operation records in the order in which they were first committed.
  """
  def records do
    order_by(Record, asc: :id)
    |> Repo.all()
  end

  @doc """
  The reconciliation statement for one durably recorded, applied cash
  payment. Returns `{:error, :not_found}` when no durable operation record
  exists for the identifier and `{:error, :not_reconcilable}` when the record
  is not an applied cash payment. Reading a statement never changes state.
  """
  def payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    operation_key = record_key(payment_operation_id)

    case Repo.get_by(Record, operation_key: operation_key) do
      nil ->
        {:error, :not_found}

      %Record{type: "record_cash_payment", status: "applied"} ->
        case Ledger.payment_entry_by_operation_key(operation_key) do
          nil -> {:error, :not_found}
          entry -> {:ok, payment_statement(payment_operation_id, entry)}
        end

      %Record{} ->
        {:error, :not_reconcilable}
    end
  end

  defp payment_statement(payment_operation_id, entry) do
    group = Repo.get!(Group, entry.group_id)

    statement = %{
      "payment_operation_id" => payment_operation_id,
      "original_group_id" => group.group_id,
      "recorded_cents" => entry.amount_cents,
      "held_cents" => Accounting.payment_held_cents(entry.id),
      "refunded_cents" => Ledger.disposition_cents(entry.id, "refund"),
      "retained_cents" => Ledger.disposition_cents(entry.id, "retention"),
      "converted_to_credit_cents" =>
        Ledger.disposition_cents(entry.id, "cash_converted_to_credit"),
      "reduced_cents" => Ledger.disposition_cents(entry.id, "cash_reduction"),
      "charged_back_cents" => Ledger.disposition_cents(entry.id, "cash_chargeback")
    }

    # Once any funding from the payment has participated in a transfer, its
    # statement always reports where its cash is held, even after none
    # remains. Payments that never participated keep the earlier shape.
    if entry.participated_in_transfer do
      Map.put(statement, "held_by_group", Accounting.payment_held_by_group(entry.id))
    else
      statement
    end
  end

  ## Idempotency

  # The record key is the JSON encoding of the identifier, so distinct
  # identifier values (for example the string "42" and the number 42) never
  # collide and lookups by the string from the URL find the same record.
  defp record_key(operation_id)
       when is_binary(operation_id) or is_number(operation_id) or is_boolean(operation_id),
       do: Jason.encode!(operation_id)

  defp record_key(_operation_id), do: nil

  defp apply_recorded(op, operation_key) do
    payload = canonical_json(op)

    Repo.transaction(fn ->
      case Repo.get_by(Record, operation_key: operation_key) do
        %Record{payload: stored_payload, result: stored_result} ->
          if stored_payload == payload do
            # An exact retry replays the original result verbatim, without
            # reading or changing current domain state.
            {:replay, Jason.decode!(stored_result)}
          else
            Repo.rollback(:operation_id_conflict)
          end

        nil ->
          savepoint!()

          result =
            case run_operation(op) do
              {:ok, fields} ->
                release_savepoint!()
                result(op, "applied", fields)

              {:error, fields} ->
                # A handled rejection keeps domain state unchanged but its
                # record still commits with the transaction.
                rollback_savepoint!()
                result(op, "rejected", fields)
            end

          store_record!(operation_key, op, payload, result)
          result
      end
    end)
    |> case do
      {:ok, {:replay, result}} ->
        result

      {:ok, result} ->
        result

      {:error, :operation_id_conflict} ->
        result(Map.get(op, "operation_id"), "rejected", conflict_fields())
    end
  end

  defp conflict_fields, do: %{"code" => "operation_id_conflict"}

  defp apply_unrecorded(op) do
    Repo.transaction(fn ->
      case run_operation(op) do
        {:ok, fields} -> {:ok, result(op, "applied", fields)}
        {:error, fields} -> Repo.rollback(result(op, "rejected", fields))
      end
    end)
    |> case do
      {:ok, {:ok, result}} -> result
      {:error, result} -> result
    end
  end

  defp store_record!(operation_key, op, payload, result) do
    %Record{}
    |> Record.changeset(%{
      operation_key: operation_key,
      type: operation_type(op),
      payload: payload,
      status: result["status"],
      result: Jason.encode!(result)
    })
    |> Repo.insert!()
  end

  defp operation_type(op) do
    case Map.get(op, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp result(op_or_id, status, fields) when is_map(op_or_id),
    do: result(Map.get(op_or_id, "operation_id"), status, fields)

  defp result(operation_id, status, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => status}, fields)

  ## Savepoints

  defp savepoint!, do: execute_sql!("SAVEPOINT " <> @savepoint)
  defp release_savepoint!, do: execute_sql!("RELEASE SAVEPOINT " <> @savepoint)

  defp rollback_savepoint! do
    execute_sql!("ROLLBACK TO SAVEPOINT " <> @savepoint)
    release_savepoint!()
  end

  defp execute_sql!(sql) do
    case Ecto.Adapters.SQL.query(Repo, sql, []) do
      {:ok, _result} -> :ok
      {:error, exception} -> raise exception
    end
  end

  ## Canonical payload

  # A canonical JSON encoding: object keys are sorted (key order is not
  # significant), array order and every value is preserved as submitted.
  defp canonical_json(value) when is_map(value) do
    "{" <>
      Enum.map_join(
        Enum.sort_by(value, fn {key, _} -> to_string(key) end),
        ",",
        fn {key, nested} -> Jason.encode!(to_string(key)) <> ":" <> canonical_json(nested) end
      ) <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  ## Operations

  defp run_operation(%{"type" => type} = op) when type in @known_types do
    with {:ok, occurred_on} <- common_fields(op) do
      run_typed(type, op, occurred_on)
    end
  end

  defp run_operation(_op) do
    {:error, %{"code" => "invalid_operation"}}
  end

  defp run_typed("open_group", op, occurred_on), do: open_group(op, occurred_on)
  defp run_typed("record_cash_payment", op, occurred_on), do: record_cash_payment(op, occurred_on)
  defp run_typed("reschedule_group", op, occurred_on), do: reschedule_group(op, occurred_on)
  defp run_typed("cancel_group", op, occurred_on), do: cancel_group(op, occurred_on)
  defp run_typed("apply_hotel_credit", op, occurred_on), do: apply_hotel_credit(op, occurred_on)
  defp run_typed("cancel_rooms", op, occurred_on), do: cancel_rooms(op, occurred_on)
  defp run_typed("reduce_cash_payment", op, occurred_on), do: reduce_cash_payment(op, occurred_on)
  defp run_typed("charge_back_payment", op, occurred_on), do: charge_back_payment(op, occurred_on)
  defp run_typed("transfer_deposit", op, occurred_on), do: transfer_deposit(op, occurred_on)

  ## open_group

  defp open_group(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, guest_id} <- fetch_id(op, "guest_id"),
         {:ok, property_id} <- fetch_id(op, "property_id"),
         :ok <- check_group_absent(group_id),
         {:ok, rate_plan} <- fetch_rate_plan(op),
         {:ok, arrival_on} <- fetch_date(op, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- fetch_date(op, "departure_on", "invalid_stay"),
         :ok <- check_stay(arrival_on, departure_on),
         {:ok, rooms} <- fetch_rooms(op) do
      group =
        Repo.insert!(%Group{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          arrival_on: arrival_on,
          departure_on: departure_on,
          booked_on: occurred_on,
          rate_plan: rate_plan,
          policy_version: Groups.policy_version(rate_plan, occurred_on),
          status: "active",
          revision: 1,
          rooms: rooms
        })

      deposit_due = Groups.deposit_due_cents(%{group | rooms: rooms})

      {:ok,
       %{
         "group_id" => group_id,
         "deposit_due_cents" => deposit_due,
         "revision" => group.revision
       }}
    end
  end

  defp check_group_absent(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      {:error, %{"code" => "group_already_exists"}}
    else
      :ok
    end
  end

  defp fetch_rate_plan(op) do
    case op["rate_plan"] do
      rate_plan when rate_plan in ["flexible", "advance_purchase"] -> {:ok, rate_plan}
      _ -> {:error, %{"code" => "invalid_rate_plan"}}
    end
  end

  defp check_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, %{"code" => "invalid_stay"}}
    end
  end

  defp fetch_rooms(op) do
    rooms = op["rooms"]

    cond do
      not is_list(rooms) or rooms == [] ->
        {:error, %{"code" => "invalid_rooms"}}

      true ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, acc} ->
          case parse_room(room, position) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, parsed} -> check_unique_room_ids(Enum.reverse(parsed))
          {:error, _} = error -> error
        end
    end
  end

  defp parse_room(room, position) do
    case room do
      %{"room_id" => room_id, "nightly_rate_cents" => rate}
      when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
        {:ok,
         %GroupStay.Groups.Room{
           room_id: room_id,
           nightly_rate_cents: rate,
           position: position,
           status: "active"
         }}

      _ ->
        {:error, %{"code" => "invalid_rooms"}}
    end
  end

  defp check_unique_room_ids(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)

    if length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok, rooms}
    else
      {:error, %{"code" => "invalid_rooms"}}
    end
  end

  ## record_cash_payment

  defp record_cash_payment(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group),
         {:ok, amount_cents} <- fetch_amount(op) do
      outstanding = Groups.outstanding_deposit_cents(group)

      if amount_cents > outstanding do
        {:error, %{"code" => "payment_exceeds_outstanding"}}
      else
        entry =
          Ledger.record_payment!(
            group.id,
            amount_cents,
            occurred_on,
            record_key(op["operation_id"])
          )

        Accounting.allocate_cash!(group, entry, amount_cents)
        revision = bump_revision!(group)

        {:ok,
         %{
           "group_id" => group_id,
           "amount_cents" => amount_cents,
           "outstanding_deposit_cents" => outstanding - amount_cents,
           "revision" => revision
         }}
      end
    end
  end

  defp fetch_amount(op) do
    case op["amount_cents"] do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, %{"code" => "invalid_amount"}}
    end
  end

  ## reschedule_group

  defp reschedule_group(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group),
         {:ok, new_arrival_on} <- fetch_date(op, "new_arrival_on", "invalid_stay"),
         :ok <- check_after(new_arrival_on, occurred_on) do
      nights = Groups.nights(group)
      new_departure_on = Date.add(new_arrival_on, nights)

      moved =
        group
        |> Ecto.Changeset.change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on
        )
        |> Repo.update!()

      revision = bump_revision!(moved)

      {:ok,
       %{
         "group_id" => group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "policy_version" => moved.policy_version,
         "refundable_until" => render_date(Groups.refundable_until(moved)),
         "revision" => revision
       }}
    end
  end

  defp check_after(date, reference_date) do
    if Date.compare(date, reference_date) == :gt do
      :ok
    else
      {:error, %{"code" => "invalid_stay"}}
    end
  end

  ## cancel_group

  defp cancel_group(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group),
         {:ok, refund_method} <- fetch_refund_method(op) do
      refundable = Groups.refundable?(group, occurred_on)

      if not refundable and refund_method == "hotel_credit" do
        # Hotel credit is not a way around a non-refundable policy.
        {:error, %{"code" => "refund_method_not_available"}}
      else
        # Only the remaining active rooms are settled; rooms cancelled by an
        # earlier cancel_rooms operation were settled at that time.
        settlement =
          Accounting.settle_rooms!(
            group,
            Accounting.active_rooms(group),
            refundable,
            refund_method,
            op["operation_id"],
            occurred_on
          )

        group
        |> Ecto.Changeset.change(status: "cancelled")
        |> Repo.update!()

        revision = bump_revision!(group)

        {:ok,
         %{
           "group_id" => group_id,
           "refunded_cents" => settlement.refunded_cents,
           "retained_cents" => settlement.retained_cents,
           "credit_issued_cents" => settlement.credit_issued_cents,
           "revision" => revision
         }}
      end
    end
  end

  ## cancel_rooms

  defp cancel_rooms(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group),
         {:ok, rooms} <- fetch_selected_rooms(op, group),
         {:ok, refund_method} <- fetch_refund_method(op) do
      refundable = Groups.refundable?(group, occurred_on)

      if not refundable and refund_method == "hotel_credit" do
        # Hotel credit is not a way around a non-refundable policy.
        {:error, %{"code" => "refund_method_not_available"}}
      else
        settlement =
          Accounting.settle_rooms!(
            group,
            rooms,
            refundable,
            refund_method,
            op["operation_id"],
            occurred_on
          )

        group =
          if length(group.rooms) == length(rooms) do
            # No active rooms remain: the group becomes cancelled.
            group
            |> Ecto.Changeset.change(status: "cancelled")
            |> Repo.update!()
          else
            group
          end

        revision = bump_revision!(group)

        {:ok,
         %{
           "group_id" => group_id,
           "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
           "refunded_cents" => settlement.refunded_cents,
           "retained_cents" => settlement.retained_cents,
           "credit_issued_cents" => settlement.credit_issued_cents,
           "revision" => revision
         }}
      end
    end
  end

  # All supplied room identifiers must identify distinct, active rooms in the
  # group; the selected rooms are returned in the group's original order.
  defp fetch_selected_rooms(op, group) do
    case op["room_ids"] do
      room_ids when is_list(room_ids) and room_ids != [] ->
        active_ids =
          group
          |> Accounting.active_rooms()
          |> MapSet.new(& &1.room_id)

        selected_ids = MapSet.new(room_ids)

        if Enum.all?(room_ids, &is_binary/1) and
             length(room_ids) == length(Enum.uniq(room_ids)) and
             MapSet.subset?(selected_ids, active_ids) do
          {:ok, Enum.filter(group.rooms, &MapSet.member?(selected_ids, &1.room_id))}
        else
          {:error, %{"code" => "invalid_rooms"}}
        end

      _ ->
        {:error, %{"code" => "invalid_rooms"}}
    end
  end

  ## reduce_cash_payment

  defp reduce_cash_payment(op, occurred_on) do
    with {:ok, payment_operation_id} <- fetch_id(op, "payment_operation_id"),
         {:ok, target} <- fetch_payment_target(payment_operation_id, "payment_not_reducible"),
         :ok <- check_revision(op, target.group),
         {:ok, amount_cents} <- fetch_amount(op),
         :ok <- check_reducible(target, amount_cents) do
      affected_groups = Accounting.reduce_payment!(target.entry, amount_cents, occurred_on)

      revision = bump_revision!(target.group)
      bump_other_revisions!(affected_groups, target.group.id)

      group = Groups.get_group(target.group.group_id)

      {:ok,
       %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
         "revision" => revision
       }}
    end
  end

  # Only cash from the payment that is still held on active rooms can be
  # reduced; refunded, retained, and converted cash is settled history.
  defp check_reducible(target, amount_cents) do
    held_cents = Accounting.payment_held_cents(target.entry.id)

    cond do
      held_cents == 0 ->
        {:error, %{"code" => "payment_not_reducible"}}

      amount_cents > held_cents ->
        {:error, %{"code" => "reduction_exceeds_held_cash"}}

      true ->
        :ok
    end
  end

  ## charge_back_payment

  defp charge_back_payment(op, occurred_on) do
    with {:ok, payment_operation_id} <- fetch_id(op, "payment_operation_id"),
         {:ok, target} <- fetch_payment_target(payment_operation_id, "payment_not_chargeable"),
         :ok <- check_revision(op, target.group),
         :ok <- check_chargeable(target) do
      {charged_back_cents, affected_groups} =
        Accounting.charge_back_payment!(target.entry, occurred_on)

      revision = bump_revision!(target.group)
      bump_other_revisions!(affected_groups, target.group.id)

      group = Groups.get_group(target.group.group_id)

      {:ok,
       %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => charged_back_cents,
         "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
         "revision" => revision
       }}
    end
  end

  defp check_chargeable(target) do
    cond do
      Ledger.disposition_cents(target.entry.id, "cash_chargeback") > 0 ->
        # Already charged back.
        {:error, %{"code" => "payment_not_chargeable"}}

      Ledger.disposition_cents(target.entry.id, "cash_reduction") >= target.entry.amount_cents ->
        # Fully reduced: there is no cash left to reverse.
        {:error, %{"code" => "payment_not_chargeable"}}

      true ->
        :ok
    end
  end

  # Resolves a payment identifier to its durable record, ledger entry, and
  # group. A record that can never address an applied cash payment (a
  # non-payment operation or a rejected payment) fails with the caller's
  # failure code, since no group can be derived for revision checking.
  defp fetch_payment_target(payment_operation_id, failure_code) do
    operation_key = record_key(payment_operation_id)

    case Repo.get_by(Record, operation_key: operation_key) do
      nil ->
        {:error, %{"code" => "operation_not_found"}}

      %Record{type: "record_cash_payment", status: "applied"} ->
        case Ledger.payment_entry_by_operation_key(operation_key) do
          nil ->
            {:error, %{"code" => failure_code}}

          entry ->
            group =
              Repo.get!(Group, entry.group_id)
              |> Groups.preload_rooms()

            {:ok, %{entry: entry, group: group}}
        end

      %Record{} ->
        {:error, %{"code" => failure_code}}
    end
  end

  ## transfer_deposit

  defp transfer_deposit(op, _occurred_on) do
    with {:ok, source_group_id} <- fetch_id(op, "source_group_id"),
         {:ok, destination_group_id} <- fetch_id(op, "destination_group_id"),
         {:ok, source} <- fetch_transfer_group(source_group_id),
         {:ok, destination} <- fetch_transfer_group(destination_group_id),
         :ok <- check_revision(op, source),
         :ok <- check_revision(op, destination, "destination_expected_revision"),
         :ok <- check_transfer_pair(source, destination),
         :ok <- check_transfer_active(source),
         :ok <- check_transfer_active(destination),
         {:ok, amount_cents} <- fetch_amount(op),
         :ok <- check_held_funding(source, amount_cents),
         :ok <- check_destination_outstanding(destination, amount_cents) do
      Accounting.transfer_funding!(
        source,
        destination,
        amount_cents,
        record_key(op["operation_id"])
      )

      # The transfer changes both groups' funding, so both revisions advance.
      source = Groups.get_group(source_group_id)
      destination = Groups.get_group(destination_group_id)

      {:ok,
       %{
         "source_group_id" => source_group_id,
         "destination_group_id" => destination_group_id,
         "amount_cents" => amount_cents,
         "source_outstanding_deposit_cents" => Groups.outstanding_deposit_cents(source),
         "destination_outstanding_deposit_cents" => Groups.outstanding_deposit_cents(destination),
         "source_revision" => bump_revision!(source),
         "destination_revision" => bump_revision!(destination)
       }}
    end
  end

  # A transfer addresses both groups by identifier, so a missing group names
  # itself in the rejection.
  defp fetch_transfer_group(group_id) do
    case Groups.get_group(group_id) do
      nil -> {:error, %{"code" => "group_not_found", "group_id" => group_id}}
      group -> {:ok, group}
    end
  end

  # Both groups must be distinct and belong to the same guest.
  defp check_transfer_pair(%Group{} = source, %Group{} = destination) do
    if source.id == destination.id or source.guest_id != destination.guest_id do
      {:error, %{"code" => "invalid_transfer"}}
    else
      :ok
    end
  end

  defp check_transfer_active(%Group{status: "active"}), do: :ok

  defp check_transfer_active(%Group{} = group),
    do: {:error, %{"code" => "group_not_active", "group_id" => group.group_id}}

  # Held funding is cash and hotel credit currently allocated to active rooms.
  defp check_held_funding(%Group{} = source, amount_cents) do
    if Groups.deposit_paid_cents(source) >= amount_cents do
      :ok
    else
      {:error, %{"code" => "transfer_exceeds_held_funding"}}
    end
  end

  defp check_destination_outstanding(%Group{} = destination, amount_cents) do
    if Groups.outstanding_deposit_cents(destination) >= amount_cents do
      :ok
    else
      {:error, %{"code" => "transfer_exceeds_outstanding"}}
    end
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group),
         {:ok, amount_cents} <- fetch_amount(op),
         :ok <- check_credit_available(group, amount_cents, occurred_on),
         :ok <- check_credit_within_outstanding(group, amount_cents) do
      outstanding = Groups.outstanding_deposit_cents(group)

      applications =
        Credit.apply_to_group!(
          group.id,
          group.guest_id,
          amount_cents,
          occurred_on,
          record_key(op["operation_id"])
        )

      Accounting.allocate_credit!(group, applications)
      revision = bump_revision!(group)

      {:ok,
       %{
         "group_id" => group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding - amount_cents,
         "revision" => revision
       }}
    end
  end

  defp check_credit_available(group, amount_cents, occurred_on) do
    if Credit.available_cents(group.guest_id, occurred_on) >= amount_cents do
      :ok
    else
      {:error, %{"code" => "insufficient_credit"}}
    end
  end

  defp check_credit_within_outstanding(group, amount_cents) do
    if amount_cents > Groups.outstanding_deposit_cents(group) do
      {:error, %{"code" => "payment_exceeds_outstanding"}}
    else
      :ok
    end
  end

  ## shared helpers

  defp common_fields(op) do
    with :ok <- check_present(op, "operation_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on", "invalid_operation") do
      {:ok, occurred_on}
    end
  end

  defp check_present(op, key) do
    if Map.has_key?(op, key) and op[key] != nil do
      :ok
    else
      {:error, %{"code" => "invalid_operation"}}
    end
  end

  defp fetch_id(op, key) do
    case op[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, %{"code" => "invalid_operation"}}
    end
  end

  defp fetch_date(op, key, error_code) do
    case op[key] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, %{"code" => error_code}}
        end

      _ ->
        {:error, %{"code" => error_code}}
    end
  end

  defp fetch_group(group_id) do
    case Groups.get_group(group_id) do
      nil -> {:error, %{"code" => "group_not_found"}}
      group -> {:ok, group}
    end
  end

  defp fetch_refund_method(op) do
    case Map.get(op, "refund_method") do
      nil -> {:ok, "cash"}
      refund_method when refund_method in @refund_methods -> {:ok, refund_method}
      _ -> {:error, %{"code" => "refund_method_not_available"}}
    end
  end

  defp check_revision(op, %Group{} = group, key \\ "expected_revision") do
    case Map.get(op, key) do
      nil ->
        :ok

      expected_revision ->
        if expected_revision == group.revision do
          :ok
        else
          {:error,
           %{
             "code" => "stale_revision",
             "group_id" => group.group_id,
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok

  defp check_active(%Group{}), do: {:error, %{"code" => "group_not_active"}}

  defp bump_revision!(%Group{} = group) do
    next = group.revision + 1
    group |> Ecto.Changeset.change(revision: next) |> Repo.update!()
    next
  end

  # An applied operation increments the revision of every group whose state
  # it changes, not only the group it is addressed to (a reduction or
  # chargeback can remove held funding in groups that a deposit transfer
  # spread the payment across). The addressed group has already advanced.
  defp bump_other_revisions!(group_pks, addressed_group_pk) do
    group_pks
    |> Enum.uniq()
    |> Kernel.--([addressed_group_pk])
    |> Enum.each(fn group_pk ->
      Group
      |> Repo.get!(group_pk)
      |> bump_revision!()
    end)

    :ok
  end

  defp render_date(nil), do: nil
  defp render_date(%Date{} = date), do: Date.to_iso8601(date)
end
