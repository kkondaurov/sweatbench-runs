defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @open_fields [
    "operation_id",
    "type",
    "occurred_on",
    "group_id",
    "guest_id",
    "property_id",
    "arrival_on",
    "departure_on",
    "rate_plan",
    "rooms"
  ]

  @common_fields ["operation_id", "type", "occurred_on"]

  @doc """
  Applies a partner batch in order. Each operation gets its own transaction so a
  rejection cannot undo an earlier operation or prevent later operations.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Applies one operation and returns the public result map."
  def process_operation(operation) when is_map(operation) do
    case field_value(operation, "type") do
      "open_group" -> transact(operation, &open_group/1)
      "record_cash_payment" -> transact(operation, &record_cash_payment/1)
      "reschedule_group" -> transact(operation, &reschedule_group/1)
      "cancel_group" -> transact(operation, &cancel_group/1)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  def process_operation(operation), do: rejected(operation, "invalid_operation")

  @doc "Returns a serialized group or a group_not_found error."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, %{code: "group_not_found"}}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, %{code: "group_not_found"}}

  @doc "Returns the current finance totals."
  def ledger_totals do
    Repo.all(
      from group in Group,
        select:
          {group.status, group.deposit_paid_cents, group.refunded_cents, group.retained_cents}
    )
    |> Enum.reduce(%{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0}, fn
      {"active", paid, _refunded, _retained}, totals ->
        %{totals | cash_held_cents: totals.cash_held_cents + paid}

      {_status, _paid, refunded, retained}, totals ->
        %{
          totals
          | cash_refunded_cents: totals.cash_refunded_cents + refunded,
            cash_retained_cents: totals.cash_retained_cents + retained
        }
    end)
  end

  defp transact(operation, callback) do
    case Repo.transaction(
           fn ->
             case callback.(operation) do
               {:ok, result} -> result
               {:error, code, details} -> Repo.rollback({:rejected, code, details})
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, {:rejected, code, details}} -> rejected(operation, code, details)
      {:error, _reason} -> rejected(operation, "invalid_operation")
    end
  end

  defp open_group(operation) do
    with :ok <- required_fields(operation, @open_fields),
         :ok <-
           valid_identifiers(operation, ["operation_id", "group_id", "guest_id", "property_id"]),
         {:ok, group_id} <- field(operation, "group_id") do
      case Repo.get(Group, group_id) do
        %Group{} -> error("group_already_exists", %{group_id: group_id})
        nil -> build_and_insert_group(operation)
      end
    end
  end

  defp build_and_insert_group(operation) do
    with {:ok, booked_on} <- parse_date(field_value(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field_value(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field_value(operation, "departure_on")),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- valid_rate_plan(field_value(operation, "rate_plan")),
         {:ok, room_data} <-
           parse_rooms(field_value(operation, "rooms"), arrival_on, departure_on, rate_plan),
         {:ok, group_id} <- field(operation, "group_id"),
         {:ok, guest_id} <- field(operation, "guest_id"),
         {:ok, property_id} <- field(operation, "property_id"),
         {:ok, group} <-
           insert_group(%{
             group_id: group_id,
             guest_id: guest_id,
             property_id: property_id,
             booked_on: booked_on,
             arrival_on: arrival_on,
             departure_on: departure_on,
             rate_plan: rate_plan,
             status: "active",
             revision: 1,
             lodging_total_cents: room_data.lodging_total_cents,
             deposit_due_cents: room_data.deposit_due_cents,
             deposit_paid_cents: 0,
             refunded_cents: 0,
             retained_cents: 0
           }),
         :ok <- insert_rooms(group.group_id, room_data.rooms) do
      applied(operation, %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- usable_amount(field_value(operation, "amount_cents")),
         outstanding <- outstanding_deposit(group),
         :ok <- within_outstanding(amount_cents, outstanding),
         {:ok, updated_group} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount_cents,
             revision: group.revision + 1
           }) do
      _ = occurred_on

      applied(operation, %{
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding - amount_cents,
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {:ok, new_arrival_on} <- parse_date(field_value(operation, "new_arrival_on")),
         :ok <- after_operation_date(new_arrival_on, occurred_on),
         day_shift <- Date.diff(new_arrival_on, group.arrival_on),
         new_departure_on <- Date.add(group.departure_on, day_shift),
         {:ok, updated_group} <-
           update_group(group, %{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: group.revision + 1
           }) do
      applied(operation, %{
        group_id: updated_group.group_id,
        new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
        new_departure_on: Date.to_iso8601(updated_group.departure_on),
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp cancel_group(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {refunded_cents, retained_cents} <- cancellation_settlement(group, occurred_on),
         {:ok, updated_group} <-
           update_group(group, %{
             status: "cancelled",
             refunded_cents: refunded_cents,
             retained_cents: retained_cents,
             revision: group.revision + 1
           }) do
      applied(operation, %{
        group_id: updated_group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp existing_group(operation) do
    with :ok <- required_fields(operation, ["group_id"]),
         :ok <- valid_identifiers(operation, ["group_id"]),
         {:ok, group_id} <- field(operation, "group_id") do
      case Repo.get(Group, group_id) do
        nil -> error("group_not_found", %{group_id: group_id})
        group -> {:ok, group}
      end
    end
  end

  defp common_operation(operation) do
    with :ok <- required_fields(operation, @common_fields),
         :ok <- valid_identifiers(operation, ["operation_id"]),
         {:ok, occurred_on} <- parse_date(field_value(operation, "occurred_on")) do
      {:ok, occurred_on}
    end
  end

  defp expected_revision(operation, group) do
    case field(operation, "expected_revision") do
      :missing ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        error("stale_revision", %{
          group_id: group.group_id,
          expected_revision: expected,
          actual_revision: group.revision
        })

      {:ok, _expected} ->
        error("invalid_operation")
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok

  defp active_group(%Group{group_id: group_id}),
    do: error("group_not_active", %{group_id: group_id})

  defp usable_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp usable_amount(_amount_cents), do: error("invalid_amount")

  defp within_outstanding(amount_cents, outstanding) when amount_cents <= outstanding, do: :ok
  defp within_outstanding(_amount_cents, _outstanding), do: error("payment_exceeds_outstanding")

  defp outstanding_deposit(%Group{
         status: "active",
         deposit_due_cents: due,
         deposit_paid_cents: paid
       }),
       do: due - paid

  defp outstanding_deposit(%Group{}), do: 0

  defp cancellation_settlement(
         %Group{rate_plan: "flexible", arrival_on: arrival_on, deposit_paid_cents: paid},
         occurred_on
       ) do
    if Date.diff(arrival_on, occurred_on) >= 14, do: {paid, 0}, else: {0, paid}
  end

  defp cancellation_settlement(%Group{deposit_paid_cents: paid}, _occurred_on), do: {0, paid}

  defp after_operation_date(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: error("invalid_stay")
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> error("invalid_stay")
    end
  end

  defp parse_date(_value), do: error("invalid_stay")

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: error("invalid_stay")
  end

  defp valid_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"],
    do: {:ok, rate_plan}

  defp valid_rate_plan(_rate_plan), do: error("invalid_rate_plan")

  defp parse_rooms(rooms, arrival_on, departure_on, rate_plan)
       when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    parsed =
      Enum.with_index(rooms)
      |> Enum.reduce_while(
        {:ok, %{rooms: [], room_ids: MapSet.new(), lodging_total_cents: 0, deposit_due_cents: 0}},
        fn
          {room, room_index}, {:ok, totals} when is_map(room) ->
            room_id = field_value(room, "room_id")
            nightly_rate_cents = field_value(room, "nightly_rate_cents")

            cond do
              not valid_identifier?(room_id) ->
                {:halt, error("invalid_rooms")}

              not (is_integer(nightly_rate_cents) and nightly_rate_cents > 0) ->
                {:halt, error("invalid_rooms")}

              MapSet.member?(totals.room_ids, room_id) ->
                {:halt, error("invalid_rooms")}

              true ->
                lodging_cents = nights * nightly_rate_cents

                deposit_cents =
                  case rate_plan do
                    "advance_purchase" -> lodging_cents
                    "flexible" -> round_percentage(lodging_cents, 20)
                  end

                room_attrs = %{
                  room_id: room_id,
                  nightly_rate_cents: nightly_rate_cents,
                  room_index: room_index
                }

                {:cont,
                 {:ok,
                  %{
                    rooms: [room_attrs | totals.rooms],
                    room_ids: MapSet.put(totals.room_ids, room_id),
                    lodging_total_cents: totals.lodging_total_cents + lodging_cents,
                    deposit_due_cents: totals.deposit_due_cents + deposit_cents
                  }}}
            end

          {_room, _room_index}, _totals ->
            {:halt, error("invalid_rooms")}
        end
      )

    case parsed do
      {:ok, totals} -> {:ok, %{totals | rooms: Enum.reverse(totals.rooms)}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp parse_rooms(_rooms, _arrival_on, _departure_on, _rate_plan), do: error("invalid_rooms")

  defp round_percentage(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
  end

  defp insert_group(attrs) do
    case Repo.insert(Group.changeset(%Group{}, attrs)) do
      {:ok, group} -> {:ok, group}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp insert_rooms(group_id, rooms) do
    rows = Enum.map(rooms, &Map.put(&1, :group_id, group_id))
    _ = Repo.insert_all(Room, rows)
    :ok
  end

  defp update_group(group, attrs) do
    case Repo.update(Group.changeset(group, attrs)) do
      {:ok, updated_group} -> {:ok, updated_group}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.room_index
      )

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
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp required_fields(operation, fields) do
    if Enum.all?(fields, fn key -> present?(operation, key) end),
      do: :ok,
      else: error("invalid_operation")
  end

  defp valid_identifiers(operation, fields) do
    if Enum.all?(fields, fn key -> valid_identifier?(field_value(operation, key)) end),
      do: :ok,
      else: error("invalid_operation")
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp present?(operation, key) do
    case field(operation, key) do
      {:ok, value} -> not is_nil(value)
      :missing -> false
    end
  end

  defp field(operation, key) when is_map(operation) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(operation, key) -> {:ok, Map.get(operation, key)}
      Map.has_key?(operation, atom_key) -> {:ok, Map.get(operation, atom_key)}
      true -> :missing
    end
  end

  defp field(_operation, _key), do: :missing

  defp field_value(operation, key) do
    case field(operation, key) do
      {:ok, value} -> value
      :missing -> nil
    end
  end

  defp error(code, details \\ %{}) do
    {:error, code, details}
  end

  defp applied(operation, details) do
    {:ok,
     Map.merge(
       %{operation_id: field_value(operation, "operation_id"), status: "applied"},
       details
     )}
  end

  defp rejected(operation, code, details \\ %{}) do
    Map.merge(
      %{operation_id: field_value(operation, "operation_id"), status: "rejected", code: code},
      details
    )
  end
end
