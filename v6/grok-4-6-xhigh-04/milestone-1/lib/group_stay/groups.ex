defmodule GroupStay.Groups do
  alias GroupStay.Repo
  alias GroupStay.Groups.Group

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @active "active"
  @cancelled "cancelled"
  @rate_plans [@flexible, @advance_purchase]

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_one/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_), do: {:error, :not_found}

  def ledger do
    Repo.all(Group)
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn group, acc ->
        held =
          if group.status == @active do
            acc.cash_held_cents + group.deposit_paid_cents
          else
            acc.cash_held_cents
          end

        %{
          cash_held_cents: held,
          cash_refunded_cents: acc.cash_refunded_cents + group.refunded_cents,
          cash_retained_cents: acc.cash_retained_cents + group.retained_cents
        }
      end
    )
  end

  defp apply_one(op) when is_map(op) do
    op_id = fetch(op, "operation_id")

    case Repo.transaction(fn ->
           case dispatch(op) do
             {:applied, payload} -> payload
             {:rejected, payload} -> Repo.rollback(payload)
           end
         end) do
      {:ok, payload} ->
        Map.merge(%{operation_id: op_id, status: "applied"}, payload)

      {:error, payload} when is_map(payload) ->
        Map.merge(%{operation_id: op_id, status: "rejected"}, payload)
    end
  end

  defp apply_one(_op) do
    %{operation_id: nil, status: "rejected", code: "invalid_operation"}
  end

  defp dispatch(op) do
    case fetch(op, "type") do
      "open_group" -> open_group(op)
      "record_cash_payment" -> record_cash_payment(op)
      "reschedule_group" -> reschedule_group(op)
      "cancel_group" -> cancel_group(op)
      _ -> {:rejected, %{code: "invalid_operation"}}
    end
  end

  defp open_group(op) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, guest_id} <- require_id(op, "guest_id"),
         {:ok, property_id} <- require_id(op, "property_id"),
         {:ok, occurred_on} <- require_date(op, "occurred_on"),
         {:ok, arrival_on} <- require_stay_date(op, "arrival_on"),
         {:ok, departure_on} <- require_stay_date(op, "departure_on"),
         {:ok, rate_plan} <- require_rate_plan(op),
         {:ok, rooms} <- require_rooms(op) do
      nights = Date.diff(departure_on, arrival_on)

      cond do
        nights < 1 ->
          {:rejected, %{code: "invalid_stay"}}

        Repo.get_by(Group, group_id: group_id) != nil ->
          {:rejected, %{code: "group_already_exists"}}

        true ->
          lodging = lodging_total(rooms, nights)
          deposit = deposit_due(rooms, nights, rate_plan)

          %Group{}
          |> Group.changeset(%{
            group_id: group_id,
            guest_id: guest_id,
            property_id: property_id,
            booked_on: occurred_on,
            arrival_on: arrival_on,
            departure_on: departure_on,
            rate_plan: rate_plan,
            status: @active,
            revision: 1,
            lodging_total_cents: lodging,
            deposit_due_cents: deposit,
            deposit_paid_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            rooms: rooms
          })
          |> Repo.insert()
          |> case do
            {:ok, group} ->
              {:applied,
               %{
                 group_id: group.group_id,
                 deposit_due_cents: group.deposit_due_cents,
                 revision: group.revision
               }}

            {:error, changeset} ->
              if Keyword.has_key?(changeset.errors, :group_id) do
                {:rejected, %{code: "group_already_exists"}}
              else
                {:rejected, %{code: "invalid_operation"}}
              end
          end
      end
    end
  end

  defp record_cash_payment(op) do
    with {:ok, group} <- load_group_for_update(op),
         {:ok, _occurred_on} <- require_date(op, "occurred_on"),
         :ok <- require_key(op, "amount_cents") do
      amount = fetch(op, "amount_cents")

      cond do
        group.status != @active ->
          {:rejected, %{code: "group_not_active"}}

        not valid_payment_amount?(amount) ->
          {:rejected, %{code: "invalid_amount"}}

        amount > outstanding(group) ->
          {:rejected, %{code: "payment_exceeds_outstanding"}}

        true ->
          paid = group.deposit_paid_cents + amount
          revision = group.revision + 1

          group
          |> Ecto.Changeset.change(%{deposit_paid_cents: paid, revision: revision})
          |> Repo.update!()

          {:applied,
           %{
             group_id: group.group_id,
             amount_cents: amount,
             outstanding_deposit_cents: group.deposit_due_cents - paid,
             revision: revision
           }}
      end
    end
  end

  defp reschedule_group(op) do
    with {:ok, group} <- load_group_for_update(op),
         {:ok, occurred_on} <- require_date(op, "occurred_on"),
         :ok <- require_key(op, "new_arrival_on") do
      if group.status != @active do
        {:rejected, %{code: "group_not_active"}}
      else
        case parse_date(fetch(op, "new_arrival_on")) do
          {:ok, new_arrival} ->
            if Date.compare(new_arrival, occurred_on) == :gt do
              shift = Date.diff(new_arrival, group.arrival_on)
              new_departure = Date.add(group.departure_on, shift)
              revision = group.revision + 1

              group
              |> Ecto.Changeset.change(%{
                arrival_on: new_arrival,
                departure_on: new_departure,
                revision: revision
              })
              |> Repo.update!()

              {:applied,
               %{
                 group_id: group.group_id,
                 new_arrival_on: new_arrival,
                 new_departure_on: new_departure,
                 revision: revision
               }}
            else
              {:rejected, %{code: "invalid_stay"}}
            end

          _ ->
            {:rejected, %{code: "invalid_stay"}}
        end
      end
    end
  end

  defp cancel_group(op) do
    with {:ok, group} <- load_group_for_update(op),
         {:ok, occurred_on} <- require_date(op, "occurred_on") do
      if group.status != @active do
        {:rejected, %{code: "group_not_active"}}
      else
        {refunded, retained} = settlement(group, occurred_on)
        revision = group.revision + 1

        group
        |> Ecto.Changeset.change(%{
          status: @cancelled,
          refunded_cents: refunded,
          retained_cents: retained,
          revision: revision
        })
        |> Repo.update!()

        {:applied,
         %{
           group_id: group.group_id,
           refunded_cents: refunded,
           retained_cents: retained,
           revision: revision
         }}
      end
    end
  end

  defp load_group_for_update(op) do
    with {:ok, group_id} <- require_id(op, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:rejected, %{code: "group_not_found"}}

        group ->
          case revision_gate(group, op) do
            :ok -> {:ok, group}
            rejected -> rejected
          end
      end
    end
  end

  defp revision_gate(group, op) do
    case fetch(op, "expected_revision") do
      nil ->
        :ok

      expected when is_integer(expected) ->
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

      _ ->
        {:rejected, %{code: "invalid_operation"}}
    end
  end

  defp settlement(group, occurred_on) do
    paid = group.deposit_paid_cents

    if refundable?(group, occurred_on) do
      {paid, 0}
    else
      {0, paid}
    end
  end

  defp refundable?(group, occurred_on) do
    group.rate_plan == @flexible and Date.diff(group.arrival_on, occurred_on) >= 14
  end

  defp outstanding(%Group{status: @cancelled}), do: 0

  defp outstanding(group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp lodging_total(rooms, nights) do
    Enum.reduce(rooms, 0, fn room, acc ->
      acc + room.nightly_rate_cents * nights
    end)
  end

  defp deposit_due(rooms, nights, @advance_purchase) do
    lodging_total(rooms, nights)
  end

  defp deposit_due(rooms, nights, @flexible) do
    Enum.reduce(rooms, 0, fn room, acc ->
      acc + round_half_up_percent(room.nightly_rate_cents * nights, 20)
    end)
  end

  defp round_half_up_percent(amount, percent) when amount >= 0 do
    product = amount * percent
    div(product, 100) + if(rem(product, 100) >= 50, do: 1, else: 0)
  end

  defp serialize_group(group) do
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
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp require_id(op, field) do
    case fetch(op, field) do
      id when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      nil -> {:rejected, %{code: "invalid_operation"}}
      _ -> {:rejected, %{code: "invalid_operation"}}
    end
  end

  defp require_date(op, field) do
    case fetch(op, field) do
      nil ->
        {:rejected, %{code: "invalid_operation"}}

      value ->
        case parse_date(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:rejected, %{code: "invalid_operation"}}
        end
    end
  end

  defp require_stay_date(op, field) do
    case fetch(op, field) do
      nil ->
        {:rejected, %{code: "invalid_operation"}}

      value ->
        case parse_date(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:rejected, %{code: "invalid_stay"}}
        end
    end
  end

  defp require_rate_plan(op) do
    case fetch(op, "rate_plan") do
      nil -> {:rejected, %{code: "invalid_operation"}}
      plan when plan in @rate_plans -> {:ok, plan}
      _ -> {:rejected, %{code: "invalid_rate_plan"}}
    end
  end

  defp require_rooms(op) do
    case fetch(op, "rooms") do
      nil -> {:rejected, %{code: "invalid_operation"}}
      rooms -> parse_rooms(rooms)
    end
  end

  defp require_key(op, field) do
    if has_field?(op, field) do
      :ok
    else
      {:rejected, %{code: "invalid_operation"}}
    end
  end

  defp parse_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.reduce_while({:ok, []}, fn room, {:ok, acc} ->
      case parse_room(room) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error ->
        {:rejected, %{code: "invalid_rooms"}}

      {:ok, parsed} ->
        parsed = Enum.reverse(parsed)
        ids = Enum.map(parsed, & &1.room_id)

        if ids == Enum.uniq(ids) do
          {:ok, parsed}
        else
          {:rejected, %{code: "invalid_rooms"}}
        end
    end
  end

  defp parse_rooms(_), do: {:rejected, %{code: "invalid_rooms"}}

  defp parse_room(room) when is_map(room) do
    id = fetch(room, "room_id")
    rate = fetch(room, "nightly_rate_cents")

    if is_binary(id) and byte_size(id) > 0 and is_integer(rate) and rate >= 0 do
      {:ok, %{room_id: id, nightly_rate_cents: rate}}
    else
      :error
    end
  end

  defp parse_room(_), do: :error

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)

  defp parse_date(_), do: :error

  defp valid_payment_amount?(amount) when is_integer(amount) and amount > 0, do: true
  defp valid_payment_amount?(_), do: false

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, atom_key(key)))
  end

  defp has_field?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, atom_key(key))
  end

  defp atom_key("operation_id"), do: :operation_id
  defp atom_key("type"), do: :type
  defp atom_key("occurred_on"), do: :occurred_on
  defp atom_key("group_id"), do: :group_id
  defp atom_key("guest_id"), do: :guest_id
  defp atom_key("property_id"), do: :property_id
  defp atom_key("arrival_on"), do: :arrival_on
  defp atom_key("departure_on"), do: :departure_on
  defp atom_key("rate_plan"), do: :rate_plan
  defp atom_key("rooms"), do: :rooms
  defp atom_key("room_id"), do: :room_id
  defp atom_key("nightly_rate_cents"), do: :nightly_rate_cents
  defp atom_key("amount_cents"), do: :amount_cents
  defp atom_key("new_arrival_on"), do: :new_arrival_on
  defp atom_key("expected_revision"), do: :expected_revision
  defp atom_key(_), do: nil
end
