defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner batch operations in order.

  Each operation runs in its own transaction. A rejected operation is rolled back completely, so
  it leaves the database exactly as it found it, and processing continues with the next operation.
  """

  import Ecto.Query

  alias GroupStay.Deposits
  alias GroupStay.Groups.{Group, LedgerEntry, Room}
  alias GroupStay.Repo

  @refund_notice_days 14

  # Largest amount stored or reported. Keeps totals within SQLite integers and JSON-safe numbers.
  @max_cents 9_007_199_254_740_991

  @doc """
  Processes a list of raw (decoded JSON) operations and returns one result map per operation, in
  the same order.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Processes a single raw operation and returns its result map."
  def process_operation(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id")

    outcome =
      case parse(operation) do
        {:ok, command} -> execute(command)
        {:error, code} -> {:error, %{code: code}}
      end

    case outcome do
      {:ok, fields} ->
        Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

      {:error, fields} ->
        Map.merge(%{operation_id: operation_id, status: "rejected"}, fields)
    end
  end

  defp execute(command) do
    Repo.transaction(
      fn ->
        case apply_command(command) do
          {:ok, fields} -> fields
          {:error, fields} -> Repo.rollback(fields)
        end
      end,
      mode: :immediate
    )
  end

  ## Parsing
  #
  # Parsing only checks that the operation can be identified and carries the data it needs.
  # Domain rules (dates, rooms, amounts, rate plans) are evaluated when the command is applied.

  defp parse(%{} = op) do
    with {:ok, operation_id} <- required_identifier(op, "operation_id"),
         {:ok, type} <- required_identifier(op, "type"),
         {:ok, occurred_on} <- required_date(op, "occurred_on") do
      base = %{operation_id: operation_id, occurred_on: occurred_on}
      parse_type(type, op, base)
    end
  end

  defp parse(_operation), do: {:error, "invalid_operation"}

  defp parse_type("open_group", op, base) do
    with {:ok, group_id} <- required_identifier(op, "group_id"),
         {:ok, guest_id} <- required_identifier(op, "guest_id"),
         {:ok, property_id} <- required_identifier(op, "property_id"),
         {:ok, arrival_on} <- required_present(op, "arrival_on"),
         {:ok, departure_on} <- required_present(op, "departure_on"),
         {:ok, rate_plan} <- required_present(op, "rate_plan"),
         {:ok, rooms} <- required_present(op, "rooms") do
      {:ok,
       Map.merge(base, %{
         type: :open_group,
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       })}
    end
  end

  defp parse_type("record_cash_payment", op, base) do
    with {:ok, command} <- group_command(:record_cash_payment, op, base),
         {:ok, amount} <- required_present(op, "amount_cents") do
      {:ok, Map.put(command, :amount_cents, amount)}
    end
  end

  defp parse_type("reschedule_group", op, base) do
    with {:ok, command} <- group_command(:reschedule_group, op, base),
         {:ok, new_arrival_on} <- required_present(op, "new_arrival_on") do
      {:ok, Map.put(command, :new_arrival_on, new_arrival_on)}
    end
  end

  defp parse_type("cancel_group", op, base), do: group_command(:cancel_group, op, base)

  defp parse_type(_type, _op, _base), do: {:error, "invalid_operation"}

  defp group_command(type, op, base) do
    with {:ok, group_id} <- required_identifier(op, "group_id"),
         {:ok, expected_revision} <- optional_revision(op) do
      {:ok,
       Map.merge(base, %{type: type, group_id: group_id, expected_revision: expected_revision})}
    end
  end

  defp required_identifier(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_present(op, key) do
    case Map.get(op, key) do
      nil -> {:error, "invalid_operation"}
      value -> {:ok, value}
    end
  end

  defp required_date(op, key) do
    case parse_date(Map.get(op, key)) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp optional_revision(op) do
    case Map.get(op, "expected_revision") do
      nil -> {:ok, nil}
      revision when is_integer(revision) and revision > 0 -> {:ok, revision}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_value), do: :error

  ## Opening

  defp apply_command(%{type: :open_group} = cmd) do
    with :ok <- ensure_group_absent(cmd.group_id),
         {:ok, arrival_on, departure_on} <- validate_stay(cmd),
         {:ok, rate_plan} <- validate_rate_plan(cmd.rate_plan),
         {:ok, rooms} <- validate_rooms(cmd.rooms),
         {:ok, priced_rooms} <- price_rooms(rooms, arrival_on, departure_on, rate_plan) do
      group =
        Repo.insert!(%Group{
          group_id: cmd.group_id,
          guest_id: cmd.guest_id,
          property_id: cmd.property_id,
          booked_on: cmd.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: "active",
          revision: 1,
          lodging_total_cents: sum(priced_rooms, :lodging_cents),
          deposit_due_cents: sum(priced_rooms, :deposit_cents),
          deposit_paid_cents: 0
        })

      Enum.each(priced_rooms, fn room ->
        Repo.insert!(struct!(Room, Map.put(room, :group_ref, group.id)))
      end)

      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    end
  end

  ## Cash payments

  defp apply_command(%{type: :record_cash_payment} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(cmd.amount_cents),
         :ok <- ensure_within_outstanding(group, amount) do
      insert_ledger_entry!(group, cmd, "cash_payment", amount)
      group = update_group!(group, deposit_paid_cents: group.deposit_paid_cents + amount)

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  ## Rescheduling

  defp apply_command(%{type: :reschedule_group} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on, new_departure_on} <- validate_new_stay(group, cmd) do
      group = update_group!(group, arrival_on: new_arrival_on, departure_on: new_departure_on)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         revision: group.revision
       }}
    end
  end

  ## Cancellation

  defp apply_command(%{type: :cancel_group} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group) do
      paid = group.deposit_paid_cents

      {refunded, retained} =
        if refundable?(group, cmd.occurred_on), do: {paid, 0}, else: {0, paid}

      if refunded > 0, do: insert_ledger_entry!(group, cmd, "cash_refund", refunded)
      if retained > 0, do: insert_ledger_entry!(group, cmd, "cash_retained", retained)

      group = update_group!(group, status: "cancelled")

      {:ok,
       %{
         group_id: group.group_id,
         refunded_cents: refunded,
         retained_cents: retained,
         revision: group.revision
       }}
    end
  end

  defp refundable?(%Group{rate_plan: "flexible", arrival_on: arrival_on}, cancelled_on),
    do: Date.diff(arrival_on, cancelled_on) >= @refund_notice_days

  defp refundable?(%Group{}, _cancelled_on), do: false

  ## Shared rules

  defp ensure_group_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id),
      do: {:error, %{code: "group_already_exists"}},
      else: :ok
  end

  # Group existence is resolved first, then the revision precondition, before any other rule.
  defp fetch_group_for_update(%{group_id: group_id, expected_revision: expected}) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, %{code: "group_not_found"}}

      %Group{revision: actual} when is_integer(expected) and expected != actual ->
        {:error,
         %{
           code: "stale_revision",
           group_id: group_id,
           expected_revision: expected,
           actual_revision: actual
         }}

      group ->
        {:ok, group}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:error, %{code: "group_not_active"}}

  defp validate_stay(cmd) do
    with {:ok, arrival_on} <- parse_date(cmd.arrival_on),
         {:ok, departure_on} <- parse_date(cmd.departure_on),
         true <- Date.compare(arrival_on, cmd.occurred_on) == :gt,
         true <- Date.compare(departure_on, arrival_on) == :gt do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, %{code: "invalid_stay"}}
    end
  end

  # The departure moves by the same number of days as the arrival, keeping the stay's length.
  defp validate_new_stay(group, cmd) do
    with {:ok, new_arrival_on} <- parse_date(cmd.new_arrival_on),
         :gt <- Date.compare(new_arrival_on, cmd.occurred_on),
         new_departure_on =
           Date.add(group.departure_on, Date.diff(new_arrival_on, group.arrival_on)),
         true <- new_departure_on.year <= 9999 do
      {:ok, new_arrival_on, new_departure_on}
    else
      _ -> {:error, %{code: "invalid_stay"}}
    end
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in Deposits.rate_plans(),
      do: {:ok, rate_plan},
      else: {:error, %{code: "invalid_rate_plan"}}
  end

  defp validate_rooms([_ | _] = rooms) do
    parsed = Enum.map(rooms, &parse_room/1)
    room_ids = Enum.map(parsed, &elem(&1, 0))

    if Enum.all?(parsed, &match?({id, _} when is_binary(id), &1)) and
         Enum.uniq(room_ids) == room_ids do
      {:ok, parsed}
    else
      {:error, %{code: "invalid_rooms"}}
    end
  end

  defp validate_rooms(_rooms), do: {:error, %{code: "invalid_rooms"}}

  defp parse_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0,
       do: {room_id, rate}

  defp parse_room(_room), do: {:invalid, nil}

  defp price_rooms(rooms, arrival_on, departure_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    priced_rooms =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {{room_id, rate}, position} ->
        lodging = Deposits.room_lodging_cents(nights, rate)

        %{
          position: position,
          room_id: room_id,
          nightly_rate_cents: rate,
          lodging_cents: lodging,
          deposit_cents: Deposits.room_deposit_cents(rate_plan, lodging)
        }
      end)

    if sum(priced_rooms, :lodging_cents) <= @max_cents,
      do: {:ok, priced_rooms},
      else: {:error, %{code: "invalid_rooms"}}
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp validate_amount(_amount), do: {:error, %{code: "invalid_amount"}}

  defp ensure_within_outstanding(group, amount) do
    if amount <= Group.outstanding_deposit_cents(group),
      do: :ok,
      else: {:error, %{code: "payment_exceeds_outstanding"}}
  end

  # Every applied operation addressed to a group increments its revision exactly once. The
  # revision guard in the WHERE clause protects against a concurrent writer.
  defp update_group!(%Group{} = group, changes) do
    changes = Keyword.merge(changes, revision: group.revision + 1, updated_at: now())

    {1, _} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision),
        set: changes
      )

    struct!(group, changes)
  end

  defp insert_ledger_entry!(group, cmd, kind, amount) do
    Repo.insert!(%LedgerEntry{
      group_ref: group.id,
      operation_id: cmd.operation_id,
      kind: kind,
      amount_cents: amount,
      occurred_on: cmd.occurred_on
    })
  end

  defp sum(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  defp now, do: DateTime.utc_now()
end
