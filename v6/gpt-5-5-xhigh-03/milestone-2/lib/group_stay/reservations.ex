defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditLot, Group, HotelCreditApplication, Room}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @policy_flex_14 "flex-14"
  @policy_flex_30 "flex-30"
  @policy_advance_nonrefundable "advance-nonrefundable"
  @flex_30_starts_on ~D[2027-01-01]
  @refund_cash "cash"
  @refund_hotel_credit "hotel_credit"

  def process_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def process_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> preload_rooms()
  end

  def group_data(%Group{} = group) do
    group = preload_rooms(group)
    policy_version = policy_version(group)

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
      policy_version: policy_version,
      refundable_until: refundable_until_iso(group, policy_version),
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: deposit_paid_cents(group),
      cash_paid_cents: cash_paid_cents(group),
      credit_paid_cents: credit_paid_cents(group),
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  def ledger_totals(raw_on \\ nil) do
    on_date = reporting_date(raw_on)

    %{
      cash_held_cents: sum_group_field(:deposit_paid_cents, status: @active),
      cash_refunded_cents: sum_group_field(:refunded_cents),
      cash_retained_cents: sum_group_field(:retained_cents),
      cash_converted_to_credit_cents: sum_group_field(:cash_converted_to_credit_cents),
      credit_liability_cents: available_credit_total(on_date) + active_credit_application_total()
    }
  end

  def guest_credit_data(guest_id, raw_on \\ nil) do
    on_date = reporting_date(raw_on)
    lots = available_credit_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: sum_key(lots, :remaining_cents),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  defp process_operation(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:applied, _result} = applied -> applied
             {:rejected, result} -> Repo.rollback({:rejected, result})
           end
         end) do
      {:ok, {:applied, result}} -> result
      {:error, {:rejected, result}} -> result
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, amount_cents} <- usable_payment_amount(operation),
         :ok <- payment_within_outstanding(group, amount_cents) do
      group =
        group
        |> Ecto.Changeset.change(
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_payment_amount(operation),
         :ok <- payment_within_outstanding(group, amount_cents),
         {:ok, lots} <- credit_lots_covering(group.guest_id, amount_cents, occurred_on) do
      apply_credit_lots(group, lots, amount_cents)

      group =
        group
        |> Ecto.Changeset.change(
          credit_paid_cents: credit_paid_cents(group) + amount_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "reschedule_group"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, occurred_on} <- reschedule_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- reschedule_date(operation, "new_arrival_on"),
         :ok <- arrival_after_operation(new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      group =
        group
        |> Ecto.Changeset.change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        policy_version: policy_version(group),
        refundable_until: refundable_until_iso(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "cancel_group"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, settlement} <- cancellation_settlement(group, occurred_on, refund_method) do
      restore_credit_applications(group, occurred_on, settlement.refundable?)
      create_credit_lot(group, operation, occurred_on, settlement.credit_issued_cents)

      group =
        group
        |> Ecto.Changeset.change(
          status: @cancelled,
          refunded_cents: settlement.refunded_cents,
          retained_cents: settlement.retained_cents,
          cash_converted_to_credit_cents: settlement.cash_converted_to_credit_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: group.refunded_cents,
        retained_cents: group.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(operation), do: rejected(operation, "invalid_operation")

  defp open_group(operation) do
    with :ok <- operation_identified(operation),
         {:ok, attrs} <- open_group_attrs(operation),
         :ok <- group_id_available(attrs.group_id),
         {:ok, arrival_on, departure_on, nights} <-
           valid_stay(attrs.arrival_on, attrs.departure_on),
         {:ok, rooms} <- valid_rooms(attrs.rooms),
         {:ok, rate_plan} <- valid_rate_plan(attrs.rate_plan) do
      room_totals = room_totals(rooms, nights, rate_plan)

      group =
        %Group{
          group_id: attrs.group_id,
          guest_id: attrs.guest_id,
          property_id: attrs.property_id,
          booked_on: attrs.booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: @active,
          policy_version: policy_version_for(rate_plan, attrs.booked_on),
          lodging_total_cents: sum_key(room_totals, :lodging_total_cents),
          deposit_due_cents: sum_key(room_totals, :deposit_due_cents),
          deposit_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          revision: 1
        }
        |> Repo.insert!()

      room_totals
      |> Enum.with_index()
      |> Enum.each(fn {room, index} ->
        Repo.insert!(%Room{
          group_id: group.id,
          position: index,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents
        })
      end)

      applied(operation, %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      })
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp open_group_attrs(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, arrival_on} <- required_raw(operation, "arrival_on"),
         {:ok, departure_on} <- required_raw(operation, "departure_on"),
         {:ok, rate_plan} <- required_raw(operation, "rate_plan"),
         {:ok, rooms} <- required_raw(operation, "rooms") do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    else
      {:error, _code} -> {:error, "invalid_operation"}
    end
  end

  defp operation_identified(operation) do
    with {:ok, _operation_id} <- required_string(operation, "operation_id") do
      :ok
    end
  end

  defp addressed_active_group(operation) do
    with {:ok, group} <- addressed_group(operation) do
      if group.status == @active do
        {:ok, group}
      else
        {:error, "group_not_active"}
      end
    end
  end

  defp addressed_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:error, "group_not_found", %{group_id: group_id}}

        group ->
          expected_revision = Map.get(operation, "expected_revision")

          if is_nil(expected_revision) or expected_revision == group.revision do
            {:ok, group}
          else
            {:error, "stale_revision",
             %{
               group_id: group.group_id,
               expected_revision: expected_revision,
               actual_revision: group.revision
             }}
          end
      end
    else
      {:error, _code} -> {:error, "invalid_operation"}
    end
  end

  defp group_id_available(group_id) do
    if Repo.exists?(from group in Group, where: group.group_id == ^group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    with {:ok, arrival_on} <- parse_date(arrival_on),
         {:ok, departure_on} <- parse_date(departure_on),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {room, _index}, {:ok, acc, seen_ids} ->
      with {:ok, room_id} <- required_string(room, "room_id"),
           false <- MapSet.member?(seen_ids, room_id),
           {:ok, nightly_rate_cents} <- non_negative_integer(room, "nightly_rate_cents") do
        parsed_room = %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
        {:cont, {:ok, [parsed_room | acc], MapSet.put(seen_ids, room_id)}}
      else
        _ -> {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, rooms, _seen_ids} -> {:ok, Enum.reverse(rooms)}
      {:error, code} -> {:error, code}
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp valid_rate_plan(rate_plan) when rate_plan in [@flexible, @advance_purchase],
    do: {:ok, rate_plan}

  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp room_totals(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging_total_cents = room.nightly_rate_cents * nights

      deposit_due_cents =
        case rate_plan do
          @flexible -> round_percentage(lodging_total_cents, 20)
          @advance_purchase -> lodging_total_cents
        end

      Map.merge(room, %{
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents
      })
    end)
  end

  defp round_percentage(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
  end

  defp usable_payment_amount(operation),
    do: payment_amount(operation, "amount_cents")

  defp payment_amount(operation, key) do
    case required_raw(operation, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_amount"}
      {:error, _code} -> {:error, "invalid_operation"}
    end
  end

  defp payment_within_outstanding(group, amount_cents) do
    if amount_cents <= outstanding_deposit(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp credit_lots_covering(guest_id, amount_cents, occurred_on) do
    lots = available_credit_lots(guest_id, occurred_on)

    if sum_key(lots, :remaining_cents) >= amount_cents do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp apply_credit_lots(group, lots, amount_cents) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining_cents ->
      if remaining_cents == 0 do
        {:halt, 0}
      else
        applied_cents = min(lot.remaining_cents, remaining_cents)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - applied_cents)
        |> Repo.update!()

        Repo.insert!(%HotelCreditApplication{
          group_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: applied_cents
        })

        {:cont, remaining_cents - applied_cents}
      end
    end)

    :ok
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", @refund_cash) do
      method when method in [@refund_cash, @refund_hotel_credit] -> {:ok, method}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp cancellation_settlement(group, occurred_on, refund_method) do
    refundable? = refundable_cancellation?(group, occurred_on)

    if refund_method == @refund_hotel_credit and not refundable? do
      {:error, "refund_method_not_available"}
    else
      cash_cancellation_settlement(cash_paid_cents(group), refundable?, refund_method)
    end
  end

  defp cash_cancellation_settlement(cash_paid_cents, true, @refund_cash) do
    {:ok,
     %{
       refundable?: true,
       refunded_cents: cash_paid_cents,
       retained_cents: 0,
       cash_converted_to_credit_cents: 0,
       credit_issued_cents: 0
     }}
  end

  defp cash_cancellation_settlement(cash_paid_cents, true, @refund_hotel_credit) do
    credit_issued_cents = cash_paid_cents + round_percentage(cash_paid_cents, 10)

    {:ok,
     %{
       refundable?: true,
       refunded_cents: 0,
       retained_cents: 0,
       cash_converted_to_credit_cents: cash_paid_cents,
       credit_issued_cents: credit_issued_cents
     }}
  end

  defp cash_cancellation_settlement(cash_paid_cents, false, @refund_cash) do
    {:ok,
     %{
       refundable?: false,
       refunded_cents: 0,
       retained_cents: cash_paid_cents,
       cash_converted_to_credit_cents: 0,
       credit_issued_cents: 0
     }}
  end

  defp restore_credit_applications(group, occurred_on, true) do
    group_credit_applications(group)
    |> Enum.each(fn application ->
      credit_lot = application.credit_lot

      if Date.compare(credit_lot.expires_on, occurred_on) == :gt do
        credit_lot
        |> Ecto.Changeset.change(
          remaining_cents: credit_lot.remaining_cents + application.amount_cents
        )
        |> Repo.update!()
      end
    end)
  end

  defp restore_credit_applications(_group, _occurred_on, false), do: :ok

  defp create_credit_lot(_group, _operation, _occurred_on, 0), do: :ok

  defp create_credit_lot(group, operation, occurred_on, credit_issued_cents) do
    Repo.insert!(%CreditLot{
      guest_id: group.guest_id,
      source_operation_id: Map.fetch!(operation, "operation_id"),
      remaining_cents: credit_issued_cents,
      expires_on: Date.add(occurred_on, 366)
    })

    :ok
  end

  defp refundable_cancellation?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
  end

  defp outstanding_deposit(%Group{status: @cancelled}), do: 0

  defp outstanding_deposit(%Group{} = group) do
    max(group.deposit_due_cents - deposit_paid_cents(group), 0)
  end

  defp deposit_paid_cents(%Group{} = group), do: cash_paid_cents(group) + credit_paid_cents(group)

  defp cash_paid_cents(%Group{} = group), do: group.deposit_paid_cents || 0

  defp credit_paid_cents(%Group{} = group), do: group.credit_paid_cents || 0

  defp policy_version(%Group{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(%Group{} = group), do: policy_version_for(group.rate_plan, group.booked_on)

  defp policy_version_for(@advance_purchase, _booked_on), do: @policy_advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @flex_30_starts_on) == :lt do
      @policy_flex_14
    else
      @policy_flex_30
    end
  end

  defp refundable_until_iso(%Group{} = group, policy_version \\ nil) do
    case refundable_until(group, policy_version) do
      nil -> nil
      refundable_until -> Date.to_iso8601(refundable_until)
    end
  end

  defp refundable_until(%Group{} = group, policy_version \\ nil) do
    case policy_version || policy_version(group) do
      @policy_flex_14 -> Date.add(group.arrival_on, -14)
      @policy_flex_30 -> Date.add(group.arrival_on, -30)
      @policy_advance_nonrefundable -> nil
    end
  end

  defp available_credit_lots(guest_id, on_date) do
    CreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on_date)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp group_credit_applications(group) do
    HotelCreditApplication
    |> where([application], application.group_id == ^group.id)
    |> preload(:credit_lot)
    |> Repo.all()
  end

  defp preload_rooms(nil), do: nil

  defp preload_rooms(%Group{} = group) do
    Repo.preload(group, rooms: from(room in Room, order_by: room.position))
  end

  defp required_raw(params, key) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp required_raw(_params, _key), do: {:error, "invalid_operation"}

  defp required_string(params, key) do
    with {:ok, value} <- required_raw(params, key),
         true <- is_binary(value),
         trimmed when trimmed != "" <- String.trim(value) do
      {:ok, value}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(params, key) do
    with {:ok, raw_date} <- required_raw(params, key),
         {:ok, date} <- parse_date(raw_date) do
      {:ok, date}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp parse_date(_date), do: {:error, :invalid_date}

  defp reporting_date(nil), do: Date.utc_today()
  defp reporting_date(%Date{} = date), do: date

  defp reporting_date(raw_date) do
    case parse_date(raw_date) do
      {:ok, date} -> date
      {:error, _reason} -> Date.utc_today()
    end
  end

  defp reschedule_date(params, key) do
    case required_raw(params, key) do
      {:ok, raw_date} ->
        case parse_date(raw_date) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      {:error, _code} ->
        {:error, "invalid_operation"}
    end
  end

  defp non_negative_integer(params, key) do
    with {:ok, value} <- required_raw(params, key),
         true <- is_integer(value),
         true <- value >= 0 do
      {:ok, value}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp sum_key(values, key), do: Enum.reduce(values, 0, &(&2 + Map.fetch!(&1, key)))

  defp available_credit_total(on_date) do
    CreditLot
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on_date)
    |> select([lot], coalesce(sum(lot.remaining_cents), 0))
    |> Repo.one()
  end

  defp active_credit_application_total do
    HotelCreditApplication
    |> join(:inner, [application], group in assoc(application, :group))
    |> where([_application, group], group.status == ^@active)
    |> select([application, _group], coalesce(sum(application.amount_cents), 0))
    |> Repo.one()
  end

  defp sum_group_field(field, opts \\ []) do
    query = from group in Group, select: coalesce(sum(field(group, ^field)), 0)

    query =
      case Keyword.fetch(opts, :status) do
        {:ok, status} -> from group in query, where: group.status == ^status
        :error -> query
      end

    Repo.one(query)
  end

  defp applied(operation, attrs), do: {:applied, result(operation, "applied", attrs)}

  defp rejected(operation, code, attrs \\ %{}) do
    {:rejected, result(operation, "rejected", Map.put(attrs, :code, code))}
  end

  defp result(operation, status, attrs) do
    operation_id =
      if is_map(operation) do
        Map.get(operation, "operation_id")
      end

    %{
      operation_id: operation_id,
      status: status
    }
    |> Map.merge(attrs)
  end
end
