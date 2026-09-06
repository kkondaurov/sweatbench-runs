defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations and owns reservation deposits and cash settlements.

  Each operation has its own transaction, so rejections cannot undo earlier operations.
  SQLite's immediate transactions acquire the write lock before reading a revision or
  balance, making validation and the resulting update atomic across connections.
  """

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @max_cents 9_223_372_036_854_775_807
  @group_fields ~w(group_id guest_id property_id revision booked_on arrival_on departure_on
                   rate_plan status lodging_total_cents deposit_due_cents deposit_paid_cents)a

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> serialize_group(group)
    end
  end

  def ledger do
    # Sum integer cents in Elixir to avoid SQLite SUM overflowing when many
    # individually representable balances are combined.
    Repo.all(
      from g in Group,
        select: {g.deposit_paid_cents, g.cash_refunded_cents, g.cash_retained_cents}
    )
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn {held, refunded, retained}, totals ->
        %{
          cash_held_cents: totals.cash_held_cents + held,
          cash_refunded_cents: totals.cash_refunded_cents + refunded,
          cash_retained_cents: totals.cash_retained_cents + retained
        }
      end
    )
  end

  defp process_operation(operation) do
    outcome = transact_operation(operation, System.monotonic_time(:millisecond) + 5_000)
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id")

    case outcome do
      {:ok, result} -> Map.merge(result, %{operation_id: operation_id, status: "applied"})
      {:error, result} -> Map.merge(result, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp transact_operation(operation, lock_deadline) do
    Repo.transact(fn -> apply_operation(operation) end, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      # A failed BEGIN has not executed the operation. Only retry this lock
      # acquisition; never replay an operation whose transaction has begun.
      if error.message == "database is locked" and
           error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           System.monotonic_time(:millisecond) < lock_deadline do
        Process.sleep(10 + :rand.uniform(40))
        transact_operation(operation, lock_deadline)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp apply_operation(operation) when is_map(operation) do
    if operation["type"] in @operation_types and identifier?(operation["operation_id"]) and
         identifier?(operation["group_id"]) do
      case operation["type"] do
        "open_group" -> open_group(operation)
        _ -> update_group(operation)
      end
    else
      reject("invalid_operation")
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp open_group(operation) do
    with :ok <- new_group(operation["group_id"]),
         :ok <-
           required_fields(
             operation,
             ~w(guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         :ok <- guest_and_property(operation),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, {arrival_on, departure_on}} <- stay(operation),
         :ok <- rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- rooms(operation["rooms"], Date.diff(departure_on, arrival_on)) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_amounts = Enum.map(rooms, &(&1.nightly_rate_cents * nights))

      deposit_due =
        case operation["rate_plan"] do
          "flexible" -> Enum.sum(Enum.map(lodging_amounts, &div(&1 * 20 + 50, 100)))
          "advance_purchase" -> Enum.sum(lodging_amounts)
        end

      group =
        Repo.insert!(%Group{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          rooms: rooms,
          lodging_total_cents: Enum.sum(lodging_amounts),
          deposit_due_cents: deposit_due
        })

      applied(group, %{deposit_due_cents: deposit_due})
    end
  end

  defp update_group(operation) do
    with {:ok, group} <- find_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, occurred_on} <- operation_date(operation),
         :ok <- active(group) do
      case operation["type"] do
        "record_cash_payment" -> record_cash_payment(group, operation)
        "reschedule_group" -> reschedule_group(group, operation, occurred_on)
        "cancel_group" -> cancel_group(group, occurred_on)
      end
    end
  end

  defp record_cash_payment(group, operation) do
    with :ok <- required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(operation["amount_cents"]),
         :ok <- within_outstanding(group, operation["amount_cents"]) do
      group =
        save_group(group,
          deposit_paid_cents: group.deposit_paid_cents + operation["amount_cents"]
        )

      applied(group, %{
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: outstanding(group)
      })
    end
  end

  defp reschedule_group(group, operation, occurred_on) do
    with :ok <- required_fields(operation, ["new_arrival_on"]),
         {:ok, arrival_on} <- parse_date(operation["new_arrival_on"], "invalid_stay"),
         :ok <- future_arrival(arrival_on, occurred_on),
         {:ok, departure_on} <- shift_departure(group, arrival_on) do
      group = save_group(group, arrival_on: arrival_on, departure_on: departure_on)
      applied(group, %{new_arrival_on: arrival_on, new_departure_on: departure_on})
    end
  end

  defp cancel_group(group, occurred_on) do
    refundable? =
      group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    {refunded, retained} =
      if refundable?, do: {group.deposit_paid_cents, 0}, else: {0, group.deposit_paid_cents}

    group =
      save_group(group,
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_refunded_cents: refunded,
        cash_retained_cents: retained
      )

    applied(group, %{refunded_cents: refunded, retained_cents: retained})
  end

  defp save_group(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp applied(group, result) do
    {:ok, Map.merge(result, %{group_id: group.group_id, revision: group.revision})}
  end

  defp reject(code), do: {:error, %{code: code}}

  defp new_group(group_id) do
    if Repo.get(Group, group_id), do: reject("group_already_exists"), else: :ok
  end

  defp find_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> reject("group_not_found")
      group -> {:ok, group}
    end
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp required_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: reject("invalid_operation")
  end

  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp guest_and_property(operation) do
    if identifier?(operation["guest_id"]) and identifier?(operation["property_id"]),
      do: :ok,
      else: reject("invalid_operation")
  end

  defp operation_date(operation), do: parse_date(operation["occurred_on"], "invalid_operation")

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> reject(code)
    end
  end

  defp parse_date(_, code), do: reject(code)

  defp stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay") do
      if Date.compare(departure_on, arrival_on) == :gt,
        do: {:ok, {arrival_on, departure_on}},
        else: reject("invalid_stay")
    end
  end

  defp rate_plan(plan) when plan in ["flexible", "advance_purchase"], do: :ok
  defp rate_plan(_), do: reject("invalid_rate_plan")

  defp rooms(rooms, nights) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and
         length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) and
         Enum.sum(Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))) <= @max_cents do
      {:ok,
       Enum.map(rooms, fn room ->
         %Room{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      reject("invalid_rooms")
    end
  end

  defp rooms(_, _), do: reject("invalid_rooms")

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate}) do
    identifier?(room_id) and is_integer(rate) and rate >= 0 and rate <= @max_cents
  end

  defp valid_room?(_), do: false

  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: reject("group_not_active")

  defp payment_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp payment_amount(_), do: reject("invalid_amount")

  defp within_outstanding(group, amount) do
    if amount <= outstanding(group), do: :ok, else: reject("payment_exceeds_outstanding")
  end

  defp future_arrival(arrival_on, occurred_on) do
    if Date.compare(arrival_on, occurred_on) == :gt, do: :ok, else: reject("invalid_stay")
  end

  defp shift_departure(group, arrival_on) do
    departure_on = Date.add(arrival_on, Date.diff(group.departure_on, group.arrival_on))

    # Date.add can produce years beyond the range accepted by ISO date parsing.
    # Reject those before persisting a date that cannot be read back by Ecto.
    parse_date(Date.to_iso8601(departure_on), "invalid_stay")
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp serialize_group(group) do
    group
    |> Map.take(@group_fields)
    |> Map.put(:rooms, Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
  end
end
