defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @active "active"
  @cancelled "cancelled"
  @rate_plans [@flexible, @advance_purchase]
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @policy_cutoff ~D[2027-01-01]
  @cash "cash"
  @hotel_credit "hotel_credit"

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

  def get_guest_credit(guest_id, on \\ nil) when is_binary(guest_id) do
    as_of = as_of_date(on)
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def ledger(on \\ nil) do
    as_of = as_of_date(on)

    groups = Repo.all(Group)

    cash =
      Enum.reduce(
        groups,
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          applied_credit: 0
        },
        fn group, acc ->
          {held, applied} =
            if group.status == @active do
              {acc.cash_held_cents + cash_paid(group), acc.applied_credit + credit_paid(group)}
            else
              {acc.cash_held_cents, acc.applied_credit}
            end

          %{
            cash_held_cents: held,
            cash_refunded_cents: acc.cash_refunded_cents + group.refunded_cents,
            cash_retained_cents: acc.cash_retained_cents + group.retained_cents,
            cash_converted_to_credit_cents:
              acc.cash_converted_to_credit_cents + converted_to_credit(group),
            applied_credit: applied
          }
        end
      )

    available =
      available_lots_query(as_of)
      |> Repo.all()
      |> Enum.reduce(0, fn lot, acc -> acc + lot.remaining_cents end)

    %{
      cash_held_cents: cash.cash_held_cents,
      cash_refunded_cents: cash.cash_refunded_cents,
      cash_retained_cents: cash.cash_retained_cents,
      cash_converted_to_credit_cents: cash.cash_converted_to_credit_cents,
      credit_liability_cents: available + cash.applied_credit
    }
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
      "apply_hotel_credit" -> apply_hotel_credit(op)
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
            cash_paid_cents: 0,
            credit_paid_cents: 0,
            cash_converted_to_credit_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            policy_version: assign_policy_version(rate_plan, occurred_on),
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
          cash = cash_paid(group) + amount
          revision = group.revision + 1

          group
          |> Ecto.Changeset.change(%{
            deposit_paid_cents: paid,
            cash_paid_cents: cash,
            revision: revision
          })
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
              policy = effective_policy(group)

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
                 policy_version: policy,
                 refundable_until: refundable_until(new_arrival, policy),
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
         {:ok, occurred_on} <- require_date(op, "occurred_on"),
         {:ok, refund_method} <- require_refund_method(op) do
      cond do
        group.status != @active ->
          {:rejected, %{code: "group_not_active"}}

        refund_method == @hotel_credit and not refundable?(group, occurred_on) ->
          {:rejected, %{code: "refund_method_not_available"}}

        true ->
          settle_cancellation(group, op, occurred_on, refund_method)
      end
    end
  end

  defp apply_hotel_credit(op) do
    with {:ok, group} <- load_group_for_update(op),
         {:ok, occurred_on} <- require_date(op, "occurred_on"),
         :ok <- require_key(op, "amount_cents") do
      amount = fetch(op, "amount_cents")

      cond do
        group.status != @active ->
          {:rejected, %{code: "group_not_active"}}

        not valid_payment_amount?(amount) ->
          {:rejected, %{code: "invalid_amount"}}

        amount > outstanding(group) ->
          {:rejected, %{code: "payment_exceeds_outstanding"}}

        guest_available_credit(group.guest_id, occurred_on) < amount ->
          {:rejected, %{code: "insufficient_credit"}}

        true ->
          consume_credit(group, amount, occurred_on)
          paid = group.deposit_paid_cents + amount
          credit = credit_paid(group) + amount
          revision = group.revision + 1

          group
          |> Ecto.Changeset.change(%{
            deposit_paid_cents: paid,
            credit_paid_cents: credit,
            revision: revision
          })
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

  defp settle_cancellation(group, op, occurred_on, refund_method) do
    refundable = refundable?(group, occurred_on)
    cash = cash_paid(group)
    revision = group.revision + 1

    {refunded, retained, converted, issued} =
      cond do
        refundable and refund_method == @hotel_credit ->
          {0, 0, cash, credit_from_cash(cash)}

        refundable ->
          {cash, 0, 0, 0}

        true ->
          {0, cash, 0, 0}
      end

    if issued > 0 do
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: fetch(op, "operation_id"),
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()
    end

    restore_or_consume_credit(group, occurred_on, refundable)

    group
    |> Ecto.Changeset.change(%{
      status: @cancelled,
      refunded_cents: refunded,
      retained_cents: retained,
      cash_converted_to_credit_cents: converted_to_credit(group) + converted,
      revision: revision
    })
    |> Repo.update!()

    {:applied,
     %{
       group_id: group.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       credit_issued_cents: issued,
       revision: revision
     }}
  end

  defp restore_or_consume_credit(group, occurred_on, refundable) do
    apps =
      from(a in CreditApplication, where: a.group_id == ^group.group_id)
      |> Repo.all()

    if refundable do
      Enum.each(apps, fn app ->
        if Date.compare(app.expires_on, occurred_on) != :lt do
          lot =
            Repo.get_by!(CreditLot,
              guest_id: group.guest_id,
              source_operation_id: app.source_operation_id
            )

          lot
          |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents + app.amount_cents})
          |> Repo.update!()
        end
      end)
    end

    from(a in CreditApplication, where: a.group_id == ^group.group_id)
    |> Repo.delete_all()
  end

  defp consume_credit(group, amount, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    Enum.reduce_while(lots, amount, fn lot, left ->
      if left == 0 do
        {:halt, 0}
      else
        take = min(lot.remaining_cents, left)

        lot
        |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents - take})
        |> Repo.update!()

        %CreditApplication{}
        |> CreditApplication.changeset(%{
          group_id: group.group_id,
          source_operation_id: lot.source_operation_id,
          expires_on: lot.expires_on,
          amount_cents: take
        })
        |> Repo.insert!()

        {:cont, left - take}
      end
    end)
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

  defp refundable?(group, occurred_on) do
    case window_days(effective_policy(group)) do
      nil -> false
      days -> Date.diff(group.arrival_on, occurred_on) >= days
    end
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

  defp credit_from_cash(cash) when cash > 0 do
    cash + round_half_up_percent(cash, 10)
  end

  defp credit_from_cash(_cash), do: 0

  defp assign_policy_version(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp assign_policy_version(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt do
      @flex_14
    else
      @flex_30
    end
  end

  defp effective_policy(group) do
    group.policy_version || assign_policy_version(group.rate_plan, group.booked_on)
  end

  defp window_days(@flex_14), do: 14
  defp window_days(@flex_30), do: 30
  defp window_days(@advance_nonrefundable), do: nil
  defp window_days(_), do: nil

  defp refundable_until(arrival, policy) do
    case window_days(policy) do
      nil -> nil
      days -> Date.add(arrival, -days)
    end
  end

  defp serialize_group(group) do
    policy = effective_policy(group)

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
      policy_version: policy,
      refundable_until: refundable_until(group.arrival_on, policy),
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid(group),
      credit_paid_cents: credit_paid(group),
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp cash_paid(group), do: group.cash_paid_cents || 0
  defp credit_paid(group), do: group.credit_paid_cents || 0
  defp converted_to_credit(group), do: group.cash_converted_to_credit_cents || 0

  defp guest_available_credit(guest_id, as_of) do
    available_lots(guest_id, as_of)
    |> Enum.reduce(0, fn lot, acc -> acc + lot.remaining_cents end)
  end

  defp available_lots(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  defp available_lots_query(as_of) do
    from(l in CreditLot,
      where: l.remaining_cents > 0 and l.expires_on >= ^as_of
    )
  end

  defp as_of_date(nil), do: Date.utc_today()

  defp as_of_date(%Date{} = date), do: date

  defp as_of_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp as_of_date(_), do: Date.utc_today()

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

  defp require_refund_method(op) do
    case fetch(op, "refund_method") do
      nil -> {:ok, @cash}
      @cash -> {:ok, @cash}
      @hotel_credit -> {:ok, @hotel_credit}
      _ -> {:rejected, %{code: "invalid_operation"}}
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
  defp atom_key("refund_method"), do: :refund_method
  defp atom_key(_), do: nil
end
