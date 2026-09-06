defmodule GroupStay do
  @moduledoc """
  The group-deposit domain and its partner batch operations.
  """

  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, GroupRoom, Ledger, Repo}

  @operation_types ~w(
    open_group
    record_cash_payment
    reschedule_group
    cancel_group
    apply_hotel_credit
  )
  @rate_plans ~w(flexible advance_purchase)
  @policy_cutover ~D[2027-01-01]
  @key_atoms %{
    "operations" => :operations,
    "operation_id" => :operation_id,
    "type" => :type,
    "group_id" => :group_id,
    "guest_id" => :guest_id,
    "property_id" => :property_id,
    "occurred_on" => :occurred_on,
    "arrival_on" => :arrival_on,
    "departure_on" => :departure_on,
    "new_arrival_on" => :new_arrival_on,
    "rate_plan" => :rate_plan,
    "rooms" => :rooms,
    "room_id" => :room_id,
    "nightly_rate_cents" => :nightly_rate_cents,
    "amount_cents" => :amount_cents,
    "expected_revision" => :expected_revision,
    "refund_method" => :refund_method,
    "on" => :on
  }

  @doc """
  Applies the operations in a partner batch in order.

  Each operation has its own transaction so a rejected operation cannot undo an
  earlier success or prevent later operations from being processed.
  """
  def process_batch(params) do
    case field(params, "operations") do
      operations when is_list(operations) ->
        %{results: Enum.map(operations, &process_operation/1)}

      _ ->
        {:error, :invalid_batch}
    end
  end

  @doc "Returns the public representation of a group, or `nil`."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> public_group(group)
    end
  end

  def get_group(_group_id), do: nil

  @doc "Returns the current finance totals, reporting credit expiry as of the requested date."
  def ledger, do: ledger(%{})

  def ledger(params) when is_map(params) do
    with {:ok, as_of} <- parse_as_of(params) do
      ledger_as_of(as_of)
    end
  end

  @doc "Returns a guest's unexpired, unexhausted credit lots."
  def get_guest_credit(guest_id, params \\ %{})

  def get_guest_credit(guest_id, params) when is_binary(guest_id) and is_map(params) do
    with {:ok, as_of} <- parse_as_of(params) do
      lots = available_credit_lots(guest_id, as_of)

      %{
        guest_id: guest_id,
        available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = field(operation, "operation_id")
    type = field(operation, "type")

    cond do
      not valid_identifier?(operation_id) -> rejected(operation_id, "invalid_operation")
      type not in @operation_types -> rejected(operation_id, "invalid_operation")
      type == "open_group" -> process_open_group(operation, operation_id)
      true -> process_group_operation(operation, operation_id, type)
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_open_group(operation, operation_id) do
    group_id = field(operation, "group_id")

    cond do
      not valid_identifier?(group_id) ->
        rejected(operation_id, "invalid_operation")

      not valid_identifier?(field(operation, "guest_id")) ->
        rejected(operation_id, "invalid_operation")

      not valid_identifier?(field(operation, "property_id")) ->
        rejected(operation_id, "invalid_operation")

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation")

      true ->
        Repo.transaction(
          fn ->
            if Repo.get(Group, group_id) do
              rejected(operation_id, "group_already_exists", %{group_id: group_id})
            else
              apply_open_group(operation, operation_id, group_id)
            end
          end,
          mode: :immediate
        )
        |> transaction_result()
    end
  end

  defp apply_open_group(operation, operation_id, group_id) do
    with {:ok, booked_on} <- parse_date(field(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(field(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)

      room_rows =
        Enum.map(rooms, fn room ->
          lodging_total_cents = nights * room.nightly_rate_cents

          deposit_due_cents =
            case field(operation, "rate_plan") do
              "advance_purchase" -> lodging_total_cents
              "flexible" -> round_half_up(lodging_total_cents * 20, 100)
            end

          Map.merge(room, %{
            lodging_total_cents: lodging_total_cents,
            deposit_due_cents: deposit_due_cents
          })
        end)

      deposit_due_cents = Enum.reduce(room_rows, 0, &(&1.deposit_due_cents + &2))

      group = %Group{
        group_id: group_id,
        guest_id: field(operation, "guest_id"),
        property_id: field(operation, "property_id"),
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: field(operation, "rate_plan"),
        policy_version: policy_version(field(operation, "rate_plan"), booked_on),
        refundable_until:
          refundable_until(
            policy_version(field(operation, "rate_plan"), booked_on),
            arrival_on
          ),
        status: "active",
        revision: 1,
        lodging_total_cents: Enum.reduce(room_rows, 0, &(&1.lodging_total_cents + &2)),
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      }

      Repo.insert!(group)

      Enum.each(Enum.with_index(room_rows), fn {room, position} ->
        Repo.insert!(%GroupRoom{
          group_id: group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        })
      end)

      applied(operation_id, %{
        group_id: group_id,
        deposit_due_cents: deposit_due_cents,
        revision: 1
      })
    else
      {:error, :invalid_stay} ->
        rejected(operation_id, "invalid_stay", %{group_id: group_id})

      {:error, :invalid_rooms} ->
        rejected(operation_id, "invalid_rooms", %{group_id: group_id})

      {:error, :invalid_rate_plan} ->
        rejected(operation_id, "invalid_rate_plan", %{group_id: group_id})
    end
  end

  defp process_group_operation(operation, operation_id, type) do
    group_id = field(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      Repo.transaction(
        fn ->
          case Repo.get(Group, group_id) do
            nil ->
              rejected(operation_id, "group_not_found", %{group_id: group_id})

            group ->
              case check_expected_revision(operation, group, operation_id) do
                :ok ->
                  apply_group_operation(operation, operation_id, type, group)

                rejection ->
                  rejection
              end
          end
        end,
        mode: :immediate
      )
      |> transaction_result()
    end
  end

  defp check_expected_revision(operation, group, operation_id) do
    case field(operation, "expected_revision") do
      nil ->
        :ok

      expected_revision when expected_revision === group.revision ->
        :ok

      expected_revision ->
        rejected(operation_id, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })
    end
  end

  defp apply_group_operation(operation, operation_id, "record_cash_payment", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_payment_amount?(field(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", %{group_id: group.group_id})

      field(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        amount_cents = field(operation, "amount_cents")
        outstanding_deposit_cents = outstanding_deposit(group) - amount_cents

        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: group_cash_paid(group) + amount_cents
        })

        ledger = ensure_ledger!()
        update_ledger!(ledger, %{cash_held_cents: ledger.cash_held_cents + amount_cents})

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount_cents,
          outstanding_deposit_cents: outstanding_deposit_cents,
          revision: group.revision + 1
        })
    end
  end

  defp apply_group_operation(operation, operation_id, "reschedule_group", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      true ->
        with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
             {:ok, new_arrival_on} <- parse_date(field(operation, "new_arrival_on")),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          nights = Date.diff(group.departure_on, group.arrival_on)
          new_departure_on = Date.add(new_arrival_on, nights)
          policy_version = policy_version(group)
          new_refundable_until = refundable_until(policy_version, new_arrival_on)

          update_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            policy_version: policy_version,
            refundable_until: new_refundable_until
          })

          applied(operation_id, %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            policy_version: policy_version,
            refundable_until: date_to_iso8601(new_refundable_until),
            revision: group.revision + 1
          })
        else
          _ -> rejected(operation_id, "invalid_stay", %{group_id: group.group_id})
        end
    end
  end

  defp apply_group_operation(operation, operation_id, "cancel_group", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_refund_method?(field(operation, "refund_method")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      true ->
        case parse_date(field(operation, "occurred_on")) do
          {:ok, occurred_on} ->
            policy_version = policy_version(group)

            refundable? =
              policy_version in ["flex-14", "flex-30"] and
                Date.compare(occurred_on, refundable_until(policy_version, group.arrival_on)) !=
                  :gt

            refund_method = refund_method(field(operation, "refund_method"))

            cond do
              not refundable? and refund_method == "hotel_credit" ->
                rejected(operation_id, "refund_method_not_available", %{group_id: group.group_id})

              true ->
                settle_cancellation!(group, operation_id, occurred_on, refundable?, refund_method)
            end

          {:error, :invalid_stay} ->
            rejected(operation_id, "invalid_stay", %{group_id: group.group_id})
        end
    end
  end

  defp apply_group_operation(operation, operation_id, "apply_hotel_credit", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_payment_amount?(field(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", %{group_id: group.group_id})

      field(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        {:ok, occurred_on} = parse_date(field(operation, "occurred_on"))
        amount_cents = field(operation, "amount_cents")
        lots = available_credit_lots(group.guest_id, occurred_on)
        available_cents = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

        if available_cents < amount_cents do
          rejected(operation_id, "insufficient_credit", %{group_id: group.group_id})
        else
          consume_credit_lots!(lots, group.group_id, amount_cents)

          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            credit_paid_cents: group_credit_paid(group) + amount_cents
          })

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding_deposit(group) - amount_cents,
            revision: group.revision + 1
          })
        end
    end
  end

  defp settle_cancellation!(group, operation_id, occurred_on, refundable?, refund_method) do
    cash_paid_cents = group_cash_paid(group)

    if refundable? do
      restore_credit_allocations!(group.group_id, occurred_on)
    else
      consume_applied_credit!(group.group_id)
    end

    {refunded_cents, retained_cents, credit_issued_cents} =
      cond do
        not refundable? ->
          {0, cash_paid_cents, 0}

        refund_method == "hotel_credit" ->
          {0, 0, issue_credit_lot!(group.guest_id, operation_id, cash_paid_cents, occurred_on)}

        true ->
          {cash_paid_cents, 0, 0}
      end

    update_group!(group, %{status: "cancelled"})

    ledger = ensure_ledger!()

    update_ledger!(ledger, %{
      cash_held_cents: ledger.cash_held_cents - cash_paid_cents,
      cash_refunded_cents: ledger.cash_refunded_cents + refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents + retained_cents,
      cash_converted_to_credit_cents:
        ledger.cash_converted_to_credit_cents +
          if(refund_method == "hotel_credit" and refundable?, do: cash_paid_cents, else: 0)
    })

    applied(operation_id, %{
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents,
      revision: group.revision + 1
    })
  end

  defp update_group!(%Group{} = group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp update_ledger!(%Ledger{} = ledger, changes) do
    ledger
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp ensure_ledger! do
    Repo.get(Ledger, 1) || Repo.insert!(%Ledger{id: 1})
  end

  defp consume_credit_lots!(lots, group_id, amount_cents) do
    {_remaining, _lots} =
      Enum.reduce_while(lots, {amount_cents, []}, fn lot, {remaining, allocations} ->
        amount_from_lot = min(remaining, lot.remaining_cents)

        if amount_from_lot > 0 do
          Repo.update!(
            Ecto.Changeset.change(lot, %{remaining_cents: lot.remaining_cents - amount_from_lot})
          )

          allocation =
            Repo.insert!(%CreditAllocation{
              group_id: group_id,
              credit_lot_id: lot.id,
              amount_cents: amount_from_lot
            })

          next_remaining = remaining - amount_from_lot

          if next_remaining == 0 do
            {:halt, {next_remaining, [allocation | allocations]}}
          else
            {:cont, {next_remaining, [allocation | allocations]}}
          end
        else
          {:cont, {remaining, allocations}}
        end
      end)

    :ok
  end

  defp restore_credit_allocations!(group_id, cancellation_date) do
    allocations_with_lots(group_id)
    |> Enum.each(fn {allocation, lot} ->
      if Date.compare(lot.expires_on, cancellation_date) == :gt do
        Repo.update!(
          Ecto.Changeset.change(lot, %{
            remaining_cents: lot.remaining_cents + allocation.amount_cents
          })
        )
      end

      Repo.delete!(allocation)
    end)
  end

  defp consume_applied_credit!(group_id) do
    allocations_with_lots(group_id)
    |> Enum.each(fn {allocation, _lot} -> Repo.delete!(allocation) end)
  end

  defp allocations_with_lots(group_id) do
    from(allocation in CreditAllocation,
      join: lot in CreditLot,
      on: lot.id == allocation.credit_lot_id,
      where: allocation.group_id == ^group_id,
      select: {allocation, lot}
    )
    |> Repo.all()
  end

  defp issue_credit_lot!(_guest_id, _operation_id, 0, _cancellation_date), do: 0

  defp issue_credit_lot!(guest_id, operation_id, cash_paid_cents, cancellation_date) do
    credit_issued_cents = cash_paid_cents + round_half_up(cash_paid_cents * 10, 100)

    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: operation_id,
      remaining_cents: credit_issued_cents,
      expires_on: Date.add(cancellation_date, 366)
    })

    credit_issued_cents
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, result}), do: result

  defp ledger_as_of(as_of) do
    ledger = Repo.get(Ledger, 1) || %Ledger{id: 1}
    public_ledger(ledger, as_of)
  end

  defp available_credit_lots(guest_id, as_of) do
    CreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0 and lot.expires_on > ^as_of)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp credit_liability(as_of) do
    available_cents =
      CreditLot
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on > ^as_of)
      |> select([lot], sum(lot.remaining_cents))
      |> Repo.one()
      |> Kernel.||(0)

    applied_cents =
      from(allocation in CreditAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: group.status == "active",
        select: sum(allocation.amount_cents)
      )
      |> Repo.one()
      |> Kernel.||(0)

    available_cents + applied_cents
  end

  defp parse_as_of(params) do
    case field(params, "on") do
      nil ->
        {:ok, Date.utc_today()}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version(_rate_plan, _booked_on), do: nil

  defp policy_version(%Group{policy_version: version, rate_plan: rate_plan, booked_on: booked_on}) do
    version || policy_version(rate_plan, booked_on)
  end

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(_policy_version, _arrival_on), do: nil

  defp date_to_iso8601(nil), do: nil
  defp date_to_iso8601(date), do: Date.to_iso8601(date)

  defp valid_refund_method?(nil), do: true
  defp valid_refund_method?(method), do: method in ["cash", "hotel_credit"]

  defp refund_method(nil), do: "cash"
  defp refund_method(method), do: method

  defp validate_stay({:ok, arrival_on}, {:ok, departure_on}) do
    validate_stay(arrival_on, departure_on)
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: field(room, "room_id"), nightly_rate_cents: field(room, "nightly_rate_cents")}
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp valid_room?(room) when is_map(room) do
    valid_identifier?(field(room, "room_id")) and
      is_integer(field(room, "nightly_rate_cents")) and field(room, "nightly_rate_cents") > 0
  end

  defp valid_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, &field(&1, "room_id"))
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp valid_payment_amount?(amount_cents),
    do: is_integer(amount_cents) and amount_cents > 0

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_stay}

  defp valid_operation_date?(value) do
    match?({:ok, _date}, parse_date(value))
  end

  defp public_group(group) do
    rooms =
      GroupRoom
      |> where([room], room.group_id == ^group.group_id)
      |> order_by([room], asc: room.position)
      |> Repo.all()

    policy_version = policy_version(group)

    refundable_until =
      group.refundable_until || refundable_until(policy_version, group.arrival_on)

    credit_paid_cents = group_credit_paid(group)
    cash_paid_cents = group_cash_paid(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version,
      refundable_until: date_to_iso8601(refundable_until),
      status: group.status,
      revision: group.revision,
      rooms: Enum.map(rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp credit_paid_for_group(group_id) do
    CreditAllocation
    |> where([allocation], allocation.group_id == ^group_id)
    |> select([allocation], sum(allocation.amount_cents))
    |> Repo.one()
    |> case do
      nil -> 0
      amount -> amount
    end
  end

  defp group_credit_paid(%Group{credit_paid_cents: credit_paid_cents})
       when is_integer(credit_paid_cents),
       do: credit_paid_cents

  defp group_credit_paid(%Group{} = group), do: credit_paid_for_group(group.group_id)

  defp group_cash_paid(%Group{cash_paid_cents: cash_paid_cents}) when is_integer(cash_paid_cents),
    do: cash_paid_cents

  defp group_cash_paid(%Group{} = group),
    do: max(group.deposit_paid_cents - group_credit_paid(group), 0)

  defp public_ledger(ledger, as_of) do
    %{
      cash_held_cents: ledger.cash_held_cents,
      cash_refunded_cents: ledger.cash_refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents,
      cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents,
      credit_liability_cents: credit_liability(as_of)
    }
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejected(operation_id, code, fields \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@key_atoms, key))
    end
  end

  defp field(_map, _key), do: nil

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
end
