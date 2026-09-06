defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @active "active"
  @cancelled "cancelled"
  @refund_notice_days 14

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> preload_rooms()
  end

  def get_group(_), do: nil

  def serialize_group(%Group{} = group) do
    group = preload_rooms(group)

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
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents
    }
  end

  def ledger_totals do
    Group
    |> select([g], %{
      status: g.status,
      deposit_paid_cents: g.deposit_paid_cents,
      refunded_cents: g.refunded_cents,
      retained_cents: g.retained_cents
    })
    |> Repo.all()
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn group, acc ->
        held = if group.status == @active, do: group.deposit_paid_cents, else: 0

        %{
          cash_held_cents: acc.cash_held_cents + held,
          cash_refunded_cents: acc.cash_refunded_cents + group.refunded_cents,
          cash_retained_cents: acc.cash_retained_cents + group.retained_cents
        }
      end
    )
  end

  def room_deposit_cents(lodging_cents, @flexible), do: round_percent(lodging_cents, 20)
  def room_deposit_cents(lodging_cents, @advance_purchase), do: lodging_cents

  def round_percent(amount_cents, percent)
      when is_integer(amount_cents) and is_integer(percent) and amount_cents >= 0 do
    numerator = amount_cents * percent
    quotient = div(numerator, 100)
    remainder = rem(numerator, 100)

    if remainder >= 50, do: quotient + 1, else: quotient
  end

  defp apply_operation(operation) when is_map(operation) do
    operation = stringify_keys(operation)
    operation_id = Map.get(operation, "operation_id")

    try do
      case Repo.transaction(fn ->
             case dispatch(operation) do
               {:applied, fields} -> {:applied, fields}
               {:rejected, fields} -> Repo.rollback({:rejected, fields})
             end
           end) do
        {:ok, {:applied, fields}} ->
          applied(operation_id, fields)

        {:error, {:rejected, fields}} ->
          rejected(operation_id, fields)
      end
    rescue
      _ -> rejected(operation_id, %{code: "invalid_operation"})
    end
  end

  defp apply_operation(_) do
    %{status: "rejected", code: "invalid_operation"}
  end

  defp dispatch(operation) do
    case operation_type(operation) do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      _ -> reject("invalid_operation")
    end
  end

  defp operation_type(%{"type" => type}) when is_atom(type), do: Atom.to_string(type)
  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil

  defp open_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         :ok <- reject_if_exists(group_id),
         {:ok, guest_id} <- require_id(operation, "guest_id"),
         {:ok, property_id} <- require_id(operation, "property_id"),
         {:ok, booked_on} <- require_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- require_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- require_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay_length(arrival_on, departure_on),
         {:ok, rate_plan} <- require_rate_plan(operation),
         {:ok, rooms} <- parse_rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)

      rooms =
        Enum.map(rooms, fn room ->
          Map.put(room, :lodging_cents, nights * room.nightly_rate_cents)
        end)

      persist_open_group(%{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    end
  end

  defp persist_open_group(attrs) do
    lodging_total_cents =
      Enum.reduce(attrs.rooms, 0, fn room, acc -> acc + room.lodging_cents end)

    deposit_due_cents =
      Enum.reduce(attrs.rooms, 0, fn room, acc ->
        acc + room_deposit_cents(room.lodging_cents, attrs.rate_plan)
      end)

    group_attrs = %{
      group_id: attrs.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: attrs.booked_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      status: @active,
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      outstanding_deposit_cents: deposit_due_cents,
      refunded_cents: 0,
      retained_cents: 0
    }

    case %Group{} |> Group.changeset(group_attrs) |> Repo.insert() do
      {:ok, group} ->
        Enum.each(attrs.rooms, fn room ->
          %Room{}
          |> Room.changeset(%{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position,
            group_id: group.id
          })
          |> Repo.insert!()
        end)

        {:applied,
         %{
           group_id: attrs.group_id,
           deposit_due_cents: deposit_due_cents,
           revision: 1
         }}

      {:error, changeset} ->
        if unique_group_id_error?(changeset) do
          reject("group_already_exists")
        else
          reject("invalid_operation")
        end
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, amount_cents} <- require_payment_amount(operation) do
      if amount_cents > group.outstanding_deposit_cents do
        reject("payment_exceeds_outstanding")
      else
        revision = group.revision + 1
        outstanding = group.outstanding_deposit_cents - amount_cents

        group
        |> Group.changeset(%{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          outstanding_deposit_cents: outstanding,
          revision: revision
        })
        |> Repo.update!()

        {:applied,
         %{
           group_id: group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding,
           revision: revision
         }}
      end
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, occurred_on} <- require_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- require_date(operation, "new_arrival_on", "invalid_stay"),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)
      revision = group.revision + 1

      group
      |> Group.changeset(%{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        revision: revision
      })
      |> Repo.update!()

      {:applied,
       %{
         group_id: group_id,
         new_arrival_on: Date.to_iso8601(new_arrival_on),
         new_departure_on: Date.to_iso8601(new_departure_on),
         revision: revision
       }}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, occurred_on} <- require_date(operation, "occurred_on", "invalid_operation") do
      {refunded_cents, retained_cents} = settlement(group, occurred_on)
      revision = group.revision + 1

      group
      |> Group.changeset(%{
        status: @cancelled,
        outstanding_deposit_cents: 0,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: revision
      })
      |> Repo.update!()

      {:applied,
       %{
         group_id: group_id,
         refunded_cents: refunded_cents,
         retained_cents: retained_cents,
         revision: revision
       }}
    end
  end

  defp settlement(%Group{rate_plan: @flexible} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= @refund_notice_days do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp settlement(%Group{} = group, _occurred_on) do
    {0, group.deposit_paid_cents}
  end

  defp reject_if_exists(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      reject("group_already_exists")
    else
      :ok
    end
  end

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> reject("group_not_found")
      group -> {:ok, group}
    end
  end

  defp match_revision(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, expected} ->
        if expected == group.revision do
          :ok
        else
          {:rejected,
           %{
             code: "stale_revision",
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           }}
        end
    end
  end

  defp require_active(%Group{status: @active}), do: :ok
  defp require_active(_), do: reject("group_not_active")

  defp require_id(operation, field) do
    case Map.get(operation, field) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> reject("invalid_operation")
    end
  end

  defp require_date(operation, field, code) do
    case parse_date(Map.get(operation, field)) do
      {:ok, date} -> {:ok, date}
      :error -> reject(code)
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp validate_stay_length(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      reject("invalid_stay")
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      reject("invalid_stay")
    end
  end

  defp require_rate_plan(operation) do
    plan =
      case Map.get(operation, "rate_plan") do
        value when is_atom(value) -> Atom.to_string(value)
        value -> value
      end

    if plan in [@flexible, @advance_purchase] do
      {:ok, plan}
    else
      reject("invalid_rate_plan")
    end
  end

  defp parse_rooms(operation) do
    case Map.get(operation, "rooms") do
      rooms when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {room, index}, {:ok, acc} ->
          case parse_room(room, index) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:rejected, _} = rejected -> {:halt, rejected}
          end
        end)
        |> case do
          {:ok, parsed} ->
            parsed = Enum.reverse(parsed)
            room_ids = Enum.map(parsed, & &1.room_id)

            if room_ids == Enum.uniq(room_ids) do
              {:ok, parsed}
            else
              reject("invalid_rooms")
            end

          other ->
            other
        end

      _ ->
        reject("invalid_rooms")
    end
  end

  defp parse_room(room, position) when is_map(room) do
    room = stringify_keys(room)
    room_id = Map.get(room, "room_id")
    rate = Map.get(room, "nightly_rate_cents")

    cond do
      not (is_binary(room_id) and room_id != "") ->
        reject("invalid_rooms")

      not is_integer(rate) or rate < 0 ->
        reject("invalid_rooms")

      true ->
        {:ok, %{room_id: room_id, nightly_rate_cents: rate, position: position}}
    end
  end

  defp parse_room(_, _), do: reject("invalid_rooms")

  defp require_payment_amount(operation) do
    case Map.get(operation, "amount_cents") do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> reject("invalid_amount")
    end
  end

  defp reject(code), do: {:rejected, %{code: code}}

  defp applied(nil, fields), do: Map.put(fields, :status, "applied")

  defp applied(operation_id, fields) do
    fields
    |> Map.put(:status, "applied")
    |> Map.put(:operation_id, operation_id)
  end

  defp rejected(nil, fields), do: Map.put(fields, :status, "rejected")

  defp rejected(operation_id, fields) do
    fields
    |> Map.put(:status, "rejected")
    |> Map.put(:operation_id, operation_id)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp preload_rooms(nil), do: nil

  defp preload_rooms(%Group{rooms: rooms} = group) when is_list(rooms) do
    %{group | rooms: Enum.sort_by(rooms, & &1.position)}
  end

  defp preload_rooms(%Group{} = group), do: Repo.preload(group, :rooms)

  defp serialize_room(room) do
    %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
  end

  defp unique_group_id_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end
end
