defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.{Group, Repo, Room}

  @open_fields [
    "group_id",
    "guest_id",
    "property_id",
    "occurred_on",
    "arrival_on",
    "departure_on",
    "rate_plan",
    "rooms"
  ]

  @doc "Processes a partner batch in order, isolating each operation's changes."
  def process_batch(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, rooms: from(room in Room, order_by: room.position))
    end
  end

  def get_group(_group_id), do: nil

  def group_data(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "revision" => group.revision,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  def ledger do
    %{
      "cash_held_cents" => total(:deposit_paid_cents, status: "active"),
      "cash_refunded_cents" => total(:cash_refunded_cents),
      "cash_retained_cents" => total(:cash_retained_cents)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    if is_binary(Map.get(operation, "operation_id")) do
      case Map.get(operation, "type") do
        "open_group" -> transaction(operation, &open_group/1)
        "record_cash_payment" -> transaction(operation, &record_cash_payment/1)
        "reschedule_group" -> transaction(operation, &reschedule_group/1)
        "cancel_group" -> transaction(operation, &cancel_group/1)
        _ -> rejection(operation, "invalid_operation")
      end
    else
      rejection(operation, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejection(%{}, "invalid_operation")

  defp transaction(operation, work) do
    case Repo.transaction(fn ->
           case work.(operation) do
             {:ok, result} -> result
             {:retry} -> Repo.rollback(:retry)
             {:error, code, fields} -> Repo.rollback({code, fields})
           end
         end) do
      {:ok, result} -> result
      {:error, :retry} -> transaction(operation, work)
      {:error, {code, fields}} -> rejection(operation, code, fields)
    end
  end

  defp open_group(operation) do
    with :ok <- validate_open_input(operation),
         :ok <- ensure_group_available(operation),
         {:ok, dates} <- open_dates(operation),
         :ok <- validate_rate_plan(operation),
         {:ok, rooms, lodging_total, deposit_due} <- open_rooms(operation, dates.nights) do
      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: dates.booked_on,
        arrival_on: dates.arrival_on,
        departure_on: dates.departure_on,
        rate_plan: operation["rate_plan"],
        status: "active",
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        revision: 1
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          case insert_rooms(group, rooms) do
            :ok ->
              {:ok,
               applied(operation, %{
                 "group_id" => group.group_id,
                 "deposit_due_cents" => group.deposit_due_cents,
                 "revision" => group.revision
               })}

            {:error, _changeset} ->
              {:error, "invalid_rooms", group_fields(operation)}
          end

        {:error, _changeset} ->
          {:error, "group_already_exists", group_fields(operation)}
      end
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         :ok <- validate_occurred_on(operation),
         {:ok, amount} <- payment_amount(operation),
         :ok <- ensure_payment_within_outstanding(group, amount),
         result <-
           update_group(
             group,
             %{deposit_paid_cents: group.deposit_paid_cents + amount},
             operation
           ) do
      case result do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "group_id" => updated_group.group_id,
             "amount_cents" => amount,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           })}

        {:retry} ->
          {:retry}

        {:error, code, fields} ->
          {:error, code, fields}
      end
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         {:ok, new_arrival_on} <- reschedule_date(operation),
         new_departure_on <-
           Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)),
         result <-
           update_group(
             group,
             %{arrival_on: new_arrival_on, departure_on: new_departure_on},
             operation
           ) do
      case result do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "group_id" => updated_group.group_id,
             "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
             "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
             "revision" => updated_group.revision
           })}

        {:retry} ->
          {:retry}

        {:error, code, fields} ->
          {:error, code, fields}
      end
    end
  end

  defp cancel_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         {:ok, occurred_on} <- cancellation_date(operation) do
      {refunded_cents, retained_cents} = cancellation_settlement(group, occurred_on)

      case update_group(
             group,
             %{
               status: "cancelled",
               deposit_due_cents: 0,
               cash_refunded_cents: refunded_cents,
               cash_retained_cents: retained_cents
             },
             operation
           ) do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "group_id" => updated_group.group_id,
             "refunded_cents" => refunded_cents,
             "retained_cents" => retained_cents,
             "revision" => updated_group.revision
           })}

        {:retry} ->
          {:retry}

        {:error, code, fields} ->
          {:error, code, fields}
      end
    end
  end

  defp validate_open_input(operation) do
    required_values? =
      Enum.all?(@open_fields, fn field ->
        Map.has_key?(operation, field) and not is_nil(operation[field])
      end)

    identifiers? =
      Enum.all?(["group_id", "guest_id", "property_id"], &is_binary(operation[&1]))

    if required_values? and identifiers?, do: :ok, else: {:error, "invalid_operation", %{}}
  end

  defp ensure_group_available(operation) do
    if Repo.exists?(from(group in Group, where: group.group_id == ^operation["group_id"])) do
      {:error, "group_already_exists", group_fields(operation)}
    else
      :ok
    end
  end

  defp open_dates(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok,
       %{
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         nights: Date.diff(departure_on, arrival_on)
       }}
    else
      _ -> {:error, "invalid_stay", group_fields(operation)}
    end
  end

  defp validate_rate_plan(%{"rate_plan" => rate_plan})
       when rate_plan in ["flexible", "advance_purchase"],
       do: :ok

  defp validate_rate_plan(operation), do: {:error, "invalid_rate_plan", group_fields(operation)}

  defp open_rooms(operation, nights) do
    case operation["rooms"] do
      rooms when is_list(rooms) and rooms != [] ->
        build_rooms(rooms, nights, operation["rate_plan"], group_fields(operation))

      _ ->
        {:error, "invalid_rooms", group_fields(operation)}
    end
  end

  defp build_rooms(rooms, nights, rate_plan, fields) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({[], MapSet.new(), 0, 0}, fn {room, position},
                                                      {built_rooms, ids, lodging_total,
                                                       deposit_due} ->
      case room_data(room, position, nights, rate_plan, ids) do
        {:ok, built_room, room_lodging, room_deposit} ->
          {:cont,
           {
             [built_room | built_rooms],
             MapSet.put(ids, built_room.room_id),
             lodging_total + room_lodging,
             deposit_due + room_deposit
           }}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {built_rooms, _ids, lodging_total, deposit_due} ->
        {:ok, Enum.reverse(built_rooms), lodging_total, deposit_due}

      :error ->
        {:error, "invalid_rooms", fields}
    end
  end

  defp room_data(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position,
         nights,
         rate_plan,
         ids
       )
       when is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents >= 0 do
    if MapSet.member?(ids, room_id) do
      :error
    else
      lodging = nights * nightly_rate_cents

      deposit =
        case rate_plan do
          "flexible" -> div(lodging * 20 + 50, 100)
          "advance_purchase" -> lodging
        end

      {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position},
       lodging, deposit}
    end
  end

  defp room_data(_room, _position, _nights, _rate_plan, _ids), do: :error

  defp insert_rooms(group, rooms) do
    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      case Repo.insert(Room.changeset(%Room{}, Map.put(room, :group_id, group.id))) do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp fetch_group(operation) do
    case operation["group_id"] do
      group_id when is_binary(group_id) ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, "group_not_found", group_fields(operation)}
          group -> {:ok, group}
        end

      _ ->
        {:error, "invalid_operation", %{}}
    end
  end

  defp check_expected_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      {:error, "stale_revision", stale_fields(operation, group.revision)}
    else
      :ok
    end
  end

  defp ensure_active(%Group{status: "active"}, _operation), do: :ok

  defp ensure_active(_group, operation),
    do: {:error, "group_not_active", group_fields(operation)}

  defp validate_occurred_on(operation) do
    if Map.has_key?(operation, "occurred_on") and
         match?({:ok, _}, parse_date(operation["occurred_on"])) do
      :ok
    else
      {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp payment_amount(operation) do
    case operation do
      %{"amount_cents" => amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      %{"amount_cents" => _amount} -> {:error, "invalid_amount", group_fields(operation)}
      _ -> {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp ensure_payment_within_outstanding(group, amount) do
    if amount <= outstanding_deposit(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding", %{"group_id" => group.group_id}}
    end
  end

  defp reschedule_date(operation) do
    if Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "new_arrival_on") do
      with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
           :gt <- Date.compare(new_arrival_on, occurred_on) do
        {:ok, new_arrival_on}
      else
        _ -> {:error, "invalid_stay", group_fields(operation)}
      end
    else
      {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp cancellation_date(operation) do
    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} -> {:ok, occurred_on}
      _ -> {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp cancellation_settlement(group, occurred_on) do
    if group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp update_group(group, attrs, operation) do
    {updated, _} =
      Repo.update_all(
        from(current_group in Group,
          where: current_group.id == ^group.id and current_group.revision == ^group.revision
        ),
        set: Map.to_list(attrs) ++ [revision: group.revision + 1]
      )

    if updated == 1 do
      {:ok, struct(group, Map.put(attrs, :revision, group.revision + 1))}
    else
      update_conflict(operation, group)
    end
  end

  defp update_conflict(operation, group) do
    if Map.has_key?(operation, "expected_revision") do
      actual_revision =
        case Repo.get_by(Group, group_id: group.group_id) do
          nil -> group.revision
          current_group -> current_group.revision
        end

      {:error, "stale_revision", stale_fields(operation, actual_revision)}
    else
      {:retry}
    end
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp total(field, filters \\ []) do
    query = from(group in Group, select: coalesce(sum(field(group, ^field)), 0))

    query =
      case Keyword.get(filters, :status) do
        nil -> query
        status -> from(group in query, where: group.status == ^status)
      end

    Repo.one(query)
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp applied(operation, fields) do
    Map.merge(
      %{
        "operation_id" => Map.get(operation, "operation_id"),
        "status" => "applied"
      },
      fields
    )
  end

  defp rejection(operation, code, fields \\ %{}) do
    Map.merge(fields, %{
      "operation_id" => Map.get(operation, "operation_id"),
      "status" => "rejected",
      "code" => code
    })
  end

  defp group_fields(operation) do
    case operation["group_id"] do
      group_id when is_binary(group_id) -> %{"group_id" => group_id}
      _ -> %{}
    end
  end

  defp stale_fields(operation, actual_revision) do
    group_fields(operation)
    |> Map.put("expected_revision", Map.get(operation, "expected_revision"))
    |> Map.put("actual_revision", actual_revision)
  end
end
