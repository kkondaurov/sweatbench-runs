defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @rate_plans ["flexible", "advance_purchase"]

  def submit(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        rooms = Repo.all(from r in Room, where: r.group_id == ^group_id, order_by: r.position)
        serialize_group(group, rooms)
    end
  end

  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            fragment(
              "COALESCE(SUM(CASE WHEN ? = 'active' THEN ? ELSE 0 END), 0)",
              g.status,
              g.deposit_paid_cents
            ),
          cash_refunded_cents: fragment("COALESCE(SUM(?), 0)", g.refunded_cents),
          cash_retained_cents: fragment("COALESCE(SUM(?), 0)", g.retained_cents)
        }
    )
  end

  defp process(%{"operation_id" => operation_id, "type" => type} = operation)
       when is_binary(operation_id) and operation_id != "" do
    case type do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> update_group(operation, &record_cash_payment/2)
      "reschedule_group" -> update_group(operation, &reschedule_group/2)
      "cancel_group" -> update_group(operation, &cancel_group/2)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp process(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with {:ok, fields} <- open_fields(operation),
         {:ok, booked_on} <- parse_required_date(fields.occurred_on, "invalid_operation"),
         {:ok, arrival_on} <- parse_required_date(fields.arrival_on, "invalid_stay"),
         {:ok, departure_on} <- parse_required_date(fields.departure_on, "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(fields.rate_plan),
         {:ok, rooms} <- validate_rooms(fields.rooms) do
      nights = Date.diff(departure_on, arrival_on)

      lodging_total_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          total + room.nightly_rate_cents * nights
        end)

      deposit_due_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          lodging = room.nightly_rate_cents * nights
          total + room_deposit(fields.rate_plan, lodging)
        end)

      attrs = %{
        group_id: fields.group_id,
        guest_id: fields.guest_id,
        property_id: fields.property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: fields.rate_plan,
        status: "active",
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        revision: 1
      }

      case Repo.transaction(fn -> insert_group(attrs, rooms) end, mode: :immediate) do
        {:ok, :ok} ->
          applied(operation, %{
            group_id: fields.group_id,
            deposit_due_cents: deposit_due_cents,
            revision: 1
          })

        {:error, :group_already_exists} ->
          reject(operation, "group_already_exists")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp insert_group(attrs, rooms) do
    case Repo.insert(Group.create_changeset(%Group{}, attrs)) do
      {:ok, _group} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            %{
              group_id: attrs.group_id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: position,
              inserted_at: now,
              updated_at: now
            }
          end)

        {_count, nil} = Repo.insert_all(Room, room_rows)
        :ok

      {:error, changeset} ->
        if changeset.errors[:group_id] do
          Repo.rollback(:group_already_exists)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp update_group(operation, apply_operation) do
    case operation do
      %{"group_id" => group_id} when is_binary(group_id) and group_id != "" ->
        {:ok, result} =
          Repo.transaction(
            fn ->
              case Repo.get(Group, group_id) do
                nil ->
                  reject(operation, "group_not_found")

                group ->
                  with :ok <- validate_expected_revision(operation, group),
                       :ok <- validate_active(group) do
                    apply_operation.(operation, group)
                  else
                    {:error, "stale_revision"} -> stale(operation, group)
                    {:error, code} -> reject(operation, code)
                  end
              end
            end,
            mode: :immediate
          )

        result

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp record_cash_payment(operation, group) do
    case operation do
      %{"occurred_on" => occurred_on, "amount_cents" => amount_cents} ->
        case parse_required_date(occurred_on, "invalid_operation") do
          {:ok, _occurred_on} ->
            outstanding = group.deposit_due_cents - group.deposit_paid_cents

            cond do
              not (is_integer(amount_cents) and amount_cents > 0) ->
                reject(operation, "invalid_amount")

              amount_cents > outstanding ->
                reject(operation, "payment_exceeds_outstanding")

              true ->
                revision = group.revision + 1
                paid = group.deposit_paid_cents + amount_cents

                group
                |> Group.update_changeset(%{deposit_paid_cents: paid, revision: revision})
                |> Repo.update!()

                applied(operation, %{
                  group_id: group.group_id,
                  amount_cents: amount_cents,
                  outstanding_deposit_cents: group.deposit_due_cents - paid,
                  revision: revision
                })
            end

          {:error, code} ->
            reject(operation, code)
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp reschedule_group(operation, group) do
    with %{"occurred_on" => occurred_on, "new_arrival_on" => new_arrival_on} <- operation,
         {:ok, occurred_on} <- parse_required_date(occurred_on, "invalid_stay"),
         {:ok, new_arrival_on} <- parse_required_date(new_arrival_on, "invalid_stay"),
         true <- Date.after?(new_arrival_on, occurred_on) do
      new_departure_on = Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))
      revision = group.revision + 1

      group
      |> Group.update_changeset(%{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        revision: revision
      })
      |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: new_arrival_on,
        new_departure_on: new_departure_on,
        revision: revision
      })
    else
      {:error, code} -> reject(operation, code)
      false -> reject(operation, "invalid_stay")
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp cancel_group(operation, group) do
    case operation do
      %{"occurred_on" => occurred_on} ->
        case parse_required_date(occurred_on, "invalid_operation") do
          {:ok, occurred_on} -> settle_cancellation(operation, group, occurred_on)
          {:error, code} -> reject(operation, code)
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp settle_cancellation(operation, group, occurred_on) do
    refundable =
      group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    {refunded_cents, retained_cents} =
      if refundable do
        {group.deposit_paid_cents, 0}
      else
        {0, group.deposit_paid_cents}
      end

    revision = group.revision + 1

    group
    |> Group.update_changeset(%{
      status: "cancelled",
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: revision
    })
    |> Repo.update!()

    applied(operation, %{
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: revision
    })
  end

  defp open_fields(operation) do
    required = [
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      {:ok,
       %{
         occurred_on: operation["occurred_on"],
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         arrival_on: operation["arrival_on"],
         departure_on: operation["departure_on"],
         rate_plan: operation["rate_plan"],
         rooms: operation["rooms"]
       }}
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    parsed =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}
        when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
               nightly_rate_cents > 0 ->
          %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}

        _ ->
          :invalid
      end)

    room_ids = Enum.map(parsed, &if(is_map(&1), do: &1.room_id, else: nil))

    if :invalid in parsed or length(Enum.uniq(room_ids)) != length(room_ids) do
      {:error, "invalid_rooms"}
    else
      {:ok, parsed}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_stay(arrival_on, departure_on) do
    if Date.before?(arrival_on, departure_on), do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, "invalid_rate_plan"}
  end

  defp validate_active(%Group{status: "active"}), do: :ok
  defp validate_active(_group), do: {:error, "group_not_active"}

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected > 0 ->
        if expected == group.revision, do: :ok, else: {:error, "stale_revision"}

      {:ok, _expected} ->
        {:error, "invalid_operation"}
    end
  end

  defp parse_required_date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, error_code}
    end
  end

  defp parse_required_date(_value, error_code), do: {:error, error_code}

  defp room_deposit("flexible", lodging_cents), do: div(lodging_cents * 20 + 50, 100)
  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp serialize_group(group, rooms) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents:
        if(group.status == "active",
          do: group.deposit_due_cents - group.deposit_paid_cents,
          else: 0
        )
    }
  end

  defp applied(operation, fields) do
    Map.merge(
      %{operation_id: operation["operation_id"], status: "applied"},
      fields
    )
  end

  defp reject(operation, code, fields \\ %{}) do
    operation_id = if is_map(operation), do: operation["operation_id"], else: nil

    Map.merge(
      %{operation_id: operation_id, status: "rejected", code: code},
      fields
    )
  end

  defp stale(operation, group) do
    reject(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    })
  end
end
