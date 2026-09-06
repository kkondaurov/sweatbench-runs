defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations to groups, returning one result map per
  operation suitable for the partner batch endpoint.

  Every applied operation runs inside its own database transaction. A
  handled rejection leaves domain state unchanged but commits its durable
  idempotency record, and processing continues with the next operation.

  Operations are durably idempotent by `operation_id` since this release:
  an exact retry replays the stored result without reading or changing
  domain state, a different payload under the same identifier is rejected
  with `operation_id_conflict`, and both applied and rejected results are
  remembered in the same database transaction as their domain changes.
  Unexpected exceptions roll back everything for the current operation,
  are not remembered, and abort the HTTP request.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Room
  alias GroupStay.DurableOperations.OperationRecord
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @rate_plans Group.rate_plans()
  @refund_methods ~w(cash hotel_credit)
  @revision_not_used :revision_not_used

  defstruct [
    :type,
    :operation_id,
    :occurred_on,
    :group_id,
    :guest_id,
    :property_id,
    :arrival_on,
    :departure_on,
    :rate_plan,
    :rooms,
    :amount_cents,
    :new_arrival_on,
    :refund_method,
    expected_revision: @revision_not_used
  ]

  @doc """
  Applies a single raw operation and renders its result map, durably
  idempotent by `operation_id`.
  """
  def apply(raw_op) do
    # The lookup-or-insert of the durable record shares one database
    # transaction with the operation's domain changes, so retries that race
    # with the original commit see the committed record (SQLite serializes
    # writers) and effects land at most once.
    Repo.transaction(fn -> process(raw_op) end)
    |> case do
      {:ok, result} -> result
    end
  end

  defp process(raw_op) do
    operation_id = raw_identifier(raw_op)

    if recordable?(operation_id) do
      payload_json = canonical_json(raw_op)

      case record_for(operation_id) do
        %OperationRecord{} = record ->
          replay(record, payload_json, operation_id)

        nil ->
          {result, type} = execute(raw_op, operation_id)
          remember(operation_id, type, payload_json, result)
          result
      end
    else
      # Without a usable identifier there is nothing to be idempotent about;
      # behavior is unchanged from before this release.
      {result, _type} = execute(raw_op, operation_id)
      result
    end
  end

  defp recordable?(operation_id), do: is_binary(operation_id) and operation_id != ""

  defp raw_identifier(op) when is_map(op), do: Map.get(op, "operation_id")
  defp raw_identifier(_), do: nil

  # Canonical encoding of the complete submitted content: object keys are
  # sorted at every level, so object key order is not significant, while
  # array order and values remain significant.
  defp canonical_json(value)

  defp canonical_json(%{} = map) do
    pairs =
      Enum.map(map, fn {key, inner} -> {Jason.encode!(key), canonical_json(inner)} end)
      |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)

    "{" <> Enum.map_join(pairs, ",", fn {key, encoded} -> key <> ":" <> encoded end) <> "}"
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(other), do: Jason.encode!(other)

  defp record_for(operation_id) do
    Repo.one(from(r in OperationRecord, where: r.operation_id == ^operation_id))
  end

  # An equivalent retry returns the stored result verbatim — including any
  # revision or stale-revision details observed originally — without reading
  # or changing current domain state.
  defp replay(%{payload_json: stored_payload} = record, payload_json, operation_id) do
    if stored_payload == payload_json do
      Jason.decode!(record.result_json)
    else
      rejected(operation_id, :operation_id_conflict)
    end
  end

  # A handled rejection commits its own record too; an unexpected exception
  # propagates and rolls back both domain changes and any record for this
  # operation, leaving it to be processed afresh after a retry.
  defp remember(operation_id, type, payload_json, result) do
    %OperationRecord{}
    |> Ecto.Changeset.change(%{
      operation_id: operation_id,
      type: type,
      payload_json: payload_json,
      result_json: Jason.encode!(result)
    })
    |> Repo.insert!()

    :ok
  end

  ## Execution

  # Domain handlers validate before mutating, so a handled rejection returns
  # as an ordinary value — domain state is untouched and the durable record
  # commits in this same transaction. An unexpected exception (including any
  # write failure) propagates instead: the whole transaction rolls back, no
  # record is remembered, and the HTTP request aborts with 500.
  defp execute(raw_op, operation_id) do
    case parse(raw_op) do
      {:ok, cmd} ->
        cmd = %{cmd | operation_id: operation_id}

        outcome =
          case cmd.type do
            "open_group" -> open_group(cmd)
            _ -> apply_to_group(cmd)
          end

        case outcome do
          {:ok, attrs} ->
            {applied(cmd.operation_id, attrs), cmd.type}

          {:error, {code, extra}} ->
            {rejected(cmd.operation_id, code, decorate(code, cmd, extra)), cmd.type}
        end

      {:error, code} ->
        {rejected(operation_id, code), submitted_type(raw_op)}
    end
  end

  defp submitted_type(op) when is_map(op) do
    case Map.get(op, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp submitted_type(_op), do: nil

  # `stale_revision` rejections carry the group reference shown in the API
  # document; existence is always resolved first, so the group is known here.
  defp decorate(:stale_revision, cmd, extra), do: Map.put(extra, "group_id", cmd.group_id)
  defp decorate(_code, _cmd, extra), do: extra

  defp applied(operation_id, attrs) do
    %{"operation_id" => operation_id, "status" => "applied"}
    |> Map.merge(attrs)
  end

  defp rejected(operation_id, code, extra \\ %{}) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => to_string(code)}
    |> Map.merge(extra)
  end

  ## open_group

  defp open_group(cmd) do
    with {:available, false} <- {:available, group_exists?(cmd.group_id)},
         {:inserted, {:ok, group}} <- {:inserted, create_group(cmd)} do
      {:ok,
       %{
         "group_id" => group.group_id,
         "deposit_due_cents" => group.deposit_due_cents,
         "revision" => group.revision
       }}
    else
      {_tag, _other} -> {:error, {:group_already_exists, %{}}}
    end
  end

  defp group_exists?(group_id), do: is_map(Repo.get(Group, group_id))

  defp create_group(cmd) do
    nights = Date.diff(cmd.departure_on, cmd.arrival_on)

    {lodging_total, deposit_due} =
      Enum.reduce(cmd.rooms, {0, 0}, fn room, {lodging_acc, deposit_acc} ->
        room_lodging = room.nightly_rate_cents * nights

        deposit =
          if cmd.rate_plan == "flexible" do
            GroupStay.flexible_room_deposit(room_lodging)
          else
            GroupStay.advance_purchase_room_deposit(room_lodging)
          end

        {lodging_acc + room_lodging, deposit_acc + deposit}
      end)

    room_changesets =
      Enum.with_index(cmd.rooms, fn room, position ->
        %Room{}
        |> Ecto.Changeset.change(%{
          group_id: cmd.group_id,
          position: position,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents
        })
      end)

    %Group{}
    |> Ecto.Changeset.change(%{
      group_id: cmd.group_id,
      guest_id: cmd.guest_id,
      property_id: cmd.property_id,
      booked_on: cmd.occurred_on,
      arrival_on: cmd.arrival_on,
      departure_on: cmd.departure_on,
      rate_plan: cmd.rate_plan,
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    })
    |> Ecto.Changeset.put_assoc(:rooms, room_changesets)
    |> Repo.insert()
  end

  ## Operations addressed to an existing group
  #
  # Existence is resolved first, then a supplied expected_revision is compared
  # against the group's revision immediately before this operation, and only
  # then are the operation's domain rules evaluated. A rejection rolls back
  # the transaction without ever incrementing the revision.

  defp apply_to_group(cmd) do
    with {:ok, group} <- find_group(cmd.group_id),
         :current <- check_revision(group, cmd.expected_revision),
         {:ok, attrs} <- apply_domain(cmd, group) do
      {:ok, attrs}
    end
  end

  defp find_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, {:group_not_found, %{}}}
      group -> {:ok, group}
    end
  end

  defp check_revision(_group, @revision_not_used), do: :current

  defp check_revision(%Group{revision: actual}, expected) do
    if expected == actual do
      :current
    else
      {:error, {:stale_revision, %{"expected_revision" => expected, "actual_revision" => actual}}}
    end
  end

  defp apply_domain(%{type: "record_cash_payment", amount_cents: amount} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      outstanding_before(group) < amount ->
        {:error, {:payment_exceeds_outstanding, %{}}}

      true ->
        updated =
          bump(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })

        {:ok,
         %{
           "group_id" => cmd.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding_after(updated),
           "revision" => updated.revision
         }}
    end
  end

  defp apply_domain(%{type: "apply_hotel_credit", amount_cents: amount} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      outstanding_before(group) < amount ->
        {:error, {:payment_exceeds_outstanding, %{}}}

      true ->
        # Expiry of available credit is evaluated as of the operation's date.
        case GroupStay.apply_group_credit(group, cmd.occurred_on, cmd.operation_id, amount) do
          :ok ->
            # Applying credit redeems it into the active deposit: liability and
            # revision are the visible effects, so nothing else changes here.
            updated =
              bump(group, %{
                deposit_paid_cents: group.deposit_paid_cents + amount,
                credit_paid_cents: group.credit_paid_cents + amount
              })

            {:ok,
             %{
               "group_id" => cmd.group_id,
               "amount_cents" => amount,
               "outstanding_deposit_cents" => outstanding_after(updated),
               "revision" => updated.revision
             }}

          {:error, :insufficient_credit} ->
            {:error, {:insufficient_credit, %{}}}
        end
    end
  end

  defp apply_domain(%{type: "reschedule_group", new_arrival_on: new_arrival} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      Date.compare(new_arrival, cmd.occurred_on) != :gt ->
        {:error, {:invalid_stay, %{}}}

      true ->
        # The departure date shifts by the same number of days, so the length
        # and price of the stay do not change.
        shift = Date.diff(new_arrival, group.arrival_on)
        new_departure = Date.add(group.departure_on, shift)

        updated = bump(group, %{arrival_on: new_arrival, departure_on: new_departure})

        {:ok,
         %{
           "group_id" => cmd.group_id,
           "new_arrival_on" => Date.to_iso8601(new_arrival),
           "new_departure_on" => Date.to_iso8601(new_departure),
           # The policy version stays fixed at what the booking date implies,
           # while the refund window follows the moved arrival.
           "policy_version" => GroupStay.policy_version(group.rate_plan, group.booked_on),
           "refundable_until" =>
             GroupStay.refundable_until(group.rate_plan, group.booked_on, new_arrival),
           "revision" => updated.revision
         }}
    end
  end

  defp apply_domain(%{type: "cancel_group", refund_method: refund_method} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      not refundable?(group, cmd.occurred_on) and refund_method == "hotel_credit" ->
        # Hotel credit is not a way around a non-refundable policy; the group
        # stays active and the revision does not advance.
        {:error, {:refund_method_not_available, %{}}}

      true ->
        {:ok, settle(cmd, group)}
    end
  end

  # Refundability follows the policy version fixed by the group's booking
  # date, and cancellation on the refundable-until date itself is refundable.
  defp refundable?(group, occurred_on) do
    GroupStay.refundable?(group.rate_plan, group.booked_on, occurred_on, group.arrival_on)
  end

  defp settle(cmd, group) do
    refund_method = cmd.refund_method || "cash"
    cash = group.cash_paid_cents

    cond do
      refundable?(group, cmd.occurred_on) and refund_method == "hotel_credit" ->
        # Cash is neither refunded nor retained: it converts into a credit lot
        # worth the refunded cash plus its bonus, `source_operation_id` naming
        # this cancellation.
        issued =
          if cash > 0 do
            lot_amount =
              GroupStay.issue_hotel_credit(
                group.guest_id,
                cmd.operation_id,
                cash,
                cmd.occurred_on
              )

            GroupStay.record_ledger_entry(%{
              kind: "converted_to_credit",
              amount: cash,
              group_id: group.group_id,
              occurred_on: cmd.occurred_on
            })

            lot_amount
          else
            0
          end

        finalize(cmd, group, %{
          "refunded_cents" => 0,
          "retained_cents" => 0,
          "credit_issued_cents" => issued
        })

      refundable?(group, cmd.occurred_on) ->
        record_settlement(cmd, group, cash, 0)

        finalize(cmd, group, %{
          "refunded_cents" => cash,
          "retained_cents" => 0,
          "credit_issued_cents" => 0
        })

      true ->
        record_settlement(cmd, group, 0, cash)

        finalize(cmd, group, %{
          "refunded_cents" => 0,
          "retained_cents" => cash,
          "credit_issued_cents" => 0
        })
    end
  end

  defp finalize(cmd, group, result) do
    if refundable?(group, cmd.occurred_on) do
      # Applied hotel credit returns to its original lots with their original
      # expiry — restoring never grants a second bonus, and portions whose
      # expiry already passed expire immediately instead of becoming available.
      GroupStay.restore_group_credit(group, cmd.occurred_on)
    else
      # Applied hotel credit is consumed by a non-refundable cancellation.
      GroupStay.consume_group_credit(group.group_id)
    end

    updated = bump(group, %{status: "cancelled"})

    %{"group_id" => group.group_id}
    |> Map.merge(result)
    |> Map.put("revision", updated.revision)
  end

  defp record_settlement(_cmd, _group, 0, 0), do: :skipped

  defp record_settlement(cmd, group, refunded, retained) do
    GroupStay.record_ledger_entry(%{
      kind: if(refunded > 0, do: "refunded", else: "retained"),
      amount: max(refunded, retained),
      group_id: group.group_id,
      occurred_on: cmd.occurred_on
    })
  end

  ## Parsing
  #
  # Data needed to identify and apply an operation must be present and usable;
  # anything missing is `invalid_operation`. A value that is present but
  # violates a domain rule is rejected with that rule's stable code.

  defp parse(op) when is_map(op) do
    with {:ok, type} <- parse_type(op),
         {:ok, occurred_on} <- common_date(op, "occurred_on") do
      case type do
        "open_group" -> parse_open_group(op, occurred_on)
        "record_cash_payment" -> parse_record_cash_payment(op, occurred_on)
        "reschedule_group" -> parse_reschedule_group(op, occurred_on)
        "cancel_group" -> parse_cancel_group(op, occurred_on)
        "apply_hotel_credit" -> parse_apply_hotel_credit(op, occurred_on)
      end
    end
  end

  defp parse(_op), do: {:error, :invalid_operation}

  defp parse_type(%{"type" => type}) when type in @operation_types, do: {:ok, type}
  defp parse_type(_op), do: {:error, :invalid_operation}

  defp common_date(op, key) do
    case to_date(Map.get(op, key)) do
      %Date{} = date -> {:ok, date}
      _ -> {:error, :invalid_operation}
    end
  end

  defp to_date(%Date{} = date), do: date

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_date(_), do: nil

  defp required_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_operation}
    end
  end

  defp stay_date(op, key) do
    case Map.fetch(op, key) do
      :error ->
        {:error, :invalid_operation}

      {:ok, raw} when raw != nil ->
        case to_date(raw) do
          %Date{} = date -> {:ok, date}
          _ -> {:error, :invalid_stay}
        end

      {:ok, _nil} ->
        {:error, :invalid_operation}
    end
  end

  defp rate_plan(op) do
    case Map.fetch(op, "rate_plan") do
      {:ok, plan} when plan in @rate_plans -> {:ok, plan}
      {:ok, nil} -> {:error, :invalid_operation}
      {:ok, _other} -> {:error, :invalid_rate_plan}
      :error -> {:error, :invalid_operation}
    end
  end

  defp rooms(op) do
    case Map.fetch(op, "rooms") do
      :error ->
        {:error, :invalid_operation}

      {:ok, nil} ->
        {:error, :invalid_operation}

      {:ok, list} when is_list(list) and list != [] ->
        with {:ok, entries} <- room_entries(list) do
          if unique_room_ids?(entries), do: {:ok, entries}, else: {:error, :invalid_rooms}
        end

      {:ok, _other} ->
        {:error, :invalid_rooms}
    end
  end

  defp room_entries(list) do
    Enum.reduce_while(list, {:ok, []}, fn room, {:ok, acc} ->
      case room_entry(room) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp room_entry(room) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate = room["nightly_rate_cents"]

    cond do
      not valid_room_id?(room_id) ->
        {:error, :invalid_rooms}

      not (is_integer(nightly_rate) and nightly_rate > 0) ->
        {:error, :invalid_rate_plan}

      true ->
        {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate}}
    end
  end

  defp room_entry(_room), do: {:error, :invalid_rooms}

  defp valid_room_id?(id), do: is_binary(id) and id != ""

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == length(Enum.uniq(ids))
  end

  # open_group does not use expected_revision, so it is never parsed there.

  defp parse_open_group(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, guest_id} <- required_string(op, "guest_id"),
         {:ok, property_id} <- required_string(op, "property_id"),
         {:ok, arrival_on} <- stay_date(op, "arrival_on"),
         {:ok, departure_on} <- stay_date(op, "departure_on"),
         {:ok, rate_plan} <- rate_plan(op),
         {:ok, rooms} <- rooms(op),
         :ok <- check_stay_dates(arrival_on, departure_on) do
      {:ok,
       %__MODULE__{
         type: "open_group",
         occurred_on: occurred_on,
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    end
  end

  defp check_stay_dates(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp parse_record_cash_payment(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, amount_cents} <- payment_amount(op) do
      {:ok,
       %__MODULE__{
         type: "record_cash_payment",
         occurred_on: occurred_on,
         group_id: group_id,
         amount_cents: amount_cents,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp payment_amount(op) do
    case Map.fetch(op, "amount_cents") do
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, nil} -> {:error, :invalid_operation}
      {:ok, _other} -> {:error, :invalid_amount}
      :error -> {:error, :invalid_operation}
    end
  end

  defp parse_reschedule_group(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, new_arrival_on} <- stay_date(op, "new_arrival_on") do
      {:ok,
       %__MODULE__{
         type: "reschedule_group",
         occurred_on: occurred_on,
         group_id: group_id,
         new_arrival_on: new_arrival_on,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp parse_cancel_group(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, refund_method} <- refund_method(op) do
      {:ok,
       %__MODULE__{
         type: "cancel_group",
         occurred_on: occurred_on,
         group_id: group_id,
         # Omitting the method preserves the original cash-settlement behavior.
         refund_method: refund_method,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp refund_method(op) do
    case Map.get(op, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in @refund_methods -> {:ok, method}
      _other -> {:error, :invalid_operation}
    end
  end

  defp parse_apply_hotel_credit(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, amount_cents} <- payment_amount(op) do
      {:ok,
       %__MODULE__{
         type: "apply_hotel_credit",
         occurred_on: occurred_on,
         group_id: group_id,
         amount_cents: amount_cents,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp supplied_revision(op) do
    if Map.has_key?(op, "expected_revision"),
      do: Map.get(op, "expected_revision"),
      else: @revision_not_used
  end

  defp outstanding_before(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding_after(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp bump(group, changes) do
    group
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.change(revision: group.revision + 1)
    |> Repo.update!()
  end
end
