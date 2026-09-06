defmodule GroupStay.FinanceReporting do
  import Ecto.Query

  alias GroupStay.Accounting.CreditEntitlement
  alias GroupStay.Accounting.Payment
  alias GroupStay.Accounting.RoomFunding
  alias GroupStay.Credit.Application, as: CreditApplication
  alias GroupStay.Credit.Lot, as: CreditLot
  alias GroupStay.Finance.Event
  alias GroupStay.Finance.OpeningCash
  alias GroupStay.Finance.OpeningCredit
  alias GroupStay.Finance.OpeningDisposition
  alias GroupStay.Finance.Reporting, as: ReportingRecord
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @reporting_id 1
  @policy_cutover ~D[2027-01-01]

  @cash_fields [
    :received_cents,
    :transferred_in_cents,
    :transferred_out_cents,
    :refunded_cents,
    :retained_cents,
    :converted_to_credit_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  def current, do: Repo.get(ReportingRecord, @reporting_id)

  def capture_context(operation) do
    case current() do
      nil -> nil
      reporting -> %{reporting: reporting, before: before_state(operation)}
    end
  end

  def start_reporting(starts_on) do
    case current() do
      %ReportingRecord{} ->
        {:error, "reporting_already_started", %{}}

      nil ->
        %ReportingRecord{}
        |> ReportingRecord.changeset(%{
          id: @reporting_id,
          starts_on: starts_on,
          opening_credit_liability_cents: credit_liability(starts_on)
        })
        |> Repo.insert!()

        Enum.each(opening_cash(), fn {property_id, held_cents} ->
          %OpeningCash{}
          |> OpeningCash.changeset(%{property_id: property_id, held_cents: held_cents})
          |> Repo.insert!()
        end)

        Enum.each(opening_credit(starts_on), fn {credit_lot_id, available_cents} ->
          %OpeningCredit{}
          |> OpeningCredit.changeset(%{
            credit_lot_id: credit_lot_id,
            available_cents: available_cents
          })
          |> Repo.insert!()
        end)

        Enum.each(opening_dispositions(), fn disposition ->
          %OpeningDisposition{}
          |> OpeningDisposition.changeset(disposition)
          |> Repo.insert!()
        end)

        :ok
    end
  end

  def record_applied(_operation, _result, nil), do: :ok

  def record_applied(operation, result, %{reporting: reporting, before: before}) do
    posting_date = posting_date(operation, reporting.starts_on)

    operation_events(operation, result, before, posting_date)
    |> Enum.each(fn attrs ->
      %Event{}
      |> Event.changeset(
        Map.merge(%{operation_id: operation_id(operation), posting_date: posting_date}, attrs)
      )
      |> Repo.insert!()
    end)

    :ok
  end

  def daily_report(%Date{} = date) do
    case current() do
      nil ->
        {:error, %{code: "report_not_available"}}

      %ReportingRecord{starts_on: starts_on} = reporting ->
        if Date.compare(date, starts_on) == :lt do
          {:error, %{code: "report_not_available"}}
        else
          {:ok, build_report(reporting, date)}
        end
    end
  end

  defp build_report(reporting, date) do
    cash_events =
      Repo.all(
        from event in Event,
          where: event.posting_date <= ^date and not is_nil(event.property_id)
      )

    opening_cash =
      Repo.all(from opening in OpeningCash, select: {opening.property_id, opening.held_cents})

    cash = build_cash(opening_cash, cash_events)

    credit_events = Repo.all(from event in Event, where: event.posting_date <= ^date)
    credit = credit_movements(credit_events, reporting.starts_on, date)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: reporting.opening_credit_liability_cents,
        movements: credit.movements,
        closing_liability_cents:
          reporting.opening_credit_liability_cents + credit.issued - credit.expired -
            credit.consumed - credit.revoked - credit.absorbed
      }
    }
  end

  defp build_cash(opening_cash, events) do
    opening = Map.new(opening_cash)

    movement_by_property =
      Enum.reduce(events, %{}, fn event, totals ->
        Map.update(totals, event.property_id, add_cash(zero_cash(), event), &add_cash(&1, event))
      end)

    properties =
      (Map.keys(opening) ++ Map.keys(movement_by_property))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      opening_held = Map.get(opening, property_id, 0)
      movement = Map.get(movement_by_property, property_id, zero_cash())
      closing_held = cash_closing(opening_held, movement)

      if opening_held != 0 or closing_held != 0 or
           Enum.any?(@cash_fields, &(Map.get(movement, &1) != 0)) do
        [
          %{
            property_id: property_id,
            opening_held_cents: opening_held,
            movements: movement,
            closing_held_cents: closing_held
          }
        ]
      else
        []
      end
    end)
  end

  defp zero_cash, do: Map.new(@cash_fields, &{&1, 0})

  defp add_cash(totals, event) do
    Enum.reduce(@cash_fields, totals, fn field, totals ->
      Map.update!(totals, field, &(&1 + Map.get(event, field, 0)))
    end)
  end

  defp cash_closing(opening, movement) do
    opening + movement.received_cents + movement.transferred_in_cents -
      movement.transferred_out_cents - movement.refunded_cents - movement.retained_cents -
      movement.converted_to_credit_cents - movement.reduced_cents - movement.charged_back_cents
  end

  defp credit_movements(events, starts_on, date) do
    totals =
      Enum.reduce(events, zero_credit(), fn event, totals ->
        %{
          totals
          | issued: totals.issued + event.credit_issued_cents,
            expired: totals.expired + event.credit_expired_cents,
            consumed: totals.consumed + event.credit_consumed_cents,
            revoked: totals.revoked + event.credit_revoked_cents,
            absorbed: totals.absorbed + event.credit_absorbed_cents
        }
      end)

    expired = totals.expired + expiring_credit(events, starts_on, date)

    totals
    |> Map.put(:expired, expired)
    |> Map.put(:movements, %{
      issued_cents: totals.issued,
      expired_cents: expired,
      consumed_cents: totals.consumed,
      revoked_cents: totals.revoked,
      absorbed_cents: totals.absorbed
    })
  end

  defp zero_credit, do: %{issued: 0, expired: 0, consumed: 0, revoked: 0, absorbed: 0}

  defp expiring_credit(events, starts_on, date) do
    opening =
      Repo.all(
        from credit in OpeningCredit,
          select: {credit.credit_lot_id, credit.available_cents}
      )
      |> Map.new()

    lot_ids =
      (Map.keys(opening) ++
         (events
          |> Enum.map(& &1.credit_lot_id)
          |> Enum.reject(&is_nil/1)))
      |> Enum.uniq()

    lots = Repo.all(from lot in CreditLot, where: lot.id in ^lot_ids)

    Enum.reduce(lots, 0, fn lot, expired_total ->
      issue_events =
        Enum.filter(events, &(&1.credit_lot_id == lot.id and &1.credit_issued_cents > 0))

      issue_date =
        case Enum.map(issue_events, & &1.posting_date) do
          [] -> nil
          dates -> Enum.min(dates)
        end

      expiry_date = effective_expiry_date(lot, issue_date)

      if Date.compare(expiry_date, starts_on) != :lt and
           Date.compare(expiry_date, date) != :gt do
        amount =
          if issue_date &&
               Date.compare(issue_date, Date.add(lot.expires_on, 1)) != :lt do
            Enum.sum(Enum.map(issue_events, & &1.credit_issued_cents))
          else
            available_at_expiry(lot.id, opening, events, lot.expires_on)
          end

        expired_total + max(amount, 0)
      else
        expired_total
      end
    end)
  end

  defp effective_expiry_date(%CreditLot{expires_on: expires_on}, nil),
    do: Date.add(expires_on, 1)

  defp effective_expiry_date(%CreditLot{expires_on: expires_on}, issue_date),
    do: max_date(Date.add(expires_on, 1), issue_date)

  defp max_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp available_at_expiry(lot_id, opening, events, expiry_date) do
    event_amount =
      events
      |> Enum.filter(fn event ->
        event.credit_lot_id == lot_id and
          Date.compare(event.posting_date, expiry_date) != :gt
      end)
      |> Enum.reduce(0, &(&2 + &1.credit_available_delta_cents))

    Map.get(opening, lot_id, 0) + event_amount
  end

  defp before_state(operation) do
    %{
      group: group_for_operation(operation),
      allocations: allocations_for_operation(operation),
      credit_applications: credit_applications_for_operation(operation),
      credit_lots: credit_lots_for_operation(operation),
      payment: payment_for_operation(operation),
      entitlements: entitlements_for_operation(operation),
      transfer: transfer_state(operation)
    }
  end

  defp credit_applications_for_operation(operation) do
    operation
    |> allocations_for_operation()
    |> Enum.map(& &1.credit_application_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> then(fn application_ids ->
      Repo.all(
        from application in CreditApplication,
          where: application.id in ^application_ids
      )
      |> Map.new(&{&1.id, &1})
    end)
  end

  defp credit_lots_for_operation(operation) do
    application_lot_ids =
      operation
      |> credit_applications_for_operation()
      |> Map.values()
      |> Enum.map(& &1.credit_lot_id)

    entitlement_lot_ids =
      operation
      |> entitlements_for_operation()
      |> Enum.map(& &1.credit_lot_id)

    (application_lot_ids ++ entitlement_lot_ids)
    |> Enum.uniq()
    |> then(fn lot_ids ->
      Repo.all(from lot in CreditLot, where: lot.id in ^lot_ids)
      |> Map.new(&{&1.id, &1})
    end)
  end

  defp group_for_operation(operation) do
    case value(operation, "group_id") do
      group_id when is_binary(group_id) -> Repo.get(Group, group_id)
      _ -> nil
    end
  end

  defp allocations_for_operation(operation) do
    type = value(operation, "type")
    group_id = value(operation, "group_id")
    payment_id = value(operation, "payment_operation_id")
    room_ids = value(operation, "room_ids")

    cond do
      type in ["cancel_group", "cancel_rooms"] and is_binary(group_id) ->
        allocations_for_rooms(group_id, room_ids)

      type in ["reduce_cash_payment", "charge_back_payment"] and is_binary(payment_id) ->
        Repo.all(
          from allocation in RoomFunding,
            join: room in Room,
            on:
              room.group_id == allocation.group_id and room.room_id == allocation.room_id and
                room.status == "active",
            where:
              allocation.source_type == "cash_payment" and allocation.source_id == ^payment_id,
            order_by: [desc: allocation.id]
        )

      type == "transfer_deposit" and is_binary(value(operation, "source_group_id")) ->
        source_group_id = value(operation, "source_group_id")

        Repo.all(
          from allocation in RoomFunding,
            join: room in Room,
            on:
              room.group_id == allocation.group_id and room.room_id == allocation.room_id and
                room.status == "active",
            where: allocation.group_id == ^source_group_id,
            order_by: [desc: allocation.id]
        )

      true ->
        []
    end
  end

  defp allocations_for_rooms(group_id, nil),
    do: Repo.all(from allocation in RoomFunding, where: allocation.group_id == ^group_id)

  defp allocations_for_rooms(group_id, room_ids) when is_list(room_ids) do
    Repo.all(
      from allocation in RoomFunding,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids
    )
  end

  defp allocations_for_rooms(_group_id, _room_ids), do: []

  defp payment_for_operation(operation) do
    case value(operation, "payment_operation_id") do
      payment_id when is_binary(payment_id) ->
        Repo.get_by(Payment, payment_operation_id: payment_id)

      _ ->
        nil
    end
  end

  defp entitlements_for_operation(operation) do
    case value(operation, "payment_operation_id") do
      payment_id when is_binary(payment_id) ->
        Repo.all(
          from entitlement in CreditEntitlement,
            where:
              entitlement.payment_operation_id == ^payment_id and
                entitlement.revoked_cents < entitlement.entitlement_cents,
            order_by: [asc: entitlement.id]
        )

      _ ->
        []
    end
  end

  defp transfer_state(operation) do
    if value(operation, "type") == "transfer_deposit" do
      %{
        source: Repo.get(Group, value(operation, "source_group_id")),
        destination: Repo.get(Group, value(operation, "destination_group_id"))
      }
    else
      %{source: nil, destination: nil}
    end
  end

  defp operation_events(operation, result, before, posting_date) do
    case value(operation, "type") do
      "record_cash_payment" ->
        cash_payment_events(operation, result)

      "apply_hotel_credit" ->
        apply_credit_events(operation)

      type when type in ["cancel_group", "cancel_rooms"] ->
        cancellation_events(operation, result, before)

      "reduce_cash_payment" ->
        reduction_events(operation, result, before)

      "charge_back_payment" ->
        chargeback_events(operation, before, posting_date)

      "transfer_deposit" ->
        transfer_events(operation, before)

      _ ->
        []
    end
  end

  defp cash_payment_events(operation, result) do
    with %Group{} = group <- Repo.get(Group, result[:group_id]),
         amount when is_integer(amount) <- result[:amount_cents] do
      [
        cash_event(group.property_id, %{
          received_cents: amount,
          payment_operation_id: operation_id(operation)
        })
      ]
    else
      _ -> []
    end
  end

  defp apply_credit_events(operation) do
    operation_id = operation_id(operation)

    Repo.all(
      from application in CreditApplication,
        where: application.funding_operation_id == ^operation_id
    )
    |> Enum.map(fn application ->
      %{
        credit_lot_id: application.credit_lot_id,
        credit_available_delta_cents: -application.amount_cents
      }
    end)
  end

  defp cancellation_events(operation, result, before) do
    group = before.group
    allocations = before.allocations

    cash_events =
      allocations
      |> Enum.filter(&(&1.funding_type == "cash"))
      |> Enum.group_by(&{&1.source_type, &1.source_id})
      |> Enum.map(fn {{source_type, source_id}, source_allocations} ->
        amount = Enum.map(source_allocations, & &1.amount_cents) |> Enum.sum()

        cash_event(group.property_id, %{
          cancellation_cash_field(result) => amount,
          payment_operation_id: if(source_type == "cash_payment", do: source_id)
        })
      end)

    cancellation_credit_events(
      operation,
      allocations,
      group,
      before.credit_applications,
      before.credit_lots
    ) ++
      issue_events(result, operation) ++ cash_events
  end

  defp cancellation_cash_field(result) do
    cond do
      result[:refunded_cents] > 0 -> :refunded_cents
      result[:retained_cents] > 0 -> :retained_cents
      true -> :converted_to_credit_cents
    end
  end

  defp cancellation_credit_events(
         operation,
         allocations,
         group,
         credit_applications,
         credit_lots
       ) do
    amounts_by_lot =
      allocations
      |> Enum.filter(&(&1.funding_type == "credit" and not is_nil(&1.credit_application_id)))
      |> Enum.reduce(%{}, fn allocation, amounts ->
        case Map.get(credit_applications, allocation.credit_application_id) do
          %CreditApplication{} = application ->
            Map.update(
              amounts,
              application.credit_lot_id,
              allocation.amount_cents,
              &(&1 + allocation.amount_cents)
            )

          nil ->
            amounts
        end
      end)

    occurred_on = Date.from_iso8601!(value(operation, "occurred_on"))
    refundable = refundable?(group, occurred_on)

    Enum.map(amounts_by_lot, fn {lot_id, amount} ->
      lot = Map.fetch!(credit_lots, lot_id)

      if refundable do
        absorbed = min(amount, lot.unrecovered_clawback_cents)
        rest = amount - absorbed

        if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt] do
          %{
            credit_lot_id: lot_id,
            credit_available_delta_cents: rest,
            credit_absorbed_cents: absorbed
          }
        else
          %{
            credit_lot_id: lot_id,
            credit_expired_cents: rest,
            credit_absorbed_cents: absorbed
          }
        end
      else
        %{credit_lot_id: lot_id, credit_consumed_cents: amount}
      end
    end)
  end

  defp issue_events(result, operation) do
    case result[:credit_issued_cents] do
      amount when is_integer(amount) and amount > 0 ->
        case Repo.get_by(CreditLot, source_operation_id: operation_id(operation)) do
          %CreditLot{} = lot ->
            [
              %{
                credit_lot_id: lot.id,
                credit_issued_cents: amount,
                credit_available_delta_cents: amount
              }
            ]

          nil ->
            []
        end

      _ ->
        []
    end
  end

  defp reduction_events(operation, result, before) do
    removed = take_allocations(before.allocations, result[:amount_cents])
    cash_event_by_group(removed, :reduced_cents, operation_id_for_payment(operation))
  end

  defp chargeback_events(operation, before, posting_date) do
    removed = take_allocations(before.allocations, before.payment.held_cents)

    held_events =
      cash_event_by_group(removed, :charged_back_cents, operation_id_for_payment(operation))

    payment_id = operation_id_for_payment(operation)

    opening_settlements =
      Repo.all(
        from disposition in OpeningDisposition,
          where: disposition.payment_operation_id == ^payment_id,
          select: {
            disposition.property_id,
            disposition.refunded_cents,
            disposition.retained_cents,
            disposition.converted_to_credit_cents
          }
      )

    opening_totals =
      Enum.reduce(opening_settlements, %{}, fn {property_id, refunded, retained, converted},
                                               totals ->
        add_settlement(totals, property_id, refunded, retained, converted)
      end)

    settled_events =
      Repo.all(
        from event in Event,
          where: event.payment_operation_id == ^payment_id,
          select: {
            event.property_id,
            event.refunded_cents,
            event.retained_cents,
            event.converted_to_credit_cents
          }
      )
      |> Enum.reduce(opening_totals, fn {property_id, refunded, retained, converted}, totals ->
        add_settlement(totals, property_id, refunded, retained, converted)
      end)
      |> Enum.flat_map(fn {property_id, totals} ->
        [
          cash_event(property_id, %{
            refunded_cents: -totals.refunded,
            retained_cents: -totals.retained,
            converted_to_credit_cents: -totals.converted,
            charged_back_cents: totals.refunded + totals.retained + totals.converted,
            payment_operation_id: payment_id
          })
        ]
      end)

    held_events ++ settled_events ++ chargeback_credit_events(before, posting_date)
  end

  defp add_settlement(totals, property_id, refunded, retained, converted) do
    Map.update(
      totals,
      property_id,
      %{refunded: refunded, retained: retained, converted: converted},
      fn current ->
        %{
          refunded: current.refunded + refunded,
          retained: current.retained + retained,
          converted: current.converted + converted
        }
      end
    )
  end

  defp chargeback_credit_events(before, posting_date) do
    {_remaining, events} =
      Enum.reduce(before.entitlements, {%{}, []}, fn entitlement, {remaining_by_lot, events} ->
        available_before =
          case Map.get(before.credit_lots, entitlement.credit_lot_id) do
            %CreditLot{expires_on: expires_on, remaining_cents: remaining} ->
              if Date.compare(posting_date, expires_on) == :gt do
                0
              else
                Map.get(remaining_by_lot, entitlement.credit_lot_id, remaining)
              end

            nil ->
              0
          end

        amount = entitlement.entitlement_cents - entitlement.revoked_cents
        revoked = min(available_before, amount)

        {
          Map.put(remaining_by_lot, entitlement.credit_lot_id, available_before - revoked),
          [
            %{
              credit_lot_id: entitlement.credit_lot_id,
              credit_available_delta_cents: -revoked,
              credit_revoked_cents: revoked
            }
            | events
          ]
        }
      end)

    events
  end

  defp transfer_events(operation, before) do
    moved = take_allocations(before.allocations, value(operation, "amount_cents"))

    cash_amount =
      moved
      |> Enum.filter(fn {allocation, _amount} -> allocation.funding_type == "cash" end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    source = before.transfer.source
    destination = before.transfer.destination

    cond do
      cash_amount == 0 or is_nil(source) or is_nil(destination) ->
        []

      source.property_id == destination.property_id ->
        [
          cash_event(source.property_id, %{
            transferred_in_cents: cash_amount,
            transferred_out_cents: cash_amount
          })
        ]

      true ->
        [
          cash_event(source.property_id, %{transferred_out_cents: cash_amount}),
          cash_event(destination.property_id, %{transferred_in_cents: cash_amount})
        ]
    end
  end

  defp take_allocations(allocations, amount) when is_integer(amount) and amount > 0 do
    {_, selected} =
      Enum.reduce_while(allocations, {amount, []}, fn allocation, {remaining, selected} ->
        moved = min(remaining, allocation.amount_cents)

        if moved == 0 do
          {:halt, {remaining, selected}}
        else
          {:cont, {remaining - moved, [{allocation, moved} | selected]}}
        end
      end)

    selected
  end

  defp take_allocations(_allocations, _amount), do: []

  defp cash_event(property_id, attrs), do: Map.merge(%{property_id: property_id}, attrs)

  defp cash_event_by_group(allocations, field, payment_id) do
    allocations
    |> Enum.group_by(fn {allocation, _amount} -> allocation.group_id end)
    |> Enum.map(fn {group_id, group_allocations} ->
      group = Repo.get!(Group, group_id)
      amount = Enum.map(group_allocations, &elem(&1, 1)) |> Enum.sum()
      cash_event(group.property_id, %{field => amount, payment_operation_id: payment_id})
    end)
  end

  defp operation_id_for_payment(operation), do: value(operation, "payment_operation_id")

  defp opening_cash do
    Repo.all(
      from allocation in RoomFunding,
        join: room in Room,
        on:
          room.group_id == allocation.group_id and room.room_id == allocation.room_id and
            room.status == "active",
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: allocation.funding_type == "cash",
        group_by: group.property_id,
        order_by: [asc: group.property_id],
        select: {group.property_id, sum(allocation.amount_cents)}
    )
  end

  defp opening_credit(starts_on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.expires_on >= ^starts_on,
        select: {lot.id, lot.remaining_cents}
    )
  end

  defp opening_dispositions do
    Repo.all(
      from payment in Payment,
        join: group in Group,
        on: group.group_id == payment.group_id,
        where:
          payment.refunded_cents > 0 or payment.retained_cents > 0 or
            payment.converted_to_credit_cents > 0,
        select: %{
          payment_operation_id: payment.payment_operation_id,
          property_id: group.property_id,
          refunded_cents: payment.refunded_cents,
          retained_cents: payment.retained_cents,
          converted_to_credit_cents: payment.converted_to_credit_cents
        }
    )
  end

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^as_of,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from allocation in RoomFunding,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active" and allocation.funding_type == "credit",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp posting_date(operation, starts_on) do
    occurred_on = Date.from_iso8601!(value(operation, "occurred_on"))
    max_date(occurred_on, starts_on)
  end

  defp refundable?(%Group{} = group, %Date{} = occurred_on) do
    policy = group.policy_version || policy_version(group.rate_plan, group.booked_on)

    case policy do
      "flex-14" -> Date.diff(group.arrival_on, occurred_on) >= 14
      "flex-30" -> Date.diff(group.arrival_on, occurred_on) >= 30
      _ -> false
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp value(operation, key) when is_map(operation) do
    Map.get(operation, key) || Map.get(operation, String.to_atom(key))
  end

  defp value(_operation, _key), do: nil
  defp operation_id(operation), do: value(operation, "operation_id")
end
