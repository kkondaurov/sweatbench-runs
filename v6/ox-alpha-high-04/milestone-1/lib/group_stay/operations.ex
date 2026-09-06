defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations to groups, returning one result map per
  operation suitable for the partner batch endpoint.

  Every applied operation runs inside its own database transaction. A
  rejection leaves the database exactly as it was before that operation
  began, and processing continues with the next operation.
  """

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Room
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @rate_plans Group.rate_plans()
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
    expected_revision: @revision_not_used
  ]

  @doc """
  Applies a single raw operation and renders its result map.
  """
  def apply(raw_op) do
    operation_id = raw_identifier(raw_op)

    case parse(raw_op) do
      {:ok, cmd} ->
        cmd = %{cmd | operation_id: operation_id}
        execute(cmd)

      {:error, code} ->
        rejected(operation_id, code)
    end
  end

  defp raw_identifier(op) when is_map(op), do: Map.get(op, "operation_id")
  defp raw_identifier(_), do: nil

  ## Execution

  defp execute(cmd) do
    Repo.transaction(fn ->
      outcome =
        case cmd.type do
          "open_group" -> open_group(cmd)
          _ -> apply_to_group(cmd)
        end

      case outcome do
        {:ok, attrs} -> attrs
        {:error, {code, extra}} -> Repo.rollback({code, extra})
      end
    end)
    |> case do
      {:ok, attrs} -> applied(cmd.operation_id, attrs)
      {:error, {code, extra}} -> rejected(cmd.operation_id, code, decorate(code, cmd, extra))
    end
  end

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
        outstanding_after = outstanding_before(group) - amount

        updated = bump(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

        {:ok,
         %{
           "group_id" => cmd.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding_after,
           "revision" => updated.revision
         }}
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
           "revision" => updated.revision
         }}
    end
  end

  defp apply_domain(%{type: "cancel_group"} = cmd, group) do
    if group.status != "active" do
      {:error, {:group_not_active, %{}}}
    else
      refundable? =
        group.rate_plan == "flexible" and
          GroupStay.flexible_refundable?(cmd.occurred_on, group.arrival_on)

      paid = group.deposit_paid_cents
      {refunded, retained} = if refundable?, do: {paid, 0}, else: {0, paid}

      record_settlement(cmd, group, refunded, retained)
      updated = bump(group, %{status: "cancelled"})

      {:ok,
       %{
         "group_id" => cmd.group_id,
         "refunded_cents" => refunded,
         "retained_cents" => retained,
         "revision" => updated.revision
       }}
    end
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
    with {:ok, group_id} <- required_string(op, "group_id") do
      {:ok,
       %__MODULE__{
         type: "cancel_group",
         occurred_on: occurred_on,
         group_id: group_id,
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

  defp bump(group, changes) do
    group
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.change(revision: group.revision + 1)
    |> Repo.update!()
  end
end
