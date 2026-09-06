defmodule GroupStay.Groups do
  @moduledoc """
  The group-deposit domain.

  Partner gateways submit batches of reservation and payment operations. This
  context applies each operation in order, reports the outcome of every one,
  and keeps the deposit records needed by support and finance.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @known_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refundable_days_before_arrival 14

  @doc """
  Applies a partner batch. Operations are processed in array order and each
  one observes changes made by earlier operations in the same batch.

  Returns `{:ok, results}` with one result per operation, or
  `{:error, :invalid_batch}` when the payload has no operations array.
  """
  def process_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def process_batch(_other), do: {:error, :invalid_batch}

  @doc """
  Fetches a group by its partner identifier, rendered for the read API.
  """
  def fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, render_group(Repo.preload(group, :rooms))}
    end
  end

  @doc """
  Finance totals for cash held on active reservations and cash moved out of
  them by cancellation settlements.
  """
  def ledger_totals do
    %{
      "cash_held_cents" =>
        Repo.one(
          from g in Group,
            where: g.status == "active",
            select: coalesce(sum(g.deposit_paid_cents), 0)
        ),
      "cash_refunded_cents" =>
        Repo.one(from g in Group, select: coalesce(sum(g.refunded_cents), 0)),
      "cash_retained_cents" =>
        Repo.one(from g in Group, select: coalesce(sum(g.retained_cents), 0))
    }
  end

  # Batch processing

  defp process_operation(op) when is_map(op) do
    operation_id = op["operation_id"]

    cond do
      not is_binary(operation_id) or String.trim(operation_id) == "" ->
        rejected(operation_id, "invalid_operation")

      op["type"] not in @known_types ->
        rejected(operation_id, "invalid_operation")

      true ->
        case Repo.transaction(fn ->
               case apply_operation(op, operation_id) do
                 {:ok, result} -> result
                 {:error, code} -> Repo.rollback({:error, code})
                 {:error, code, extra} -> Repo.rollback({:error, code, extra})
               end
             end) do
          {:ok, result} ->
            result

          {:error, {:error, code}} ->
            rejected(operation_id, code)

          {:error, {:error, code, extra}} ->
            rejected(operation_id, code, extra)
        end
    end
  end

  defp process_operation(_other), do: rejected(nil, "invalid_operation")

  defp apply_operation(op, operation_id) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"], :invalid_operation) do
      case op["type"] do
        "open_group" -> open_group(op, operation_id, occurred_on)
        "record_cash_payment" -> record_cash_payment(op, operation_id)
        "reschedule_group" -> reschedule_group(op, operation_id, occurred_on)
        "cancel_group" -> cancel_group(op, operation_id, occurred_on)
      end
    end
  end

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(
      %{"operation_id" => operation_id, "status" => "rejected", "code" => code},
      extra
    )
  end

  # open_group

  defp open_group(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, guest_id} <- require_id(op, "guest_id"),
         {:ok, property_id} <- require_id(op, "property_id"),
         :ok <- ensure_group_is_new(group_id),
         {:ok, arrival_on} <- parse_date(op["arrival_on"], :invalid_stay),
         {:ok, departure_on} <- parse_date(op["departure_on"], :invalid_stay),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(op["rooms"]),
         {:ok, rate_plan} <- validate_rate_plan(op["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)

      lodging_total_cents = Enum.sum_by(rooms, &(&1.nightly_rate_cents * nights))

      deposit_due_cents =
        case rate_plan do
          "advance_purchase" -> lodging_total_cents
          "flexible" -> Enum.sum_by(rooms, &flexible_room_deposit(&1.nightly_rate_cents * nights))
        end

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          rooms
          |> Enum.with_index()
          |> Enum.each(fn {room, index} ->
            Repo.insert!(%Room{
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: index,
              group_id: group.id
            })
          end)

          {:ok,
           %{
             "operation_id" => operation_id,
             "status" => "applied",
             "group_id" => group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           }}

        {:error, _changeset} ->
          {:error, :group_already_exists}
      end
    end
  end

  defp ensure_group_is_new(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rooms(raw_rooms) when is_list(raw_rooms) and raw_rooms != [] do
    raw_rooms
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case validate_room(raw, acc) do
        {:ok, room} -> {:cont, {:ok, [room | acc]}}
        {:error, :invalid_rooms} -> {:halt, {:error, :invalid_rooms}}
      end
    end)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      {:error, :invalid_rooms} = error -> error
    end
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp validate_room(raw, accepted) do
    with true <- is_map(raw),
         room_id when is_binary(room_id) and room_id != "" <- raw["room_id"],
         rate when is_integer(rate) and rate >= 0 <- raw["nightly_rate_cents"],
         false <- Enum.any?(accepted, &(&1.room_id == room_id)) do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
    else
      _ -> {:error, :invalid_rooms}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_), do: {:error, :invalid_rate_plan}

  # 20% of the room's lodging amount, rounded to the nearest cent with an
  # exact half-cent rounding upward.
  defp flexible_room_deposit(lodging_cents) do
    div(lodging_cents * @flexible_deposit_percent + 50, 100)
  end

  # record_cash_payment

  defp record_cash_payment(op, operation_id) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      new_revision = group.revision + 1
      new_paid = group.deposit_paid_cents + amount_cents

      Repo.update!(change(group, deposit_paid_cents: new_paid, revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => group.deposit_due_cents - new_paid,
         "revision" => new_revision
       }}
    end
  end

  defp validate_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp validate_amount(_), do: {:error, :invalid_amount}

  defp ensure_within_outstanding(group, amount_cents) do
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount_cents <= outstanding do
      :ok
    else
      {:error, :payment_exceeds_outstanding}
    end
  end

  # reschedule_group

  defp reschedule_group(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- parse_date(op["new_arrival_on"], :invalid_stay),
         :ok <- ensure_after(new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)
      new_revision = group.revision + 1

      Repo.update!(
        change(group,
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: new_revision
        )
      )

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "revision" => new_revision
       }}
    end
  end

  defp ensure_after(date, reference_date) do
    if Date.compare(date, reference_date) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  # cancel_group

  defp cancel_group(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group) do
      refundable? =
        group.rate_plan == "flexible" and
          Date.diff(group.arrival_on, occurred_on) >= @refundable_days_before_arrival

      refunded_cents = if refundable?, do: group.deposit_paid_cents, else: 0
      retained_cents = if refundable?, do: 0, else: group.deposit_paid_cents
      new_revision = group.revision + 1

      Repo.update!(
        change(group,
          status: "cancelled",
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          revision: new_revision
        )
      )

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "revision" => new_revision
       }}
    end
  end

  # Shared helpers

  defp fetch_group_record(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_revision(op, group) do
    case op do
      %{"expected_revision" => expected} when expected != nil ->
        if expected == group.revision do
          :ok
        else
          {:error, :stale_revision,
           %{
             "group_id" => group.group_id,
             "expected_revision" => expected,
             "actual_revision" => group.revision
           }}
        end

      _ ->
        :ok
    end
  end

  defp ensure_active(group) do
    if group.status == "active", do: :ok, else: {:error, :group_not_active}
  end

  defp require_id(op, key) do
    case op[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp parse_date(value, error_code) do
    case value do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, error_code}
        end

      _ ->
        {:error, error_code}
    end
  end

  # Read rendering

  defp render_group(group) do
    rooms =
      group.rooms
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&%{"room_id" => &1.room_id, "nightly_rate_cents" => &1.nightly_rate_cents})

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" => rooms,
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  defp outstanding_deposit_cents(%{status: "cancelled"}), do: 0

  defp outstanding_deposit_cents(group),
    do: group.deposit_due_cents - group.deposit_paid_cents
end
