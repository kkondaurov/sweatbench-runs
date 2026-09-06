defmodule GroupStay.Operations do
  @moduledoc """
  Processing of partner batch operations.

  Operations are applied in array order, each inside its own database
  transaction. A rejected operation rolls its transaction back — leaving
  the database exactly as it was — and processing continues with the next
  operation.
  """

  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refundable_lead_days 14

  @type operation_result :: %{String.t() => term()}

  @doc """
  Processes a whole partner batch, returning `{:ok, results}` with one
  result per operation, or `{:error, :invalid_batch}` when the payload does
  not carry an operations array.
  """
  @spec process_batch(map()) :: {:ok, [operation_result()]} | {:error, :invalid_batch}
  def process_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def process_batch(_), do: {:error, :invalid_batch}

  defp process_operation(operation) when is_map(operation) do
    with {:ok, operation_id} <- require_string(operation, "operation_id"),
         {:ok, type} <- fetch_type(operation),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, context} <- fetch_context(type, operation) do
      apply_operation(type, operation, operation_id, occurred_on, context)
    else
      {:error, code} -> rejected(operation["operation_id"], code)
    end
  end

  defp process_operation(_operation), do: rejected(nil, :invalid_operation)

  # -- structural validation --------------------------------------------------

  defp fetch_type(%{"type" => type}) when type in @operation_types, do: {:ok, type}
  defp fetch_type(_), do: {:error, :invalid_operation}

  defp fetch_occurred_on(%{"occurred_on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_operation}
    end
  end

  defp fetch_occurred_on(_), do: {:error, :invalid_operation}

  # The fields needed to identify the operation and the group it addresses.
  defp fetch_context("open_group", operation) do
    with {:ok, group_id} <- require_string(operation, "group_id"),
         {:ok, guest_id} <- require_string(operation, "guest_id"),
         {:ok, property_id} <- require_string(operation, "property_id") do
      {:ok, %{group_id: group_id, guest_id: guest_id, property_id: property_id}}
    end
  end

  defp fetch_context(_type, operation) do
    case require_string(operation, "group_id") do
      {:ok, group_id} -> {:ok, %{group_id: group_id}}
      {:error, code} -> {:error, code}
    end
  end

  defp require_string(operation, key) do
    case operation do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_operation}
    end
  end

  # -- per-operation execution ------------------------------------------------

  defp apply_operation(type, operation, operation_id, occurred_on, context) do
    case Repo.transact(fn ->
           run(type, operation, operation_id, occurred_on, context)
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp run("open_group", operation, operation_id, occurred_on, context) do
    with :ok <- ensure_group_new(context.group_id, operation_id),
         {:ok, arrival_on, departure_on} <- parse_stay(operation),
         {:ok, rooms} <- parse_rooms(operation),
         {:ok, rate_plan} <- parse_rate_plan(operation),
         {:ok, group} <-
           create_group(context, occurred_on, arrival_on, departure_on, rooms, rate_plan) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "deposit_due_cents" => group.deposit_due_cents,
         "revision" => group.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("record_cash_payment", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, amount_cents} <- parse_amount(operation),
         :ok <- ensure_within_outstanding(group, amount_cents, operation_id),
         {:ok, _payment} <- Groups.create_payment(group, amount_cents, occurred_on),
         {:ok, revision} <- bump_revision(group, operation, operation_id) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group) - amount_cents,
         "revision" => revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("reschedule_group", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, new_arrival_on} <- parse_new_arrival(operation, occurred_on),
         {:ok, updated} <- reschedule(group, new_arrival_on, operation, operation_id) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
         "new_departure_on" => Date.to_iso8601(updated.departure_on),
         "revision" => updated.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("cancel_group", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, updated} <- cancel(group, occurred_on, operation, operation_id) do
      held_cents = Groups.held_paid_cents(group)

      {refunded_cents, retained_cents} =
        if refundable?(group, occurred_on), do: {held_cents, 0}, else: {0, held_cents}

      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "revision" => updated.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  # -- open_group ------------------------------------------------------------

  defp ensure_group_new(group_id, operation_id) do
    if Groups.group_exists?(group_id) do
      {:error, rejected(operation_id, :group_already_exists)}
    else
      :ok
    end
  end

  defp parse_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation, "arrival_on", :invalid_stay),
         {:ok, departure_on} <- parse_date(operation, "departure_on", :invalid_stay) do
      if Date.diff(departure_on, arrival_on) >= 1 do
        {:ok, arrival_on, departure_on}
      else
        {:error, :invalid_stay}
      end
    end
  end

  defp parse_rooms(operation) do
    case operation do
      %{"rooms" => rooms} when is_list(rooms) and rooms != [] ->
        parse_room_entries(rooms, [])

      _ ->
        {:error, :invalid_rooms}
    end
  end

  defp parse_room_entries([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_room_entries([entry | rest], acc) when is_map(entry) do
    with {:ok, room_id} <- require_room_string(entry, "room_id"),
         {:ok, nightly_rate_cents} <- parse_nightly_rate(entry) do
      if Enum.any?(acc, &match?({^room_id, _}, &1)) do
        {:error, :invalid_rooms}
      else
        parse_room_entries(rest, [{room_id, nightly_rate_cents} | acc])
      end
    end
  end

  defp parse_room_entries([_ | _], _acc), do: {:error, :invalid_rooms}

  defp require_room_string(entry, key) do
    case entry do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_rooms}
    end
  end

  defp parse_nightly_rate(%{"nightly_rate_cents" => cents})
       when is_integer(cents) and cents >= 0,
       do: {:ok, cents}

  defp parse_nightly_rate(_), do: {:error, :invalid_rooms}

  defp parse_rate_plan(%{"rate_plan" => rate_plan}) when rate_plan in @rate_plans,
    do: {:ok, rate_plan}

  defp parse_rate_plan(_), do: {:error, :invalid_rate_plan}

  defp create_group(context, occurred_on, arrival_on, departure_on, rooms, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    room_amounts = Enum.map(rooms, fn {_room_id, rate} -> nights * rate end)
    lodging_total_cents = Enum.sum(room_amounts)

    deposit_due_cents =
      case rate_plan do
        "flexible" -> Enum.sum(Enum.map(room_amounts, &flexible_deposit_cents/1))
        "advance_purchase" -> lodging_total_cents
      end

    attrs = %{
      group_id: context.group_id,
      guest_id: context.guest_id,
      property_id: context.property_id,
      booked_on: occurred_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents
    }

    room_attrs =
      Enum.map(rooms, fn {room_id, rate} -> %{room_id: room_id, nightly_rate_cents: rate} end)

    Groups.create_group(attrs, room_attrs)
  end

  defp flexible_deposit_cents(room_amount_cents) do
    numerator = room_amount_cents * @flexible_deposit_percent

    # Round to the nearest cent; an exact half-cent rounds upward.
    div(numerator + 50, 100)
  end

  # -- record_cash_payment ------------------------------------------------------

  defp parse_amount(%{"amount_cents" => amount}) when is_integer(amount) and amount > 0,
    do: {:ok, amount}

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp ensure_within_outstanding(group, amount_cents, operation_id) do
    if amount_cents <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, rejected(operation_id, :payment_exceeds_outstanding)}
    end
  end

  # -- reschedule_group ---------------------------------------------------------

  defp parse_new_arrival(operation, occurred_on) do
    with {:ok, new_arrival_on} <- parse_date(operation, "new_arrival_on", :invalid_stay) do
      if Date.compare(new_arrival_on, occurred_on) == :gt do
        {:ok, new_arrival_on}
      else
        {:error, :invalid_stay}
      end
    end
  end

  defp reschedule(group, new_arrival_on, operation, operation_id) do
    shift_days = Date.diff(new_arrival_on, group.arrival_on)
    new_departure_on = Date.add(group.departure_on, shift_days)

    case Groups.reschedule_group(group, new_arrival_on, new_departure_on) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, _changeset} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  # -- cancel_group -------------------------------------------------------------

  defp refundable?(%Group{rate_plan: "flexible", arrival_on: arrival_on}, occurred_on) do
    Date.diff(arrival_on, occurred_on) >= @refundable_lead_days
  end

  defp refundable?(_group, _occurred_on), do: false

  defp cancel(group, occurred_on, operation, operation_id) do
    settlement_state = if refundable?(group, occurred_on), do: "refunded", else: "retained"

    case Groups.cancel_group(group, settlement_state) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, _changeset} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  # -- shared group checks --------------------------------------------------------

  defp fetch_group(group_id, operation_id) do
    case Groups.fetch_by_group_id(group_id) do
      nil -> {:error, rejected(operation_id, :group_not_found)}
      %Group{} = group -> {:ok, group}
    end
  end

  defp ensure_active(%Group{status: "active"}, _operation_id), do: :ok

  defp ensure_active(_group, operation_id),
    do: {:error, rejected(operation_id, :group_not_active)}

  defp check_revision(group, operation, operation_id) do
    case operation do
      %{"expected_revision" => expected} when is_integer(expected) ->
        if expected == group.revision do
          :ok
        else
          {:error, stale_rejection(operation_id, group.group_id, expected, group.revision)}
        end

      %{"expected_revision" => other} when other != nil ->
        {:error, rejected(operation_id, :invalid_operation)}

      _ ->
        :ok
    end
  end

  defp bump_revision(group, operation, operation_id) do
    case Groups.bump_revision(group) do
      {:ok, revision} ->
        {:ok, revision}

      {:error, :stale} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  # -- result building ------------------------------------------------------------

  defp parse_date(operation, key, error) do
    case operation do
      %{^key => value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, error}
        end

      _ ->
        {:error, error}
    end
  end

  defp applied(operation_id, fields) do
    Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)
  end

  defp rejected(operation_id, code) when is_atom(code),
    do: %{"operation_id" => operation_id, "status" => "rejected", "code" => Atom.to_string(code)}

  defp stale_rejection(operation_id, group_id, expected_revision, actual_revision)
       when is_integer(expected_revision) do
    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "actual_revision" => actual_revision
    }
  end

  defp stale_rejection(operation_id, group_id, operation, actual_revision) do
    case operation do
      %{"expected_revision" => expected} when is_integer(expected) ->
        stale_rejection(operation_id, group_id, expected, actual_revision)

      _ ->
        %{
          "operation_id" => operation_id,
          "status" => "rejected",
          "code" => "stale_revision",
          "group_id" => group_id,
          "expected_revision" => nil,
          "actual_revision" => actual_revision
        }
    end
  end
end
