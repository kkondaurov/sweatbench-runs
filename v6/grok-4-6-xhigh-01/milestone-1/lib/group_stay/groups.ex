defmodule GroupStay.Groups do
  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.Group

  @rate_plans ~w(flexible advance_purchase)
  @refundable_days 14

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_by_group_id(group_id) when is_binary(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  def get_by_group_id(_), do: nil

  def ledger_totals do
    groups =
      Repo.all(
        from g in Group,
          select: {g.status, g.deposit_paid_cents, g.refunded_cents, g.retained_cents}
      )

    Enum.reduce(groups, %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0}, fn
      {"active", paid, _refunded, _retained}, acc ->
        %{acc | cash_held_cents: acc.cash_held_cents + paid}

      {_status, _paid, refunded, retained}, acc ->
        %{
          acc
          | cash_refunded_cents: acc.cash_refunded_cents + refunded,
            cash_retained_cents: acc.cash_retained_cents + retained
        }
    end)
  end

  def serialize(%Group{} = group) do
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
        Enum.map(group.rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp apply_operation(operation) when not is_map(operation) do
    rejected(operation, "invalid_operation")
  end

  defp apply_operation(operation) do
    operation = stringify_keys(operation)

    case transact(fn -> dispatch(operation) end) do
      {:ok, result} -> result
      {:error, result} when is_map(result) -> result
      {:error, code} when is_binary(code) -> rejected(operation, code)
    end
  end

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)
  defp dispatch(operation), do: {:error, rejected(operation, "invalid_operation")}

  defp open_group(operation) do
    with {:ok, attrs} <- parse_open(operation) do
      case Repo.get_by(Group, group_id: attrs.group_id) do
        %Group{} ->
          {:error, rejected(operation, "group_already_exists")}

        nil ->
          case Repo.insert(Group.insert_changeset(attrs)) do
            {:ok, group} ->
              {:ok,
               applied(operation, %{
                 group_id: group.group_id,
                 deposit_due_cents: group.deposit_due_cents,
                 revision: group.revision
               })}

            {:error, changeset} ->
              if unique_error?(changeset) do
                {:error, rejected(operation, "group_already_exists")}
              else
                {:error, rejected(operation, "invalid_operation")}
              end
          end
      end
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, amount} <- req_payment_amount(operation) do
      outstanding = outstanding(group)

      cond do
        amount > outstanding ->
          {:error, rejected(operation, "payment_exceeds_outstanding")}

        true ->
          paid = group.deposit_paid_cents + amount

          {:ok, group} =
            group
            |> change(%{deposit_paid_cents: paid})
            |> optimistic_lock(:revision)
            |> Repo.update()

          {:ok,
           applied(operation, %{
             group_id: group.group_id,
             amount_cents: amount,
             outstanding_deposit_cents: outstanding(group),
             revision: group.revision
           })}
      end
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- req_date(operation, "new_arrival_on", "invalid_stay"),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      {:ok, group} =
        group
        |> change(%{arrival_on: new_arrival_on, departure_on: new_departure_on})
        |> optimistic_lock(:revision)
        |> Repo.update()

      {:ok,
       applied(operation, %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         revision: group.revision
       })}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation") do
      {refunded, retained} = settlement(group, occurred_on)

      {:ok, group} =
        group
        |> change(%{status: "cancelled", refunded_cents: refunded, retained_cents: retained})
        |> optimistic_lock(:revision)
        |> Repo.update()

      {:ok,
       applied(operation, %{
         group_id: group.group_id,
         refunded_cents: group.refunded_cents,
         retained_cents: group.retained_cents,
         revision: group.revision
       })}
    end
  end

  defp parse_open(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, guest_id} <- req_id(operation, "guest_id"),
         {:ok, property_id} <- req_id(operation, "property_id"),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, rate_plan} <- req_rate_plan(operation),
         {:ok, arrival_on} <- req_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- req_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay_length(arrival_on, departure_on),
         {:ok, rooms} <- req_rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)
      {lodging, deposit} = totals(rooms, nights, rate_plan)

      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: occurred_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms,
         lodging_total_cents: lodging,
         deposit_due_cents: deposit,
         deposit_paid_cents: 0,
         refunded_cents: 0,
         retained_cents: 0,
         status: "active",
         revision: 1
       }}
    else
      {:error, result} -> {:error, result}
    end
  end

  defp totals(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_acc, deposit_acc} ->
      lodging = nights * room.nightly_rate_cents
      deposit = room_deposit(lodging, rate_plan)
      {lodging_acc + lodging, deposit_acc + deposit}
    end)
  end

  defp room_deposit(lodging, "flexible"), do: round_percent(lodging, 20)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp round_percent(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp outstanding(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding(_group), do: 0

  defp settlement(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= @refundable_days do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp settlement(group, _occurred_on) do
    {0, group.deposit_paid_cents}
  end

  defp fetch_group(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, rejected(operation, "group_not_found")}
    end
  end

  defp match_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, expected} ->
        if expected === group.revision do
          :ok
        else
          {:error,
           %{
             operation_id: operation["operation_id"],
             status: "rejected",
             code: "stale_revision",
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           }
           |> drop_nil_operation_id()}
        end
    end
  end

  defp require_active(%Group{status: "active"}), do: :ok
  defp require_active(_group), do: {:error, "group_not_active"}

  defp validate_stay_length(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp req_id(operation, key) do
    case operation[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp req_date(operation, key, code) do
    case parse_date(operation[key]) do
      {:ok, date} ->
        {:ok, date}

      :error ->
        {:error, if(code == "invalid_operation", do: rejected(operation, code), else: code)}
    end
  end

  defp req_rate_plan(operation) do
    case operation["rate_plan"] do
      plan when plan in @rate_plans -> {:ok, plan}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp req_rooms(operation) do
    case operation["rooms"] do
      rooms when is_list(rooms) and rooms != [] ->
        parsed = Enum.map(rooms, &parse_room/1)

        cond do
          Enum.any?(parsed, &(&1 == :error)) ->
            {:error, "invalid_rooms"}

          true ->
            rooms = Enum.map(parsed, fn {:ok, room} -> room end)
            ids = Enum.map(rooms, & &1.room_id)

            if ids == Enum.uniq(ids) do
              {:ok, rooms}
            else
              {:error, "invalid_rooms"}
            end
        end

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp parse_room(room) when is_map(room) do
    room = stringify_keys(room)
    id = room["room_id"]
    rate = room["nightly_rate_cents"]

    if is_binary(id) and id != "" and is_integer(rate) and rate >= 0 do
      {:ok, %{room_id: id, nightly_rate_cents: rate}}
    else
      :error
    end
  end

  defp parse_room(_), do: :error

  defp req_payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, rejected(operation, "invalid_operation")}

      {:ok, amount} when is_integer(amount) and amount > 0 ->
        {:ok, amount}

      {:ok, _} ->
        {:error, "invalid_amount"}
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    Date.from_iso8601(value)
  end

  defp parse_date(_), do: :error

  defp applied(operation, fields) do
    Map.merge(%{operation_id: operation["operation_id"], status: "applied"}, fields)
    |> drop_nil_operation_id()
  end

  defp rejected(operation, code) when is_map(operation) do
    %{operation_id: operation["operation_id"], status: "rejected", code: code}
    |> drop_nil_operation_id()
  end

  defp rejected(_operation, code) do
    %{status: "rejected", code: code}
  end

  defp drop_nil_operation_id(%{operation_id: nil} = map), do: Map.delete(map, :operation_id)
  defp drop_nil_operation_id(map), do: map

  defp unique_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp transact(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
