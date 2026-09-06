defmodule GroupStay.Groups do
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  def apply_operation(operation) when is_map(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  def apply_operation(_), do: rejected(%{}, "invalid_operation")

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        group
        |> Repo.preload(rooms: from(room in Room, order_by: room.position))
        |> serialize_group()
    end
  end

  def ledger do
    %{
      cash_held_cents: total_for("active", :deposit_paid_cents),
      cash_refunded_cents: total_for("cancelled", :refunded_cents),
      cash_retained_cents: total_for("cancelled", :retained_cents)
    }
  end

  defp open_group(operation) do
    with {:ok, booked_on} <- common_date(operation),
         {:ok, attributes, rooms} <- open_attributes(operation, booked_on) do
      transaction(fn ->
        if Repo.get_by(Group, group_id: attributes.group_id) do
          {:error, group_error(operation, "group_already_exists", attributes.group_id)}
        else
          case Repo.insert(Group.changeset(%Group{}, attributes)) do
            {:ok, group} ->
              room_rows = Enum.map(rooms, &Map.put(&1, :group_id, group.id))
              {room_count, _} = Repo.insert_all(Room, room_rows)

              if room_count == length(room_rows) do
                {:ok,
                 applied(operation, %{
                   group_id: group.group_id,
                   deposit_due_cents: group.deposit_due_cents,
                   revision: group.revision
                 })}
              else
                {:error, rejected(operation, "invalid_operation")}
              end

            {:error, changeset} ->
              if Keyword.has_key?(changeset.errors, :group_id) do
                {:error, group_error(operation, "group_already_exists", attributes.group_id)}
              else
                {:error, rejected(operation, "invalid_operation")}
              end
          end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, _occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        amount = operation["amount_cents"]

        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          not positive_integer?(amount) ->
            {:error, group_error(operation, "invalid_amount", group.group_id)}

          amount > group.deposit_due_cents - group.deposit_paid_cents ->
            {:error, group_error(operation, "payment_exceeds_outstanding", group.group_id)}

          true ->
            {:update, [deposit_paid_cents: group.deposit_paid_cents + amount],
             fn updated ->
               applied(operation, %{
                 group_id: updated.group_id,
                 amount_cents: amount,
                 outstanding_deposit_cents:
                   updated.deposit_due_cents - updated.deposit_paid_cents,
                 revision: updated.revision
               })
             end}
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp reschedule_group(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          true ->
            case parse_date(operation["new_arrival_on"]) do
              {:ok, new_arrival_on} ->
                if Date.compare(new_arrival_on, occurred_on) == :gt do
                  stay_length = Date.diff(group.departure_on, group.arrival_on)
                  new_departure_on = Date.add(new_arrival_on, stay_length)

                  {:update, [arrival_on: new_arrival_on, departure_on: new_departure_on],
                   fn updated ->
                     applied(operation, %{
                       group_id: updated.group_id,
                       new_arrival_on: date_string(updated.arrival_on),
                       new_departure_on: date_string(updated.departure_on),
                       revision: updated.revision
                     })
                   end}
                else
                  {:error, group_error(operation, "invalid_stay", group.group_id)}
                end

              _ ->
                {:error, group_error(operation, "invalid_stay", group.group_id)}
            end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp cancel_group(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        if group.status != "active" do
          {:error, group_error(operation, "group_not_active", group.group_id)}
        else
          refundable? =
            group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

          refunded_cents = if refundable?, do: group.deposit_paid_cents, else: 0
          retained_cents = if refundable?, do: 0, else: group.deposit_paid_cents

          {:update,
           [
             status: "cancelled",
             deposit_due_cents: 0,
             deposit_paid_cents: 0,
             refunded_cents: refunded_cents,
             retained_cents: retained_cents
           ],
           fn updated ->
             applied(operation, %{
               group_id: updated.group_id,
               refunded_cents: refunded_cents,
               retained_cents: retained_cents,
               revision: updated.revision
             })
           end}
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp apply_to_group(operation, group_id, action) do
    result =
      transaction(fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            {:error, group_error(operation, "group_not_found", group_id)}

          group ->
            if stale_revision?(operation, group) do
              {:error, stale_revision_error(operation, group)}
            else
              case action.(group) do
                {:error, result} ->
                  {:error, result}

                {:update, changes, result_builder} ->
                  case update_group(group, changes) do
                    {:ok, updated} ->
                      {:ok, result_builder.(updated)}

                    {:conflict, latest} ->
                      if has_expected_revision?(operation) do
                        {:error, stale_revision_error(operation, latest)}
                      else
                        {:error, :retry}
                      end
                  end
              end
            end
        end
      end)

    case result do
      :retry -> apply_to_group(operation, group_id, action)
      result -> result
    end
  end

  defp update_group(group, changes) do
    changeset =
      group
      |> change(changes)
      |> optimistic_lock(:revision)

    case Repo.update(changeset, stale_error_field: :revision) do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:conflict, Repo.get!(Group, group.id)}
    end
  end

  defp open_attributes(operation, booked_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         Enum.all?(["group_id", "guest_id", "property_id"], &valid_identifier?(operation[&1])) do
      with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
           {:ok, departure_on} <- parse_date(operation["departure_on"]),
           :ok <- valid_stay(arrival_on, departure_on),
           :ok <- valid_rate_plan(operation["rate_plan"]),
           {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
             build_rooms(
               operation["rooms"],
               Date.diff(departure_on, arrival_on),
               operation["rate_plan"]
             ) do
        {:ok,
         %{
           group_id: operation["group_id"],
           guest_id: operation["guest_id"],
           property_id: operation["property_id"],
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: operation["rate_plan"],
           status: "active",
           revision: 1,
           lodging_total_cents: lodging_total_cents,
           deposit_due_cents: deposit_due_cents,
           deposit_paid_cents: 0,
           refunded_cents: 0,
           retained_cents: 0
         }, rooms}
      else
        :invalid_stay ->
          {:error, group_error(operation, "invalid_stay", operation["group_id"])}

        :invalid_rate_plan ->
          {:error, group_error(operation, "invalid_rate_plan", operation["group_id"])}

        :invalid_rooms ->
          {:error, group_error(operation, "invalid_rooms", operation["group_id"])}

        _ ->
          {:error, group_error(operation, "invalid_stay", operation["group_id"])}
      end
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp build_rooms(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    room_data =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        if is_map(room) and valid_identifier?(room["room_id"]) and
             positive_integer?(room["nightly_rate_cents"]) do
          lodging_cents = room["nightly_rate_cents"] * nights

          %{
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position,
            lodging_cents: lodging_cents,
            deposit_cents: deposit_for(lodging_cents, rate_plan)
          }
        else
          :invalid
        end
      end)

    if :invalid in room_data or duplicate_room_ids?(room_data) do
      :invalid_rooms
    else
      lodging_total_cents = Enum.sum(Enum.map(room_data, & &1.lodging_cents))
      deposit_due_cents = Enum.sum(Enum.map(room_data, & &1.deposit_cents))

      room_rows =
        Enum.map(room_data, fn room ->
          Map.take(room, [:room_id, :nightly_rate_cents, :position])
        end)

      {:ok, room_rows, lodging_total_cents, deposit_due_cents}
    end
  end

  defp build_rooms(_, _, _), do: :invalid_rooms

  defp duplicate_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)
    length(room_ids) != MapSet.size(MapSet.new(room_ids))
  end

  defp deposit_for(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, "advance_purchase"), do: lodging_cents

  defp valid_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: :invalid_stay
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_), do: :invalid_rate_plan

  defp operation_group_id(operation) do
    if valid_identifier?(operation["group_id"]) do
      {:ok, operation["group_id"]}
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp common_date(operation) do
    with true <- valid_identifier?(operation["operation_id"]),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      {:ok, occurred_on}
    else
      _ -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp has_expected_revision?(operation), do: Map.has_key?(operation, "expected_revision")

  defp stale_revision?(operation, group) do
    has_expected_revision?(operation) and operation["expected_revision"] != group.revision
  end

  defp stale_revision_error(operation, group) do
    rejected(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    })
  end

  defp total_for(status, field) do
    Repo.aggregate(from(group in Group, where: group.status == ^status), :sum, field) || 0
  end

  defp serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: date_string(group.booked_on),
      arrival_on: date_string(group.arrival_on),
      departure_on: date_string(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  defp date_string(date), do: Date.to_iso8601(date)

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation, fields),
    do: Map.merge(base_result(operation), Map.put(fields, :status, "applied"))

  defp rejected(operation, code, fields \\ %{}) do
    base_result(operation)
    |> Map.merge(%{status: "rejected", code: code})
    |> Map.merge(fields)
  end

  defp group_error(operation, code, group_id),
    do: rejected(operation, code, %{group_id: group_id})

  defp base_result(operation) do
    case Map.fetch(operation, "operation_id") do
      {:ok, operation_id} -> %{operation_id: operation_id}
      :error -> %{}
    end
  end
end
