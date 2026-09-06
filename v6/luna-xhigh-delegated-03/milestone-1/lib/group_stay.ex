defmodule GroupStay do
  @moduledoc """
  The group-deposit domain and its partner batch operations.
  """

  import Ecto.Query

  alias GroupStay.{Group, GroupRoom, Ledger, Repo}

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @rate_plans ~w(flexible advance_purchase)
  @key_atoms %{
    "operations" => :operations,
    "operation_id" => :operation_id,
    "type" => :type,
    "group_id" => :group_id,
    "guest_id" => :guest_id,
    "property_id" => :property_id,
    "occurred_on" => :occurred_on,
    "arrival_on" => :arrival_on,
    "departure_on" => :departure_on,
    "new_arrival_on" => :new_arrival_on,
    "rate_plan" => :rate_plan,
    "rooms" => :rooms,
    "room_id" => :room_id,
    "nightly_rate_cents" => :nightly_rate_cents,
    "amount_cents" => :amount_cents,
    "expected_revision" => :expected_revision
  }

  @doc """
  Applies the operations in a partner batch in order.

  Each operation has its own transaction so a rejected operation cannot undo an
  earlier success or prevent later operations from being processed.
  """
  def process_batch(params) do
    case field(params, "operations") do
      operations when is_list(operations) ->
        %{results: Enum.map(operations, &process_operation/1)}

      _ ->
        {:error, :invalid_batch}
    end
  end

  @doc "Returns the public representation of a group, or `nil`."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> public_group(group)
    end
  end

  def get_group(_group_id), do: nil

  @doc "Returns the current finance totals."
  def ledger do
    case Repo.get(Ledger, 1) do
      nil -> %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0}
      ledger -> public_ledger(ledger)
    end
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = field(operation, "operation_id")
    type = field(operation, "type")

    cond do
      not valid_identifier?(operation_id) -> rejected(operation_id, "invalid_operation")
      type not in @operation_types -> rejected(operation_id, "invalid_operation")
      type == "open_group" -> process_open_group(operation, operation_id)
      true -> process_group_operation(operation, operation_id, type)
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_open_group(operation, operation_id) do
    group_id = field(operation, "group_id")

    cond do
      not valid_identifier?(group_id) ->
        rejected(operation_id, "invalid_operation")

      not valid_identifier?(field(operation, "guest_id")) ->
        rejected(operation_id, "invalid_operation")

      not valid_identifier?(field(operation, "property_id")) ->
        rejected(operation_id, "invalid_operation")

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation")

      true ->
        Repo.transaction(
          fn ->
            if Repo.get(Group, group_id) do
              rejected(operation_id, "group_already_exists", %{group_id: group_id})
            else
              apply_open_group(operation, operation_id, group_id)
            end
          end,
          mode: :immediate
        )
        |> transaction_result()
    end
  end

  defp apply_open_group(operation, operation_id, group_id) do
    with {:ok, booked_on} <- parse_date(field(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(field(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)

      room_rows =
        Enum.map(rooms, fn room ->
          lodging_total_cents = nights * room.nightly_rate_cents

          deposit_due_cents =
            case field(operation, "rate_plan") do
              "advance_purchase" -> lodging_total_cents
              "flexible" -> round_half_up(lodging_total_cents * 20, 100)
            end

          Map.merge(room, %{
            lodging_total_cents: lodging_total_cents,
            deposit_due_cents: deposit_due_cents
          })
        end)

      deposit_due_cents = Enum.reduce(room_rows, 0, &(&1.deposit_due_cents + &2))

      group = %Group{
        group_id: group_id,
        guest_id: field(operation, "guest_id"),
        property_id: field(operation, "property_id"),
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: field(operation, "rate_plan"),
        status: "active",
        revision: 1,
        lodging_total_cents: Enum.reduce(room_rows, 0, &(&1.lodging_total_cents + &2)),
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0
      }

      Repo.insert!(group)

      Enum.each(Enum.with_index(room_rows), fn {room, position} ->
        Repo.insert!(%GroupRoom{
          group_id: group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        })
      end)

      applied(operation_id, %{
        group_id: group_id,
        deposit_due_cents: deposit_due_cents,
        revision: 1
      })
    else
      {:error, :invalid_stay} ->
        rejected(operation_id, "invalid_stay", %{group_id: group_id})

      {:error, :invalid_rooms} ->
        rejected(operation_id, "invalid_rooms", %{group_id: group_id})

      {:error, :invalid_rate_plan} ->
        rejected(operation_id, "invalid_rate_plan", %{group_id: group_id})
    end
  end

  defp process_group_operation(operation, operation_id, type) do
    group_id = field(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      Repo.transaction(
        fn ->
          case Repo.get(Group, group_id) do
            nil ->
              rejected(operation_id, "group_not_found", %{group_id: group_id})

            group ->
              case check_expected_revision(operation, group, operation_id) do
                :ok ->
                  apply_group_operation(operation, operation_id, type, group)

                rejection ->
                  rejection
              end
          end
        end,
        mode: :immediate
      )
      |> transaction_result()
    end
  end

  defp check_expected_revision(operation, group, operation_id) do
    case field(operation, "expected_revision") do
      nil ->
        :ok

      expected_revision when expected_revision === group.revision ->
        :ok

      expected_revision ->
        rejected(operation_id, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })
    end
  end

  defp apply_group_operation(operation, operation_id, "record_cash_payment", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_payment_amount?(field(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", %{group_id: group.group_id})

      field(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        amount_cents = field(operation, "amount_cents")
        outstanding_deposit_cents = outstanding_deposit(group) - amount_cents
        update_group!(group, %{deposit_paid_cents: group.deposit_paid_cents + amount_cents})
        update_ledger!(cash_held_cents: ledger().cash_held_cents + amount_cents)

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount_cents,
          outstanding_deposit_cents: outstanding_deposit_cents,
          revision: group.revision + 1
        })
    end
  end

  defp apply_group_operation(operation, operation_id, "reschedule_group", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      true ->
        with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
             {:ok, new_arrival_on} <- parse_date(field(operation, "new_arrival_on")),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          nights = Date.diff(group.departure_on, group.arrival_on)
          new_departure_on = Date.add(new_arrival_on, nights)
          update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

          applied(operation_id, %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            revision: group.revision + 1
          })
        else
          _ -> rejected(operation_id, "invalid_stay", %{group_id: group.group_id})
        end
    end
  end

  defp apply_group_operation(operation, operation_id, "cancel_group", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      true ->
        case parse_date(field(operation, "occurred_on")) do
          {:ok, occurred_on} ->
            refundable? =
              group.rate_plan == "flexible" and
                Date.diff(group.arrival_on, occurred_on) >= 14

            paid_cents = group.deposit_paid_cents

            {refunded_cents, retained_cents} =
              if refundable?, do: {paid_cents, 0}, else: {0, paid_cents}

            update_group!(group, %{status: "cancelled"})

            update_ledger!(
              cash_held_cents: ledger().cash_held_cents - paid_cents,
              cash_refunded_cents: ledger().cash_refunded_cents + refunded_cents,
              cash_retained_cents: ledger().cash_retained_cents + retained_cents
            )

            applied(operation_id, %{
              group_id: group.group_id,
              refunded_cents: refunded_cents,
              retained_cents: retained_cents,
              revision: group.revision + 1
            })

          {:error, :invalid_stay} ->
            rejected(operation_id, "invalid_stay", %{group_id: group.group_id})
        end
    end
  end

  defp update_group!(%Group{} = group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp update_ledger!(changes) do
    ledger = ensure_ledger!()

    ledger
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp ensure_ledger! do
    Repo.get(Ledger, 1) || Repo.insert!(%Ledger{id: 1})
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, result}), do: result

  defp validate_stay({:ok, arrival_on}, {:ok, departure_on}) do
    validate_stay(arrival_on, departure_on)
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: field(room, "room_id"), nightly_rate_cents: field(room, "nightly_rate_cents")}
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp valid_room?(room) when is_map(room) do
    valid_identifier?(field(room, "room_id")) and
      is_integer(field(room, "nightly_rate_cents")) and field(room, "nightly_rate_cents") > 0
  end

  defp valid_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, &field(&1, "room_id"))
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp valid_payment_amount?(amount_cents),
    do: is_integer(amount_cents) and amount_cents > 0

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_stay}

  defp valid_operation_date?(value) do
    match?({:ok, _date}, parse_date(value))
  end

  defp public_group(group) do
    rooms =
      GroupRoom
      |> where([room], room.group_id == ^group.group_id)
      |> order_by([room], asc: room.position)
      |> Repo.all()

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms: Enum.map(rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp public_ledger(ledger) do
    %{
      cash_held_cents: ledger.cash_held_cents,
      cash_refunded_cents: ledger.cash_refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents
    }
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejected(operation_id, code, fields \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@key_atoms, key))
    end
  end

  defp field(_map, _key), do: nil

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
end
