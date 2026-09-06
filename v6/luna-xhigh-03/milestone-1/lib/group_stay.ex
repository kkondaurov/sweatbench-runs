defmodule GroupStay do
  @moduledoc """
  GroupStay keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.{Group, Repo}

  @active_status "active"
  @cancelled_status "cancelled"
  @rate_plans ["flexible", "advance_purchase"]

  @doc "Processes partner operations in order and returns one result per operation."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns a public group representation or `:not_found`."
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, public_group(group)}
    end
  end

  @doc "Returns the accounting totals currently tracked by GroupStay."
  def ledger do
    Repo.all(Group)
    |> Enum.reduce(
      %{
        "cash_held_cents" => 0,
        "cash_refunded_cents" => 0,
        "cash_retained_cents" => 0
      },
      fn group, ledger ->
        held = if group.status == @active_status, do: group.deposit_paid_cents, else: 0

        %{
          "cash_held_cents" => ledger["cash_held_cents"] + held,
          "cash_refunded_cents" => ledger["cash_refunded_cents"] + (group.refunded_cents || 0),
          "cash_retained_cents" => ledger["cash_retained_cents"] + (group.retained_cents || 0)
        }
      end
    )
  end

  defp process_operation(operation) do
    case Repo.transaction(fn -> apply_operation(operation) end, mode: :immediate) do
      {:ok, {_status, result}} -> result
      {:error, _reason} -> rejected(operation, "invalid_operation")
    end
  end

  defp apply_operation(operation) do
    case operation_type(operation) do
      "open_group" -> apply_open_group(operation)
      "record_cash_payment" -> apply_cash_payment(operation)
      "reschedule_group" -> apply_reschedule(operation)
      "cancel_group" -> apply_cancellation(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp apply_open_group(operation) do
    with {:ok, _operation_id} <- operation_id(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get(Group, group_id) do
        %Group{} -> rejected(operation, "group_already_exists")
        nil -> build_open_group(operation, group_id)
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp build_open_group(operation, group_id) do
    with {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- valid_rate_plan(operation),
         {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
           calculate_rooms(operation, arrival_on, departure_on, rate_plan) do
      group = %Group{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: @active_status,
        rooms_json: Jason.encode!(rooms),
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        revision: 1
      }

      case Repo.insert(group) do
        {:ok, _group} ->
          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           }}

        {:error, _changeset} ->
          rejected(operation, "group_already_exists")
      end
    else
      {:error, code} -> rejected(operation, code)
      :invalid_stay -> rejected(operation, "invalid_stay")
    end
  end

  defp apply_cash_payment(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
             {:ok, amount_cents} <- payment_amount(operation),
             outstanding_deposit_cents <- outstanding_deposit(group),
             :ok <- payment_fits(amount_cents, outstanding_deposit_cents) do
          {:ok, updated_group} =
            update_group(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount_cents,
              revision: group.revision + 1
            })

          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => updated_group.group_id,
             "amount_cents" => amount_cents,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           }}
        else
          {:error, code} -> rejected(operation, code)
          :payment_exceeds_outstanding -> rejected(operation, "payment_exceeds_outstanding")
        end
      end
    end)
  end

  defp apply_reschedule(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
             {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
             :ok <- reschedule_date_is_valid(occurred_on, new_arrival_on) do
          day_shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, day_shift)

          {:ok, updated_group} =
            update_group(group, %{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            })

          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => updated_group.group_id,
             "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
             "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
             "revision" => updated_group.revision
           }}
        else
          {:error, code} -> rejected(operation, code)
          :invalid_stay -> rejected(operation, "invalid_stay")
        end
      end
    end)
  end

  defp apply_cancellation(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, occurred_on} <- required_date(operation, "occurred_on") do
          refundable? =
            group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

          refunded_cents = if refundable?, do: group.deposit_paid_cents, else: 0
          retained_cents = group.deposit_paid_cents - refunded_cents

          {:ok, updated_group} =
            update_group(group, %{
              status: @cancelled_status,
              refunded_cents: refunded_cents,
              retained_cents: retained_cents,
              revision: group.revision + 1
            })

          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => updated_group.group_id,
             "refunded_cents" => refunded_cents,
             "retained_cents" => retained_cents,
             "revision" => updated_group.revision
           }}
        else
          {:error, code} -> rejected(operation, code)
        end
      end
    end)
  end

  defp apply_to_existing_group(operation, callback) do
    with {:ok, _operation_id} <- operation_id(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get(Group, group_id) do
        nil ->
          rejected(operation, "group_not_found")

        group ->
          case stale_revision(operation, group) do
            :ok ->
              callback.(group)

            {:stale, expected_revision} ->
              rejected(operation, "stale_revision", %{
                "group_id" => group.group_id,
                "expected_revision" => expected_revision,
                "actual_revision" => group.revision
              })
          end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp update_group(group, attributes) do
    case Repo.update(change(group, attributes)) do
      {:ok, updated_group} -> {:ok, updated_group}
      {:error, changeset} -> Repo.rollback({:update_failed, changeset})
    end
  end

  defp stale_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") do
      expected_revision = Map.get(operation, "expected_revision")

      if expected_revision === group.revision do
        :ok
      else
        {:stale, expected_revision}
      end
    else
      :ok
    end
  end

  defp calculate_rooms(operation, arrival_on, departure_on, rate_plan) do
    rooms = Map.get(operation, "rooms")
    nights = Date.diff(departure_on, arrival_on)

    if is_list(rooms) and rooms != [] do
      rooms
      |> Enum.reduce_while({:ok, [], 0, 0, MapSet.new()}, fn room,
                                                             {:ok, parsed, lodging, deposit, ids} ->
        with {:ok, room_id} <- room_identifier(room),
             :ok <- unique_room_id(room_id, ids),
             {:ok, nightly_rate_cents} <- nightly_rate(room) do
          room_lodging = nights * nightly_rate_cents

          room_deposit =
            if rate_plan == "flexible",
              do: round_percentage(room_lodging, 20, 100),
              else: room_lodging

          {:cont,
           {:ok, parsed ++ [%{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}],
            lodging + room_lodging, deposit + room_deposit, MapSet.put(ids, room_id)}}
        else
          _ -> {:halt, :invalid_rooms}
        end
      end)
      |> case do
        {:ok, parsed, lodging, deposit, _ids} -> {:ok, parsed, lodging, deposit}
        :invalid_rooms -> {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp round_percentage(amount, numerator, denominator) do
    quotient = div(amount * numerator, denominator)
    remainder = rem(amount * numerator, denominator)
    if remainder * 2 >= denominator, do: quotient + 1, else: quotient
  end

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: :invalid_stay
  end

  defp reschedule_date_is_valid(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: :invalid_stay
  end

  defp valid_rate_plan(operation) do
    case Map.get(operation, "rate_plan") do
      rate_plan when rate_plan in @rate_plans -> {:ok, rate_plan}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp payment_amount(operation) do
    case Map.get(operation, "amount_cents") do
      amount_cents when is_integer(amount_cents) and amount_cents > 0 -> {:ok, amount_cents}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp payment_fits(amount_cents, outstanding_deposit_cents) do
    if amount_cents <= outstanding_deposit_cents, do: :ok, else: :payment_exceeds_outstanding
  end

  defp outstanding_deposit(%Group{status: @active_status} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit(%Group{}), do: 0

  defp room_identifier(room) when is_map(room) do
    case Map.get(room, "room_id") do
      room_id when is_binary(room_id) and byte_size(room_id) > 0 -> {:ok, room_id}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp room_identifier(_), do: {:error, "invalid_rooms"}

  defp unique_room_id(room_id, ids) do
    if MapSet.member?(ids, room_id), do: {:error, "invalid_rooms"}, else: :ok
  end

  defp nightly_rate(room) do
    if is_map(room) do
      case Map.get(room, "nightly_rate_cents") do
        nightly_rate_cents when is_integer(nightly_rate_cents) and nightly_rate_cents > 0 ->
          {:ok, nightly_rate_cents}

        _ ->
          {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp operation_type(operation) when is_map(operation), do: Map.get(operation, "type")
  defp operation_type(_operation), do: nil

  defp operation_id(operation) when is_map(operation) do
    if valid_identifier?(Map.get(operation, "operation_id")),
      do: {:ok, Map.get(operation, "operation_id")},
      else: {:error, "invalid_operation"}
  end

  defp operation_id(_operation), do: {:error, "invalid_operation"}

  defp operation_id_value(operation) when is_map(operation),
    do: Map.get(operation, "operation_id")

  defp operation_id_value(_operation), do: nil

  defp required_identifier(operation, key) do
    if is_map(operation) and valid_identifier?(Map.get(operation, key)),
      do: {:ok, Map.get(operation, key)},
      else: {:error, "invalid_operation"}
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp required_date(operation, key) when is_map(operation) do
    case Map.get(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp required_date(_operation, _key), do: {:error, "invalid_stay"}

  defp rejected(operation, code, extra \\ %{}) do
    {:rejected,
     Map.merge(
       %{
         "operation_id" => operation_id_value(operation),
         "status" => "rejected",
         "code" => code
       },
       extra
     )}
  end

  defp public_group(group) do
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
      "rooms" => Jason.decode!(group.rooms_json),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end
end
