defmodule GroupStay.Operations do
  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.{Group, Repo, Room}

  @valid_rate_plans ["flexible", "advance_purchase"]

  def process_batch(params) when is_map(params) do
    operations = field(params, "operations")

    if is_list(operations) do
      {:ok, Enum.map(operations, &process_operation/1)}
    else
      {:error, :invalid_batch}
    end
  end

  def process_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group_payload(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger do
    %{
      "cash_held_cents" => sum_active(:deposit_paid_cents),
      "cash_refunded_cents" => sum_cancelled(:refunded_cents),
      "cash_retained_cents" => sum_cancelled(:retained_cents)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = field(operation, "operation_id")

    case field(operation, "type") do
      "open_group" -> process_open(operation, operation_id)
      "record_cash_payment" -> process_existing(operation, operation_id, :payment)
      "reschedule_group" -> process_existing(operation, operation_id, :reschedule)
      "cancel_group" -> process_existing(operation, operation_id, :cancel)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_open(operation, operation_id) do
    if valid_identifier?(operation_id) and required_fields?(operation, open_fields()) do
      group_id = field(operation, "group_id")

      if valid_identifier?(group_id) do
        transaction(group_id, fn -> open_group(operation, operation_id, group_id) end)
      else
        rejected(operation_id, "invalid_operation")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp open_group(operation, operation_id, group_id) do
    if Repo.get(Group, group_id) do
      rejected(operation_id, "group_already_exists")
    else
      case validate_open(operation) do
        {:ok, group_attrs, rooms} ->
          group = Repo.insert!(struct(Group, group_attrs))

          Repo.insert_all(Room, Enum.map(rooms, &Map.put(&1, :group_id, group_id)))

          applied(operation_id, %{
            "group_id" => group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })

        {:error, code} ->
          rejected(operation_id, code)
      end
    end
  end

  defp process_existing(operation, operation_id, kind) do
    group_id = field(operation, "group_id")

    if valid_identifier?(operation_id) and valid_identifier?(group_id) do
      transaction(group_id, fn -> existing_operation(operation, operation_id, group_id, kind) end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp existing_operation(operation, operation_id, group_id, kind) do
    case Repo.get(Group, group_id) do
      nil ->
        rejected(operation_id, "group_not_found")

      group ->
        case revision_check(operation, group) do
          :ok ->
            apply_existing(group, operation, operation_id, kind)

          {:stale, expected_revision} ->
            rejected(operation_id, "stale_revision", %{
              "group_id" => group_id,
              "expected_revision" => expected_revision,
              "actual_revision" => group.revision
            })

          :invalid ->
            rejected(operation_id, "invalid_operation")
        end
    end
  end

  defp apply_existing(group, operation, operation_id, :payment) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with :ok <- validate_common_date(operation),
           {:ok, amount_cents} <- validate_payment_amount(operation),
           outstanding when amount_cents <= outstanding <- outstanding(group) do
        updated =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount_cents
          })

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding(updated),
          "revision" => updated.revision
        })
      else
        {:error, code} ->
          rejected(operation_id, code)

        _ ->
          rejected(operation_id, "payment_exceeds_outstanding")
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :reschedule) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      case validate_reschedule(operation, group) do
        {:ok, new_arrival_on, new_departure_on} ->
          updated =
            update_group!(group, %{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on
            })

          applied(operation_id, %{
            "group_id" => group.group_id,
            "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated.departure_on),
            "revision" => updated.revision
          })

        {:error, code} ->
          rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :cancel) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      case validate_common_date(operation) do
        :ok ->
          {refunded_cents, retained_cents} = cancellation_settlement(group, operation)

          updated =
            update_group!(group, %{
              status: "cancelled",
              refunded_cents: refunded_cents,
              retained_cents: retained_cents
            })

          applied(operation_id, %{
            "group_id" => group.group_id,
            "refunded_cents" => refunded_cents,
            "retained_cents" => retained_cents,
            "revision" => updated.revision
          })

        {:error, code} ->
          rejected(operation_id, code)
      end
    end
  end

  defp validate_open(operation) do
    with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_identifier_fields(operation),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")),
         :ok <- validate_rate_plan(field(operation, "rate_plan")) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total_cents = Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * nights + &2))

      deposit_due_cents =
        case field(operation, "rate_plan") do
          "advance_purchase" ->
            lodging_total_cents

          "flexible" ->
            Enum.reduce(rooms, 0, &(round_percentage(&1.nightly_rate_cents * nights, 20) + &2))
        end

      group_attrs = %{
        group_id: field(operation, "group_id"),
        guest_id: field(operation, "guest_id"),
        property_id: field(operation, "property_id"),
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: field(operation, "rate_plan"),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0
      }

      room_attrs =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          %{
            position: position,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents
          }
        end)

      {:ok, group_attrs, room_attrs}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp validate_identifier_fields(operation) do
    if valid_identifier?(field(operation, "group_id")) and
         valid_identifier?(field(operation, "guest_id")) and
         valid_identifier?(field(operation, "property_id")) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(rooms, {:ok, MapSet.new(), []}, fn room, {:ok, ids, valid_rooms} ->
      room_id = if is_map(room), do: field(room, "room_id"), else: nil
      nightly_rate_cents = if is_map(room), do: field(room, "nightly_rate_cents"), else: nil

      if valid_identifier?(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 and
           not MapSet.member?(ids, room_id) do
        {:cont,
         {:ok, MapSet.put(ids, room_id),
          valid_rooms ++ [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents}]}}
      else
        {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, _ids, valid_rooms} -> {:ok, valid_rooms}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @valid_rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_common_date(operation) do
    if has_field?(operation, "occurred_on") do
      case parse_date(field(operation, "occurred_on")) do
        {:ok, _date} -> :ok
        {:error, code} -> {:error, code}
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_payment_amount(operation) do
    if has_field?(operation, "amount_cents") do
      case field(operation, "amount_cents") do
        amount_cents when is_integer(amount_cents) and amount_cents > 0 -> {:ok, amount_cents}
        _ -> {:error, "invalid_amount"}
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_reschedule(operation, %Group{} = group) do
    if not has_field?(operation, "occurred_on") or not has_field?(operation, "new_arrival_on") do
      {:error, "invalid_operation"}
    else
      with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
           {:ok, new_arrival_on} <- parse_date(field(operation, "new_arrival_on")) do
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          {:ok, new_arrival_on, Date.add(new_arrival_on, stay_length)}
        else
          {:error, "invalid_stay"}
        end
      else
        {:error, _code} -> {:error, "invalid_stay"}
      end
    end
  end

  defp cancellation_settlement(group, operation) do
    paid = group.deposit_paid_cents

    if group.rate_plan == "flexible" and
         Date.diff(group.arrival_on, parse_date!(field(operation, "occurred_on"))) >= 14 do
      {paid, 0}
    else
      {0, paid}
    end
  end

  defp outstanding(%Group{status: "active", deposit_due_cents: due, deposit_paid_cents: paid}),
    do: due - paid

  defp outstanding(%Group{}), do: 0

  defp update_group!(group, attrs) do
    group
    |> Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp group_payload(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.position
      )

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
      "rooms" =>
        Enum.map(
          rooms,
          &%{"room_id" => &1.room_id, "nightly_rate_cents" => &1.nightly_rate_cents}
        ),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  defp sum_active(field) do
    Repo.one(
      from group in Group,
        where: group.status == "active",
        select: coalesce(sum(field(group, ^field)), 0)
    )
  end

  defp sum_cancelled(field) do
    Repo.one(
      from group in Group,
        where: group.status == "cancelled",
        select: coalesce(sum(field(group, ^field)), 0)
    )
  end

  defp transaction(group_id, fun) do
    :global.trans({__MODULE__, group_id}, fn ->
      {:ok, result} = Repo.transaction(fun)
      result
    end)
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

  defp rejected(operation_id, code, fields \\ %{}),
    do:
      Map.merge(%{"operation_id" => operation_id, "status" => "rejected", "code" => code}, fields)

  defp revision_check(operation, group) do
    case expected_revision(operation) do
      :absent -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:stale, expected_revision}
      :invalid -> :invalid
    end
  end

  defp expected_revision(operation) do
    if has_field?(operation, "expected_revision") do
      case field(operation, "expected_revision") do
        revision when is_integer(revision) -> {:ok, revision}
        _ -> :invalid
      end
    else
      :absent
    end
  end

  defp required_fields?(operation, fields), do: Enum.all?(fields, &has_field?(operation, &1))

  defp open_fields do
    [
      "operation_id",
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]
  end

  defp has_field?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp parse_date!(value) do
    {:ok, date} = parse_date(value)
    date
  end

  defp round_percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)
end
