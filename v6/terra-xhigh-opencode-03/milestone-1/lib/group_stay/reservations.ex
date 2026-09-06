defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @rate_plans ["flexible", "advance_purchase"]

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def fetch_group(group_id) when is_binary(group_id) do
    case group_by_partner_id(group_id) do
      nil -> :not_found
      group -> {:ok, group_payload(group)}
    end
  end

  def fetch_group(_), do: :not_found

  def ledger do
    totals =
      Repo.one(
        from group in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    group.status,
                    group.deposit_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(group.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.retained_cents), 0)
          }
      )

    totals || %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0}
  end

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      operation
      |> with_group_lock(fn ->
        case Repo.transaction(fn -> dispatch(operation) end) do
          {:ok, result} -> result
          {:error, result} -> result
        end
      end)
      |> Map.put("operation_id", operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_operation(_), do: rejected(nil, "invalid_operation")

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)

  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp dispatch(_), do: rollback("invalid_operation")

  defp open_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         nil <- group_by_partner_id(group_id),
         {:ok, attrs, room_attrs} <- opening_attrs(operation, group_id),
         {:ok, group} <- Repo.insert(Group.changeset(%Group{}, attrs)),
         :ok <- insert_rooms(group, room_attrs) do
      applied(%{
        "group_id" => group.group_id,
        "deposit_due_cents" => group.deposit_due_cents,
        "revision" => group.revision
      })
    else
      %Group{} -> rollback("group_already_exists", group_result(operation))
      {:error, code} when is_binary(code) -> rollback(code)
      {:error, %Ecto.Changeset{}} -> rollback("group_already_exists", group_result(operation))
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, _occurred_on} <- operation_date(operation),
         {:ok, amount} <- positive_amount(operation, "amount_cents"),
         :ok <- payment_within_outstanding?(group, amount),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        rollback("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        rollback("invalid_operation")

      {:error, :invalid_operation_date} ->
        rollback("invalid_operation", group_result(operation))

      {:error, :invalid_amount} ->
        rollback("invalid_amount", group_result(operation))

      {:error, :payment_exceeds_outstanding} ->
        rollback("payment_exceeds_outstanding", group_result(operation))

      {:error, %Ecto.Changeset{}} ->
        rollback("invalid_operation")

      {:stale, details} ->
        rollback("stale_revision", details)

      :inactive ->
        rollback("group_not_active", group_result(operation))
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, new_arrival_on} <- date_value(operation, "new_arrival_on"),
         :ok <- future_arrival?(new_arrival_on, occurred_on),
         new_departure_on <-
           Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
        "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} -> rollback("group_not_found", group_result(operation))
      {:error, :invalid_identifier} -> rollback("invalid_operation")
      {:error, :invalid_operation_date} -> rollback("invalid_operation", group_result(operation))
      {:error, :invalid_stay} -> rollback("invalid_stay", group_result(operation))
      {:error, %Ecto.Changeset{}} -> rollback("invalid_operation")
      {:stale, details} -> rollback("stale_revision", details)
      :inactive -> rollback("group_not_active", group_result(operation))
    end
  end

  defp cancel_group(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {refunded_cents, retained_cents} <- cancellation_settlement(group, occurred_on),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             status: "cancelled",
             deposit_due_cents: 0,
             deposit_paid_cents: 0,
             refunded_cents: group.refunded_cents + refunded_cents,
             retained_cents: group.retained_cents + retained_cents,
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "refunded_cents" => refunded_cents,
        "retained_cents" => retained_cents,
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} -> rollback("group_not_found", group_result(operation))
      {:error, :invalid_identifier} -> rollback("invalid_operation")
      {:error, :invalid_operation_date} -> rollback("invalid_operation", group_result(operation))
      {:error, %Ecto.Changeset{}} -> rollback("invalid_operation")
      {:stale, details} -> rollback("stale_revision", details)
      :inactive -> rollback("group_not_active", group_result(operation))
    end
  end

  defp opening_attrs(operation, group_id) do
    with {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- date_value(operation, "arrival_on"),
         {:ok, departure_on} <- date_value(operation, "departure_on"),
         :ok <- valid_stay?(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
           rooms(operation, arrival_on, departure_on, rate_plan) do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         status: "active",
         lodging_total_cents: lodging_total_cents,
         deposit_due_cents: deposit_due_cents,
         deposit_paid_cents: 0,
         refunded_cents: 0,
         retained_cents: 0,
         revision: 1
       }, rooms}
    else
      {:error, :invalid_operation_date} -> {:error, "invalid_operation"}
      {:error, :invalid_stay} -> {:error, "invalid_stay"}
      {:error, :invalid_rate_plan} -> {:error, "invalid_rate_plan"}
      {:error, :invalid_rooms} -> {:error, "invalid_rooms"}
      {:error, :invalid_identifier} -> {:error, "invalid_operation"}
    end
  end

  defp group_for_operation(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      case group_by_partner_id(group_id) do
        nil -> {:error, :not_found}
        group -> {:ok, group}
      end
    end
  end

  defp group_by_partner_id(group_id) do
    Repo.one(
      from group in Group,
        where: group.group_id == ^group_id,
        preload: [rooms: ^from(room in Room, order_by: room.position)]
    )
  end

  defp insert_rooms(group, room_attrs) do
    Enum.reduce_while(room_attrs, :ok, fn room_attrs, :ok ->
      attrs = Map.put(room_attrs, :group_db_id, group.id)

      case Repo.insert(Room.changeset(%Room{}, attrs)) do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp rooms(%{"rooms" => rooms}, arrival_on, departure_on, rate_plan)
       when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({[], MapSet.new(), 0, 0}, fn {room, position},
                                                      {attrs, room_ids, lodging_total,
                                                       deposit_total} ->
      case room_attrs(room, position, room_ids, nights, rate_plan) do
        {:ok, room_attrs, room_id, lodging_cents, deposit_cents} ->
          {:cont,
           {[room_attrs | attrs], MapSet.put(room_ids, room_id), lodging_total + lodging_cents,
            deposit_total + deposit_cents}}

        {:error, :invalid_rooms} ->
          {:halt, :invalid_rooms}
      end
    end)
    |> case do
      :invalid_rooms ->
        {:error, :invalid_rooms}

      {attrs, _room_ids, lodging_total, deposit_total} ->
        {:ok, Enum.reverse(attrs), lodging_total, deposit_total}
    end
  end

  defp rooms(_, _, _, _), do: {:error, :invalid_rooms}

  defp room_attrs(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position,
         room_ids,
         nights,
         rate_plan
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents >= 0 do
    if MapSet.member?(room_ids, room_id) do
      {:error, :invalid_rooms}
    else
      lodging_cents = nights * nightly_rate_cents
      deposit_cents = deposit_for(lodging_cents, rate_plan)

      {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position},
       room_id, lodging_cents, deposit_cents}
    end
  end

  defp room_attrs(_, _, _, _, _), do: {:error, :invalid_rooms}

  defp deposit_for(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, "advance_purchase"), do: lodging_cents

  defp rate_plan(%{"rate_plan" => rate_plan}) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp rate_plan(_), do: {:error, :invalid_rate_plan}

  defp valid_stay?(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp future_arrival?(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp positive_amount(operation, key) do
    case Map.get(operation, key) do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp payment_within_outstanding?(group, amount) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, :payment_exceeds_outstanding}
  end

  defp active?(%Group{status: "active"}), do: :ok
  defp active?(_), do: :inactive

  defp revision_matches?(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:stale,
           %{
             "group_id" => group.group_id,
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end

      {:ok, _} ->
        {:error, :invalid_identifier}
    end
  end

  defp operation_date(operation) do
    case date_value(operation, "occurred_on") do
      {:ok, date} -> {:ok, date}
      {:error, :invalid_stay} -> {:error, :invalid_operation_date}
    end
  end

  defp date_value(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, :invalid_stay}
        end

      _ ->
        {:error, :invalid_stay}
    end
  end

  defp required_identifier(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_identifier}
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp cancellation_settlement(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp cancellation_settlement(group, _occurred_on), do: {0, group.deposit_paid_cents}

  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  # Serializing a group's operations makes revision checks and writes a single critical section.
  defp with_group_lock(operation, fun) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and group_id != "" ->
        :global.trans({__MODULE__, group_id}, fun)

      _ ->
        fun.()
    end
  end

  defp group_payload(group) do
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
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp applied(fields), do: Map.merge(%{"status" => "applied"}, fields)

  defp rollback(code, fields \\ %{}), do: Repo.rollback(rejected(nil, code, fields))

  defp rejected(operation_id, code, fields \\ %{}) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    |> Map.merge(fields)
  end

  defp group_result(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) -> %{"group_id" => group_id}
      _ -> %{}
    end
  end
end
