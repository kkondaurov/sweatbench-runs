defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and exposes the resulting group and ledger state.

  Each operation owns a database transaction. A rejected operation therefore cannot leak a
  partial accounting or booking change, while earlier operations in the same batch remain
  committed and visible to later operations.
  """

  import Ecto.Query

  alias GroupStay.{Group, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)
  @active "active"
  @cancelled "cancelled"
  @max_sqlite_integer 9_223_372_036_854_775_807

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> serialize_group()
    end
  end

  def ledger do
    from(group in Group,
      select: {group.cash_held_cents, group.cash_refunded_cents, group.cash_retained_cents}
    )
    |> Repo.all()
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

  defp apply_operation(operation) when is_map(operation) do
    case operation["type"] do
      "open_group" -> transact(fn -> open_group(operation) end)
      "record_cash_payment" -> transact(fn -> with_group(operation, &record_cash_payment/2) end)
      "reschedule_group" -> transact(fn -> with_group(operation, &reschedule_group/2) end)
      "cancel_group" -> transact(fn -> with_group(operation, &cancel_group/2) end)
      _unknown -> reject(operation, "invalid_operation")
    end
  end

  defp apply_operation(_operation), do: reject(%{}, "invalid_operation")

  defp transact(fun) do
    transaction = fn ->
      case fun.() do
        %{status: "rejected"} = result -> Repo.rollback({:rejected, result})
        result -> result
      end
    end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, result} -> result
      {:error, {:rejected, result}} -> result
    end
  end

  defp open_group(operation) do
    with :ok <- require_open_fields(operation) do
      case Repo.get(Group, operation["group_id"]) do
        nil -> validate_and_open(operation)
        _group -> reject(operation, "group_already_exists")
      end
    else
      :error -> reject(operation, "invalid_operation")
    end
  end

  defp validate_and_open(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.before?(arrival_on, departure_on) do
      validate_open_rate_and_rooms(operation, booked_on, arrival_on, departure_on)
    else
      _invalid -> reject(operation, "invalid_stay")
    end
  end

  defp validate_open_rate_and_rooms(operation, booked_on, arrival_on, departure_on) do
    cond do
      operation["rate_plan"] not in @rate_plans ->
        reject(operation, "invalid_rate_plan")

      not valid_rooms?(operation["rooms"], Date.diff(departure_on, arrival_on)) ->
        reject(operation, "invalid_rooms")

      true ->
        case calculate_totals(
               operation["rooms"],
               Date.diff(departure_on, arrival_on),
               operation["rate_plan"]
             ) do
          {:ok, lodging_total_cents, deposit_due_cents} ->
            persist_group(
              operation,
              booked_on,
              arrival_on,
              departure_on,
              lodging_total_cents,
              deposit_due_cents
            )

          :error ->
            reject(operation, "invalid_rooms")
        end
    end
  end

  defp persist_group(
         operation,
         booked_on,
         arrival_on,
         departure_on,
         lodging_total_cents,
         deposit_due_cents
       ) do
    group = %Group{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      status: @active,
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents
    }

    case Repo.insert(group) do
      {:ok, group} ->
        operation["rooms"]
        |> Enum.with_index()
        |> Enum.each(fn {room, position} ->
          %Room{
            group_id: group.group_id,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position
          }
          |> Repo.insert!()
        end)

        applied(operation,
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        )

      {:error, _changeset} ->
        reject(operation, "group_already_exists")
    end
  end

  defp with_group(operation, apply_fun) do
    with :ok <- require_group_operation_fields(operation),
         %Group{} = group <- Repo.get(Group, operation["group_id"]) do
      with :ok <- check_expected_revision(operation, group) do
        apply_fun.(operation, group)
      else
        {:stale, expected_revision} ->
          operation
          |> reject("stale_revision")
          |> Map.merge(%{
            group_id: group.group_id,
            expected_revision: expected_revision,
            actual_revision: group.revision
          })

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      :error -> reject(operation, "invalid_operation")
      nil -> reject(operation, "group_not_found")
    end
  end

  defp record_cash_payment(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not valid_payment_amount?(operation["amount_cents"]) ->
        reject(operation, "invalid_amount")

      operation["amount_cents"] > outstanding_deposit(group) ->
        reject(operation, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]

        group =
          group
          |> Ecto.Changeset.change(%{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_held_cents: group.cash_held_cents + amount,
            revision: group.revision + 1
          })
          |> Repo.update!()

        applied(operation,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp reschedule_group(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
             true <- Date.after?(new_arrival_on, occurred_on) do
          with {:ok, new_departure_on} <-
                 shift_departure(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)) do
            group =
              group
              |> Ecto.Changeset.change(%{
                arrival_on: new_arrival_on,
                departure_on: new_departure_on,
                revision: group.revision + 1
              })
              |> Repo.update!()

            applied(operation,
              group_id: group.group_id,
              new_arrival_on: Date.to_iso8601(group.arrival_on),
              new_departure_on: Date.to_iso8601(group.departure_on),
              revision: group.revision
            )
          else
            :error -> reject(operation, "invalid_stay")
          end
        else
          _invalid -> reject(operation, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} -> settle_cancellation(operation, group, occurred_on)
          :error -> reject(operation, "invalid_operation")
        end
    end
  end

  defp settle_cancellation(operation, group, occurred_on) do
    refundable =
      group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    {refunded_cents, retained_cents} =
      if refundable, do: {group.cash_held_cents, 0}, else: {0, group.cash_held_cents}

    group =
      group
      |> Ecto.Changeset.change(%{
        status: @cancelled,
        cash_held_cents: 0,
        cash_refunded_cents: group.cash_refunded_cents + refunded_cents,
        cash_retained_cents: group.cash_retained_cents + retained_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

    applied(operation,
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: group.revision
    )
  end

  defp require_open_fields(operation) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      :ok
    else
      :error
    end
  end

  defp require_group_operation_fields(operation) do
    type_specific =
      case operation["type"] do
        "record_cash_payment" -> ["amount_cents"]
        "reschedule_group" -> ["new_arrival_on"]
        "cancel_group" -> []
      end

    required = ~w(operation_id occurred_on group_id) ++ type_specific

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["group_id"]) do
      :ok
    else
      :error
    end
  end

  defp required_present?(operation, fields), do: Enum.all?(fields, &Map.has_key?(operation, &1))

  defp valid_identifier?(identifier), do: is_binary(identifier) and byte_size(identifier) > 0

  defp valid_rooms?(rooms, nights) when is_list(rooms) and rooms != [] do
    room_ids = Enum.map(rooms, &room_id/1)

    Enum.all?(rooms, &valid_room?(&1, nights)) and
      Enum.uniq(room_ids) == room_ids
  end

  defp valid_rooms?(_rooms, _nights), do: false

  defp valid_room?(room, nights) when is_map(room) do
    room_id = room["room_id"]
    rate = room["nightly_rate_cents"]

    valid_identifier?(room_id) and is_integer(rate) and rate >= 0 and
      rate <= @max_sqlite_integer and nights * rate <= @max_sqlite_integer
  end

  defp valid_room?(_room, _nights), do: false

  defp room_id(room) when is_map(room), do: room["room_id"]
  defp room_id(_room), do: nil

  defp room_deposit(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)
  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp calculate_totals(rooms, nights, rate_plan) do
    {lodging_total, deposit_total} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging_sum, deposit_sum} ->
        lodging = nights * room["nightly_rate_cents"]
        deposit = room_deposit(lodging, rate_plan)
        {lodging_sum + lodging, deposit_sum + deposit}
      end)

    if lodging_total <= @max_sqlite_integer and deposit_total <= @max_sqlite_integer do
      {:ok, lodging_total, deposit_total}
    else
      :error
    end
  end

  defp valid_payment_amount?(amount) do
    is_integer(amount) and amount > 0 and amount <= @max_sqlite_integer
  end

  defp valid_occurred_on?(operation),
    do: match?({:ok, _date}, parse_date(operation["occurred_on"]))

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp shift_departure(new_arrival_on, stay_length) do
    {:ok, Date.add(new_arrival_on, stay_length)}
  rescue
    ArgumentError -> :error
  end

  defp check_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected} when is_integer(expected) and expected == group.revision -> :ok
      {:ok, expected} when is_integer(expected) -> {:stale, expected}
      {:ok, _invalid} -> :error
    end
  end

  defp outstanding_deposit(%Group{status: @active} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding_deposit(%Group{}), do: 0

  defp serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{
      operation_id: operation_id(operation),
      status: "applied"
    })
  end

  defp reject(operation, code) do
    %{
      operation_id: operation_id(operation),
      status: "rejected",
      code: code
    }
  end

  defp operation_id(operation) do
    case operation["operation_id"] do
      operation_id when is_binary(operation_id) -> operation_id
      _invalid -> nil
    end
  end
end
