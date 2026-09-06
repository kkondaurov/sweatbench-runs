defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @rate_plans ["flexible", "advance_purchase"]

  def process(operation) when is_map(operation) do
    operation_id = operation["operation_id"]

    result =
      Repo.transact(fn ->
        case apply_operation(operation) do
          {:ok, fields} -> {:ok, Map.merge(%{"status" => "applied"}, fields)}
          {:error, fields} -> Repo.rollback(Map.merge(%{"status" => "rejected"}, fields))
        end
      end)

    fields =
      case result do
        {:ok, fields} -> fields
        {:error, fields} -> fields
      end

    Map.put(fields, "operation_id", operation_id)
  end

  def process(_operation),
    do: %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_group_id), do: nil

  def group_json(%Group{} = group) do
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
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  def ledger do
    active_cash =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.deposit_paid_cents), 0)
      )

    settlements =
      Repo.one(
        from g in Group,
          select: {coalesce(sum(g.refunded_cents), 0), coalesce(sum(g.retained_cents), 0)}
      )

    {refunded, retained} = settlements

    %{
      "cash_held_cents" => active_cash,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained
    }
  end

  defp apply_operation(
         %{"operation_id" => operation_id, "type" => type, "occurred_on" => occurred_on} = op
       )
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on) do
    with {:ok, date} <- Date.from_iso8601(occurred_on) do
      case type do
        "open_group" -> open_group(op, date)
        "record_cash_payment" -> with_group(op, &record_cash_payment(&1, op))
        "reschedule_group" -> with_group(op, &reschedule_group(&1, op, date))
        "cancel_group" -> with_group(op, &cancel_group(&1, date))
        _ -> reject("invalid_operation")
      end
    else
      _ -> reject("invalid_operation")
    end
  end

  defp apply_operation(_operation), do: reject("invalid_operation")

  defp open_group(op, booked_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(op, &1)) do
      do_open_group(op, booked_on)
    else
      reject("invalid_operation")
    end
  end

  defp do_open_group(op, booked_on) do
    with :ok <- validate_identifier(op["group_id"]),
         :ok <- validate_identifier(op["guest_id"]),
         :ok <- validate_identifier(op["property_id"]),
         :ok <- validate_group_is_new(op["group_id"]),
         {:ok, arrival_on} <- parse_date(op["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(op["departure_on"], "invalid_stay"),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on),
         :ok <- validate_rate_plan(op["rate_plan"]),
         {:ok, rooms} <- validate_rooms(op["rooms"]) do
      lodging_total = Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))

      deposit_due =
        Enum.sum_by(rooms, fn room ->
          lodging = room["nightly_rate_cents"] * nights
          if op["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        end)

      attrs = %{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: op["rate_plan"],
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          Enum.with_index(rooms)
          |> Enum.each(fn {room, position} ->
            room
            |> Map.put("position", position)
            |> Map.put("group_reservation_id", group.id)
            |> then(&Repo.insert!(Room.changeset(%Room{}, &1)))
          end)

          {:ok,
           %{
             "group_id" => group.group_id,
             "deposit_due_cents" => deposit_due,
             "revision" => 1
           }}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id),
            do: reject("group_already_exists"),
            else: reject("invalid_operation")
      end
    else
      {:error, code} -> reject(code)
      _ -> reject("invalid_stay")
    end
  end

  defp with_group(%{"group_id" => group_id} = op, callback)
       when is_binary(group_id) and group_id != "" do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject("group_not_found", %{"group_id" => group_id})

      group ->
        case check_revision(group, op) do
          :ok -> callback.(group)
          error -> error
        end
    end
  end

  defp with_group(_op, _callback), do: reject("invalid_operation")

  defp check_revision(group, %{"expected_revision" => expected}) when is_integer(expected) do
    if expected == group.revision do
      :ok
    else
      reject("stale_revision", %{
        "group_id" => group.group_id,
        "expected_revision" => expected,
        "actual_revision" => group.revision
      })
    end
  end

  defp check_revision(_group, %{"expected_revision" => _}), do: reject("invalid_operation")
  defp check_revision(_group, _op), do: :ok

  defp record_cash_payment(group, op) do
    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) ->
        reject("invalid_amount")

      op["amount_cents"] > outstanding(group) ->
        reject("payment_exceeds_outstanding")

      true ->
        amount = op["amount_cents"]
        updated = update_group!(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

        {:ok,
         %{
           "group_id" => group.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding(updated),
           "revision" => updated.revision
         }}
    end
  end

  defp reschedule_group(group, op, occurred_on) do
    cond do
      not Map.has_key?(op, "new_arrival_on") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      true ->
        with {:ok, new_arrival} <- parse_date(op["new_arrival_on"], "invalid_stay"),
             true <- Date.after?(new_arrival, occurred_on) do
          shift = Date.diff(new_arrival, group.arrival_on)
          new_departure = Date.add(group.departure_on, shift)
          updated = update_group!(group, %{arrival_on: new_arrival, departure_on: new_departure})

          {:ok,
           %{
             "group_id" => group.group_id,
             "new_arrival_on" => Date.to_iso8601(new_arrival),
             "new_departure_on" => Date.to_iso8601(new_departure),
             "revision" => updated.revision
           }}
        else
          _ -> reject("invalid_stay")
        end
    end
  end

  defp cancel_group(group, occurred_on) do
    if group.status == "active" do
      refundable =
        group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

      refunded = if refundable, do: group.deposit_paid_cents, else: 0
      retained = if refundable, do: 0, else: group.deposit_paid_cents

      updated =
        update_group!(group, %{
          status: "cancelled",
          refunded_cents: refunded,
          retained_cents: retained
        })

      {:ok,
       %{
         "group_id" => group.group_id,
         "refunded_cents" => refunded,
         "retained_cents" => retained,
         "revision" => updated.revision
       }}
    else
      reject("group_not_active", %{"group_id" => group.group_id})
    end
  end

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    unique = Enum.uniq_by(rooms, &Map.get(&1, "room_id")) == rooms
    if valid and unique, do: {:ok, rooms}, else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_identifier(value) when is_binary(value) and value != "", do: :ok
  defp validate_identifier(_value), do: {:error, "invalid_operation"}

  defp validate_group_is_new(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_value, code), do: {:error, code}

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0

  defp reject(code, fields \\ %{}), do: {:error, Map.put(fields, "code", code)}
end
