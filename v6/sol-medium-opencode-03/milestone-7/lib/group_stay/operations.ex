defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{
    AllocationOrder,
    CashAllocation,
    CashDisposition,
    CashPayment,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    FinanceCreditExpiryAdjustment,
    FinanceMovement,
    FinancePeriodClose,
    FinanceReporting,
    Group,
    OperationRecord,
    Repo,
    Room
  }

  @rate_plans ~w(flexible advance_purchase)

  def submit(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, :group_not_found}
          group -> {:ok, preload_group(group)}
        end
      end)

    result
  end

  def get_operation(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, deserialize_result(record.result)}
    end
  end

  def get_payment(operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          nil -> {:error, :operation_not_found}
          _record -> payment_statement(operation_id)
        end
      end)

    result
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  def daily_finance_report(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(FinanceReporting, singleton: 1) do
          nil ->
            {:error, :report_not_available}

          %{starts_on: starts_on} when date < starts_on ->
            {:error, :report_not_available}

          reporting ->
            close =
              Repo.one(
                from c in FinancePeriodClose,
                  where: c.period_end_on >= ^date,
                  order_by: c.period_end_on,
                  limit: 1
              )

            {:ok, build_daily_report(reporting, date, close)}
        end
      end)

    result
  end

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  defp build_daily_report(reporting, date, close) do
    movements = finance_movements_through(date, close)

    cash_rows = Enum.reject(movements, &is_nil(&1.property_id))

    properties =
      (Map.keys(reporting.opening_cash) ++ Enum.map(cash_rows, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        property_rows = Enum.filter(cash_rows, &(&1.property_id == property_id))
        prior = Enum.filter(property_rows, &(&1.posting_date < date))
        current = Enum.filter(property_rows, &(&1.posting_date == date))
        ordinary = Enum.reject(current, & &1.late_adjustment)
        late = Enum.filter(current, & &1.late_adjustment)
        opening = Map.get(reporting.opening_cash, property_id, 0) + cash_delta(prior)
        movement = sum_fields(ordinary, @cash_fields)
        late_movement = sum_fields(late, @cash_fields)
        closing = opening + cash_delta(movement) + cash_delta(late_movement)

        {%{
           property_id: property_id,
           opening_held_cents: opening,
           movements: movement,
           closing_held_cents: closing
         }, late_movement}
      end)
      |> Enum.reject(fn {row, late} ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          Enum.all?(@cash_fields, &(row.movements[&1] == 0)) and
          Enum.all?(@cash_fields, &(late[&1] == 0))
      end)

    cash_rows = Enum.map(cash, &elem(&1, 0))

    late_cash =
      cash
      |> Enum.map(fn {row, movement} -> %{property_id: row.property_id, movements: movement} end)
      |> Enum.reject(fn row -> Enum.all?(@cash_fields, &(row.movements[&1] == 0)) end)

    credit_rows = Enum.filter(movements, &is_nil(&1.property_id))
    prior_credit = Enum.filter(credit_rows, &(&1.posting_date < date))
    current_credit = Enum.filter(credit_rows, &(&1.posting_date == date))
    ordinary_credit = Enum.reject(current_credit, & &1.late_adjustment)
    late_credit = Enum.filter(current_credit, & &1.late_adjustment)
    prior_expiry = expiry_total_before(date, close)
    today_expiry = expiry_total_on(date, close)
    opening_credit = reporting.opening_credit_cents + credit_delta(prior_credit) - prior_expiry

    credit_movement =
      ordinary_credit
      |> sum_fields(@credit_fields)
      |> Map.update!(:expired_cents, &(&1 + today_expiry))

    late_credit_movement = sum_fields(late_credit, @credit_fields)

    %{
      date: Date.to_iso8601(date),
      status: if(close, do: "closed", else: "open"),
      cash: cash_rows,
      credit: %{
        opening_liability_cents: opening_credit,
        movements: credit_movement,
        closing_liability_cents:
          opening_credit + credit_delta(credit_movement) + credit_delta(late_credit_movement)
      },
      late_adjustments: %{cash: late_cash, credit: late_credit_movement}
    }
  end

  defp finance_movements_through(date, nil) do
    Repo.all(from m in FinanceMovement, where: m.posting_date <= ^date)
  end

  defp finance_movements_through(date, close) do
    Repo.all(
      from m in FinanceMovement,
        join: o in OperationRecord,
        on: o.operation_id == m.operation_id,
        where: m.posting_date <= ^date and o.id <= ^close.operation_record_cutoff_id
    )
  end

  defp sum_fields(rows, fields) when is_list(rows),
    do: Map.new(fields, fn field -> {field, Enum.sum(Enum.map(rows, &Map.fetch!(&1, field)))} end)

  defp cash_delta(rows) when is_list(rows), do: rows |> sum_fields(@cash_fields) |> cash_delta()

  defp cash_delta(values) do
    values.received_cents + values.transferred_in_cents - values.transferred_out_cents -
      values.refunded_cents - values.retained_cents - values.converted_to_credit_cents -
      values.reduced_cents - values.charged_back_cents
  end

  defp credit_delta(rows) when is_list(rows),
    do: rows |> sum_fields(@credit_fields) |> credit_delta()

  defp credit_delta(values),
    do:
      values.issued_cents - values.expired_cents - values.consumed_cents -
        values.revoked_cents - values.absorbed_cents

  defp expiry_total_before(date, close), do: expiry_total(:before, date, close)
  defp expiry_total_on(date, close), do: expiry_total(:on, date, close)

  defp expiry_total(comparison, date, close) do
    date_filter =
      case comparison do
        :before -> dynamic([e], e.expires_on < ^date)
        :on -> dynamic([e], e.expires_on == ^date)
      end

    query =
      from e in FinanceCreditExpiryAdjustment,
        left_join: o in OperationRecord,
        on: o.operation_id == e.operation_id,
        where: ^date_filter,
        select: coalesce(sum(e.amount_cents), 0)

    query =
      if close do
        from [e, o] in query,
          where: is_nil(e.operation_id) or o.id <= ^close.operation_record_cutoff_id
      else
        query
      end

    Repo.one(query)
  end

  defp ledger_totals(on) do
    cash_held =
      Repo.one(
        from a in CashAllocation,
          join: r in assoc(a, :room),
          where: r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    cash =
      Repo.one(
        from g in Group,
          select: %{
            cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    payment_totals =
      Repo.one(
        from p in CashPayment,
          select: %{
            cash_reduced_cents: coalesce(sum(p.reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(p.charged_back_cents), 0)
          }
      )

    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on > ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in CreditAllocation,
          join: r in assoc(a, :room),
          where: r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    # SQLite cannot express min(unrecovered, applied) portably through Ecto's aggregate DSL.
    shortfall =
      Repo.all(
        from l in CreditLot,
          left_join: a in assoc(l, :allocations),
          left_join: r in assoc(a, :room),
          group_by: [l.id, l.unrecovered_clawback_cents],
          select:
            {l.unrecovered_clawback_cents,
             coalesce(
               sum(
                 fragment("CASE WHEN ? = 'active' THEN ? ELSE 0 END", r.status, a.amount_cents)
               ),
               0
             )}
      )
      |> Enum.sum_by(fn {unrecovered, active} -> min(unrecovered, active) end)

    cash
    |> Map.merge(payment_totals)
    |> Map.merge(%{
      cash_held_cents: cash_held,
      credit_liability_cents: available + applied,
      credit_shortfall_cents: shortfall
    })
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
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

  def serialize_group(group) do
    rooms = Enum.map(group.rooms, &serialize_room/1)
    active = Enum.filter(rooms, &(&1.status == "active"))
    lodging = Enum.sum(Enum.map(active, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(active, & &1.deposit_due_cents))
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: format_date(refundable_until(group)),
      status: group.status,
      revision: group.revision,
      rooms: rooms,
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: due - cash - credit
    }
  end

  defp serialize_room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      lodging_total_cents: room.lodging_total_cents,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: Enum.sum(Enum.map(room.cash_allocations, & &1.amount_cents)),
      credit_paid_cents: Enum.sum(Enum.map(room.credit_allocations, & &1.amount_cents))
    }
  end

  defp process(operation) when is_map(operation) do
    operation_id = operation["operation_id"]

    if valid_identifier?(operation_id) do
      {:ok, result} =
        Repo.transaction(fn -> process_durable(operation, operation_id) end, mode: :immediate)

      result
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process(_operation), do: rejected(nil, "invalid_operation")

  defp process_durable(operation, operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      %OperationRecord{submission: submission, result: result} ->
        if submission === operation,
          do: deserialize_result(result),
          else: rejected(operation_id, "operation_id_conflict")

      nil ->
        result = process_new(operation, operation_id)

        %OperationRecord{}
        |> OperationRecord.changeset(%{
          operation_id: operation_id,
          operation_type: operation_type(operation),
          submission: operation,
          result: result
        })
        |> Repo.insert!()

        result
    end
  end

  defp process_new(%{"type" => "start_finance_reporting"} = operation, operation_id) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} ->
        case Repo.get_by(FinanceReporting, singleton: 1) do
          nil ->
            start_finance_reporting!(starts_on)

            %{
              operation_id: operation_id,
              status: "applied",
              starts_on: Date.to_iso8601(starts_on)
            }

          _ ->
            rejected(operation_id, "reporting_already_started")
        end

      :error ->
        rejected(operation_id, "invalid_reporting_date")
    end
  end

  defp process_new(%{"type" => "close_finance_period"} = operation, operation_id) do
    with {:ok, period_end_on} <- parse_date(operation["period_end_on"]),
         %FinanceReporting{starts_on: starts_on} <-
           Repo.get_by(FinanceReporting, singleton: 1),
         true <- Date.compare(period_end_on, starts_on) != :lt,
         true <- later_than_latest_close?(period_end_on) do
      cutoff = Repo.one(from o in OperationRecord, select: coalesce(max(o.id), 0))

      Repo.insert!(%FinancePeriodClose{
        period_end_on: period_end_on,
        operation_record_cutoff_id: cutoff
      })

      %{
        operation_id: operation_id,
        status: "applied",
        period_end_on: Date.to_iso8601(period_end_on)
      }
    else
      _ -> rejected(operation_id, "invalid_period")
    end
  end

  defp process_new(operation, operation_id) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         reporting = Repo.get_by(FinanceReporting, singleton: 1),
         posting_date = reporting_posting_date(reporting, occurred_on),
         before = finance_snapshot(reporting, posting_date),
         {:ok, result} <- dispatch(operation, occurred_on) do
      applied = Map.merge(%{operation_id: operation_id, status: "applied"}, result)

      if reporting,
        do: record_finance_movement!(operation, occurred_on, posting_date, applied, before)

      applied
    else
      :error ->
        rejected(operation_id, "invalid_operation")

      {:error, result} when is_map(result) ->
        result |> Map.put(:operation_id, operation_id) |> Map.put(:status, "rejected")

      {:error, code} ->
        rejected(operation_id, code)
    end
  end

  defp later_than_latest_close?(period_end_on) do
    case Repo.one(from c in FinancePeriodClose, select: max(c.period_end_on)) do
      nil -> true
      latest -> Date.compare(period_end_on, latest) == :gt
    end
  end

  defp reporting_posting_date(nil, _occurred_on), do: nil

  defp reporting_posting_date(reporting, occurred_on) do
    natural_date = max_date(occurred_on, reporting.starts_on)

    case Repo.one(from c in FinancePeriodClose, select: max(c.period_end_on)) do
      nil -> natural_date
      latest -> max_date(natural_date, Date.add(latest, 1))
    end
  end

  defp start_finance_reporting!(starts_on) do
    snapshot = finance_snapshot(%FinanceReporting{starts_on: starts_on}, starts_on)

    Repo.insert!(%FinanceReporting{
      singleton: 1,
      starts_on: starts_on,
      opening_cash: snapshot.held,
      opening_credit_cents: snapshot.credit_liability
    })

    Repo.all(from l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^starts_on)
    |> Enum.each(&adjust_expiry!(&1, &1.remaining_cents, nil))
  end

  defp finance_snapshot(nil, _occurred_on), do: nil

  defp finance_snapshot(reporting, occurred_on) do
    on = max_date(occurred_on, reporting.starts_on)

    held =
      Repo.all(
        from a in CashAllocation,
          join: r in assoc(a, :room),
          join: g in assoc(r, :group),
          where: r.status == "active",
          group_by: g.property_id,
          select: {g.property_id, sum(a.amount_cents)}
      )
      |> Map.new()

    held_by_group =
      Repo.all(
        from a in CashAllocation,
          join: r in assoc(a, :room),
          join: g in assoc(r, :group),
          where: r.status == "active",
          group_by: g.group_id,
          select: {g.group_id, sum(a.amount_cents)}
      )
      |> Map.new()

    dispositions =
      Repo.all(
        from g in Group,
          group_by: g.property_id,
          select:
            {g.property_id, sum(g.refunded_cents), sum(g.retained_cents),
             sum(g.cash_converted_to_credit_cents)}
      )
      |> Map.new(fn {property, refunded, retained, converted} ->
        {property, %{refunded: refunded, retained: retained, converted: converted}}
      end)

    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on > ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in CreditAllocation,
          join: r in assoc(a, :room),
          where: r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    unrecovered =
      Repo.one(from l in CreditLot, select: coalesce(sum(l.unrecovered_clawback_cents), 0))

    %{
      held: held,
      held_by_group: held_by_group,
      dispositions: dispositions,
      credit_liability: available + applied,
      unrecovered: unrecovered
    }
  end

  defp record_finance_movement!(operation, occurred_on, posting_date, result, before) do
    reporting = Repo.get_by!(FinanceReporting, singleton: 1)
    natural_date = max_date(occurred_on, reporting.starts_on)
    late_adjustment = Date.compare(posting_date, natural_date) == :gt
    after_snapshot = finance_snapshot(reporting, posting_date)
    type = operation["type"]

    properties =
      (Map.keys(before.held) ++
         Map.keys(after_snapshot.held) ++
         Map.keys(before.dispositions) ++ Map.keys(after_snapshot.dispositions))
      |> Enum.uniq()

    cash_rows =
      if type == "transfer_deposit" do
        source = Repo.get_by!(Group, group_id: operation["source_group_id"])
        destination = Repo.get_by!(Group, group_id: operation["destination_group_id"])

        cash_moved =
          Map.get(before.held_by_group, source.group_id, 0) -
            Map.get(after_snapshot.held_by_group, source.group_id, 0)

        cond do
          cash_moved == 0 ->
            []

          source.property_id == destination.property_id ->
            [
              {source.property_id,
               %{transferred_in_cents: cash_moved, transferred_out_cents: cash_moved}}
            ]

          true ->
            [
              {source.property_id, %{transferred_out_cents: cash_moved}},
              {destination.property_id, %{transferred_in_cents: cash_moved}}
            ]
        end
      else
        Enum.flat_map(properties, fn property ->
          held_delta =
            Map.get(after_snapshot.held, property, 0) - Map.get(before.held, property, 0)

          old_d =
            Map.get(before.dispositions, property, %{refunded: 0, retained: 0, converted: 0})

          new_d =
            Map.get(after_snapshot.dispositions, property, %{
              refunded: 0,
              retained: 0,
              converted: 0
            })

          refunded = new_d.refunded - old_d.refunded
          retained = new_d.retained - old_d.retained
          converted = new_d.converted - old_d.converted

          values =
            case type do
              "record_cash_payment" ->
                %{received_cents: max(held_delta, 0)}

              type when type in ~w(cancel_group cancel_rooms) ->
                %{
                  refunded_cents: refunded,
                  retained_cents: retained,
                  converted_to_credit_cents: converted
                }

              "reduce_cash_payment" ->
                %{reduced_cents: max(-held_delta, 0)}

              "charge_back_payment" ->
                %{
                  refunded_cents: refunded,
                  retained_cents: retained,
                  converted_to_credit_cents: converted,
                  charged_back_cents: max(-held_delta, 0) - refunded - retained - converted
                }

              _ ->
                %{}
            end

          if Enum.any?(values, fn {_key, value} -> value != 0 end),
            do: [{property, values}],
            else: []
        end)
      end

    credit_delta = after_snapshot.credit_liability - before.credit_liability
    absorbed = max(before.unrecovered - after_snapshot.unrecovered, 0)
    issued = result[:credit_issued_cents] || 0

    credit_values =
      case type do
        type when type in ~w(cancel_group cancel_rooms) ->
          group = Repo.get_by!(Group, group_id: operation["group_id"])

          if refundable?(group, occurred_on) do
            %{
              issued_cents: issued,
              absorbed_cents: absorbed,
              expired_cents: max(issued - absorbed - credit_delta, 0)
            }
          else
            %{consumed_cents: max(-credit_delta, 0)}
          end

        "charge_back_payment" ->
          %{revoked_cents: max(-credit_delta, 0)}

        _ ->
          if credit_delta == 0, do: %{}, else: %{expired_cents: -credit_delta}
      end

    Enum.each(cash_rows, fn {property, values} ->
      insert_finance_movement!(
        operation["operation_id"],
        posting_date,
        property,
        late_adjustment,
        values
      )
    end)

    if Enum.any?(credit_values, fn {_key, value} -> value != 0 end) do
      insert_finance_movement!(
        operation["operation_id"],
        posting_date,
        nil,
        late_adjustment,
        credit_values
      )
    end
  end

  defp insert_finance_movement!(
         operation_id,
         posting_date,
         property_id,
         late_adjustment,
         values
       ) do
    Repo.insert!(
      struct!(
        FinanceMovement,
        Map.merge(values, %{
          operation_id: operation_id,
          posting_date: posting_date,
          property_id: property_id,
          late_adjustment: late_adjustment
        })
      )
    )
  end

  defp max_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)

  defp adjust_expiry!(_lot, 0, _operation_id), do: :ok

  defp adjust_expiry!(lot, amount, operation_id) do
    case Repo.get_by(FinanceReporting, singleton: 1) do
      nil ->
        :ok

      reporting ->
        expiry_date = Date.add(lot.expires_on, 1)

        first_open_on = reporting_posting_date(reporting, reporting.starts_on)

        if Date.compare(expiry_date, first_open_on) == :gt do
          Repo.insert!(%FinanceCreditExpiryAdjustment{
            operation_id: operation_id,
            expires_on: expiry_date,
            amount_cents: amount
          })
        end

        :ok
    end
  end

  defp dispatch(%{"type" => "open_group"} = operation, occurred_on) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if required_fields?(operation, required),
      do: open_group(operation, occurred_on),
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => type} = operation, occurred_on)
       when type in ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms) do
    required =
      case type do
        "record_cash_payment" -> ~w(group_id amount_cents)
        "apply_hotel_credit" -> ~w(group_id amount_cents)
        "reschedule_group" -> ~w(group_id new_arrival_on)
        "cancel_group" -> ~w(group_id)
        "cancel_rooms" -> ~w(group_id room_ids)
      end

    dispatch_update(operation, occurred_on, required)
  end

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation, _occurred_on) do
    if required_fields?(operation, ~w(payment_operation_id amount_cents)),
      do: reduce_cash_payment(operation),
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => "charge_back_payment"} = operation, _occurred_on) do
    if required_fields?(operation, ~w(payment_operation_id)),
      do: charge_back_payment(operation),
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => "transfer_deposit"} = operation, _occurred_on) do
    if required_fields?(operation, ~w(source_group_id destination_group_id amount_cents)),
      do: transfer_deposit(operation),
      else: {:error, "invalid_operation"}
  end

  defp dispatch(_operation, _occurred_on), do: {:error, "invalid_operation"}

  defp open_group(operation, booked_on) do
    with {:ok, attrs, room_attrs} <- opening_attrs(operation, booked_on) do
      case Repo.insert(Group.create_changeset(attrs)) do
        {:ok, group} ->
          now = now()

          rooms =
            room_attrs
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              Map.merge(room, %{
                group_record_id: group.id,
                position: position,
                inserted_at: now,
                updated_at: now
              })
            end)

          {count, _} = Repo.insert_all(Room, rooms)
          if count != length(rooms), do: raise("failed to persist all rooms")

          {:ok,
           %{group_id: group.group_id, deposit_due_cents: group.deposit_due_cents, revision: 1}}

        {:error, changeset} ->
          if unique_error?(changeset, :group_id),
            do: {:error, "group_already_exists"},
            else: {:error, "invalid_operation"}
      end
    end
  end

  defp opening_attrs(operation, booked_on) do
    with true <- identifiers?(operation, ~w(group_id guest_id property_id)),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt || {:domain, "invalid_stay"},
         rate_plan when rate_plan in @rate_plans <-
           operation["rate_plan"] || {:domain, "invalid_rate_plan"},
         {:ok, rooms} <-
           room_attrs(operation["rooms"], Date.diff(departure_on, arrival_on), rate_plan) do
      lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
      deposit = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

      {:ok,
       %{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         policy_version: policy_version(rate_plan, booked_on),
         status: "active",
         revision: 1,
         lodging_total_cents: lodging,
         deposit_due_cents: deposit
       }, rooms}
    else
      false -> {:error, "invalid_operation"}
      :error -> {:error, "invalid_stay"}
      {:domain, code} -> {:error, code}
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp room_attrs(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(
        rooms,
        &(is_map(&1) and valid_identifier?(&1["room_id"]) and is_integer(&1["nightly_rate_cents"]) and
            &1["nightly_rate_cents"] > 0)
      )

    unique = Enum.uniq_by(rooms, & &1["room_id"]) |> length() == length(rooms)

    if valid and unique do
      {:ok,
       Enum.map(rooms, fn room ->
         lodging = nights * room["nightly_rate_cents"]
         deposit = if rate_plan == "flexible", do: rounded_percent(lodging, 20), else: lodging

         %{
           room_id: room["room_id"],
           nightly_rate_cents: room["nightly_rate_cents"],
           status: "active",
           lodging_total_cents: lodging,
           deposit_due_cents: deposit
         }
       end)}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp room_attrs(_, _, _), do: {:error, "invalid_rooms"}

  defp dispatch_update(operation, occurred_on, required) do
    if required_fields?(operation, required),
      do: update_group(operation, occurred_on),
      else: {:error, "invalid_operation"}
  end

  defp update_group(operation, occurred_on) do
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> {:error, "group_not_found"}
        group -> normalize_apply_result(apply_to_group(group, operation, occurred_on))
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp apply_to_group(group, operation, occurred_on) do
    case check_revision(group, operation) do
      :ok ->
        if group.status == "active",
          do: apply_active(group, operation, occurred_on),
          else: {:error, "group_not_active"}

      error ->
        error
    end
  end

  defp apply_active(group, %{"type" => "record_cash_payment"} = operation, _occurred_on) do
    amount = operation["amount_cents"]

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > outstanding(group) ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        payment =
          Repo.insert!(%CashPayment{
            payment_operation_id: operation["operation_id"],
            group_record_id: group.id,
            recorded_cents: amount
          })

        allocate_cash!(group, payment, amount)
        group = sync_group!(group)

        %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        }
    end
  end

  defp apply_active(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on) do
    amount = operation["amount_cents"]

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > outstanding(group) ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        lots = available_lots(group.guest_id, occurred_on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          {:error, "insufficient_credit"}
        else
          allocate_credit!(lots, group, operation["operation_id"], amount)
          group = sync_group!(group)

          %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(group),
            revision: group.revision
          }
        end
    end
  end

  defp apply_active(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      new_departure = Date.add(new_arrival, Date.diff(group.departure_on, group.arrival_on))
      group = update!(group, arrival_on: new_arrival, departure_on: new_departure)

      %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival),
        new_departure_on: Date.to_iso8601(new_departure),
        policy_version: group.policy_version,
        refundable_until: format_date(refundable_until(group)),
        revision: group.revision
      }
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp apply_active(group, %{"type" => "cancel_group"} = operation, occurred_on) do
    rooms = active_rooms(group.id)
    settle_rooms(group, rooms, operation, occurred_on, false)
  end

  defp apply_active(group, %{"type" => "cancel_rooms"} = operation, occurred_on) do
    room_ids = operation["room_ids"]
    active = active_rooms(group.id)

    valid =
      is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &valid_identifier?/1) and
        length(Enum.uniq(room_ids)) == length(room_ids)

    selected = if valid, do: Enum.filter(active, &(&1.room_id in room_ids)), else: []

    if valid and length(selected) == length(room_ids),
      do: settle_rooms(group, selected, operation, occurred_on, true),
      else: {:error, "invalid_rooms"}
  end

  defp settle_rooms(group, rooms, operation, occurred_on, partial?) do
    refund_method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred_on)

    cond do
      refund_method not in ~w(cash hotel_credit) ->
        {:error, "invalid_operation"}

      refund_method == "hotel_credit" and not refundable ->
        {:error, "refund_method_not_available"}

      true ->
        do_settle_rooms(group, rooms, operation, occurred_on, refundable, refund_method, partial?)
    end
  end

  defp do_settle_rooms(group, rooms, operation, occurred_on, refundable, refund_method, partial?) do
    room_ids = Enum.map(rooms, & &1.id)

    cash_allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.room_id in ^room_ids,
          order_by: a.id,
          preload: [:cash_payment]
      )

    credit_allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.room_id in ^room_ids,
          order_by: a.id,
          preload: [:credit_lot]
      )

    cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    refunded = if refundable and refund_method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash
    converted = if refundable and refund_method == "hotel_credit", do: cash, else: 0

    disposition =
      if refunded > 0,
        do: :refunded_cents,
        else: if(retained > 0, do: :retained_cents, else: :converted_to_credit_cents)

    update_payment_dispositions!(cash_allocations, group.id, disposition)

    if refundable,
      do: restore_credit!(credit_allocations, occurred_on, operation["operation_id"])

    Enum.each(credit_allocations, &delete_allocation!/1)

    credit_issued = issue_credit!(group, operation, occurred_on, converted, cash_allocations)
    Enum.each(cash_allocations, &delete_allocation!/1)

    from(r in Room, where: r.id in ^room_ids)
    |> Repo.update_all(set: [status: "cancelled", updated_at: now()])

    remaining? =
      Repo.exists?(from r in Room, where: r.group_record_id == ^group.id and r.status == "active")

    group =
      sync_group!(group,
        status: if(remaining?, do: "active", else: "cancelled"),
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      )

    base = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: group.revision
    }

    if partial?, do: Map.put(base, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)), else: base
  end

  defp transfer_deposit(operation) do
    source_id = operation["source_group_id"]
    destination_id = operation["destination_group_id"]

    with true <- valid_identifier?(source_id) and valid_identifier?(destination_id),
         {:ok, source} <- transfer_group(source_id),
         {:ok, destination} <- transfer_group(destination_id),
         :ok <- normalize_check_revision(source, operation),
         :ok <- check_destination_revision(destination, operation) do
      amount = operation["amount_cents"]

      cond do
        source.id == destination.id or source.guest_id != destination.guest_id ->
          {:error, "invalid_transfer"}

        source.status != "active" ->
          group_error("group_not_active", source.group_id)

        destination.status != "active" ->
          group_error("group_not_active", destination.group_id)

        not is_integer(amount) or amount <= 0 ->
          {:error, "invalid_amount"}

        held_funding(source.id) < amount ->
          {:error, "transfer_exceeds_held_funding"}

        outstanding(destination) < amount ->
          {:error, "transfer_exceeds_outstanding"}

        true ->
          chunks = draw_transfer_chunks!(source.id, amount)
          place_transfer_chunks!(destination, chunks)

          chunks
          |> Enum.flat_map(fn
            {:cash, nil, _} -> []
            {:cash, payment_id, _} -> [payment_id]
            _ -> []
          end)
          |> Enum.uniq()
          |> mark_payments_transferred!()

          source = sync_group!(source)
          destination = sync_group!(destination)

          {:ok,
           %{
             source_group_id: source.group_id,
             destination_group_id: destination.group_id,
             amount_cents: amount,
             source_outstanding_deposit_cents: outstanding(source),
             destination_outstanding_deposit_cents: outstanding(destination),
             source_revision: source.revision,
             destination_revision: destination.revision
           }}
      end
    else
      false -> {:error, "invalid_operation"}
      error -> error
    end
  end

  defp transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> group_error("group_not_found", group_id)
      group -> {:ok, group}
    end
  end

  defp check_destination_revision(group, operation) do
    expected = operation["destination_expected_revision"]

    if not is_nil(expected) and expected != group.revision,
      do:
        {:error,
         %{
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }},
      else: :ok
  end

  defp held_funding(group_id) do
    cash =
      Repo.one(
        from a in CashAllocation,
          join: r in assoc(a, :room),
          where: r.group_record_id == ^group_id and r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          join: r in assoc(a, :room),
          where: r.group_record_id == ^group_id and r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    cash + credit
  end

  defp draw_transfer_chunks!(source_group_id, amount) do
    allocations =
      Repo.all(
        from o in AllocationOrder,
          left_join: cash in CashAllocation,
          on: cash.allocation_order_id == o.id,
          left_join: credit in CreditAllocation,
          on: credit.allocation_order_id == o.id,
          left_join: cash_room in Room,
          on: cash.room_id == cash_room.id,
          left_join: credit_room in Room,
          on: credit.room_id == credit_room.id,
          where:
            (cash_room.group_record_id == ^source_group_id and cash_room.status == "active") or
              (credit_room.group_record_id == ^source_group_id and credit_room.status == "active"),
          order_by: [desc: o.id],
          select: {o, cash, credit}
      )

    {_remaining, chunks} =
      Enum.reduce_while(allocations, {amount, []}, fn {order, cash, credit},
                                                      {remaining, chunks} ->
        allocation = cash || credit
        moved = min(allocation.amount_cents, remaining)

        chunk =
          if cash,
            do: {:cash, cash.cash_payment_id, moved},
            else: {:credit, credit.credit_lot_id, credit.funding_operation_id, moved}

        if moved == allocation.amount_cents do
          Repo.delete!(allocation)
          Repo.delete!(order)
        else
          reduce_allocation!(allocation, moved)
        end

        state = {remaining - moved, chunks ++ [chunk]}
        if moved == remaining, do: {:halt, state}, else: {:cont, state}
      end)

    chunks
  end

  defp place_transfer_chunks!(destination, chunks) do
    Enum.reduce(chunks, active_rooms(destination.id), fn chunk, rooms ->
      amount = elem(chunk, tuple_size(chunk) - 1)

      {_remaining, rooms} =
        fill_room_list!(rooms, amount, fn room, used ->
          case chunk do
            {:cash, payment_id, _} ->
              insert_cash_allocation!(room.id, payment_id, used)

            {:credit, lot_id, operation_id, _} ->
              insert_credit_allocation!(destination.id, room.id, lot_id, operation_id, used)
          end
        end)

      rooms
    end)
  end

  defp mark_payments_transferred!([]), do: :ok

  defp mark_payments_transferred!(payment_ids) do
    from(p in CashPayment, where: p.id in ^payment_ids)
    |> Repo.update_all(set: [participated_in_transfer: true, updated_at: now()])
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment, group} <-
           target_payment(operation["payment_operation_id"], "payment_not_reducible"),
         :ok <- normalize_check_revision(group, operation) do
      amount = operation["amount_cents"]
      held = held_allocations(payment.id)
      held_total = Enum.sum(Enum.map(held, & &1.amount_cents))

      cond do
        not is_integer(amount) or amount <= 0 ->
          {:error, "invalid_amount"}

        held_total == 0 ->
          {:error, "payment_not_reducible"}

        amount > held_total ->
          {:error, "reduction_exceeds_held_cash"}

        true ->
          affected_group_ids = allocation_group_ids_for_amount(held, amount)
          remove_allocations!(held, amount)
          update_payment!(payment, reduced_cents: payment.reduced_cents + amount)
          groups = sync_groups!([group.id | affected_group_ids])
          group = Map.fetch!(groups, group.id)

          {:ok,
           %{
             payment_operation_id: payment.payment_operation_id,
             group_id: group.group_id,
             amount_cents: amount,
             outstanding_deposit_cents: outstanding(group),
             revision: group.revision
           }}
      end
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment, group} <-
           target_payment(operation["payment_operation_id"], "payment_not_chargeable"),
         :ok <- normalize_check_revision(group, operation) do
      chargeable = payment.recorded_cents - payment.reduced_cents

      if chargeable <= 0 or payment.charged_back_cents > 0 do
        {:error, "payment_not_chargeable"}
      else
        held = held_allocations(payment.id)
        affected_group_ids = allocation_group_ids(held)
        dispositions = payment_dispositions(payment.id)
        remove_allocations!(held, Enum.sum(Enum.map(held, & &1.amount_cents)))
        revoke_entitlements!(payment, operation["operation_id"])

        extras =
          Map.new(dispositions, fn disposition ->
            settled_group = Repo.get!(Group, disposition.group_record_id)

            {settled_group.id,
             [
               refunded_cents: settled_group.refunded_cents - disposition.refunded_cents,
               retained_cents: settled_group.retained_cents - disposition.retained_cents,
               cash_converted_to_credit_cents:
                 settled_group.cash_converted_to_credit_cents -
                   disposition.converted_to_credit_cents
             ]}
          end)

        group_ids =
          [group.id | affected_group_ids ++ Enum.map(dispositions, & &1.group_record_id)]

        groups = sync_groups!(group_ids, extras)
        group = Map.fetch!(groups, group.id)
        Enum.each(dispositions, &Repo.delete!/1)

        update_payment!(payment,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: chargeable
        )

        {:ok,
         %{
           payment_operation_id: payment.payment_operation_id,
           group_id: group.group_id,
           charged_back_cents: chargeable,
           outstanding_deposit_cents: outstanding(group),
           revision: group.revision
         }}
      end
    end
  end

  defp payment_statement(operation_id) do
    case Repo.get_by(CashPayment, payment_operation_id: operation_id) do
      nil ->
        {:error, :payment_not_reconcilable}

      payment ->
        held =
          Repo.one(
            from a in CashAllocation,
              where: a.cash_payment_id == ^payment.id,
              select: coalesce(sum(a.amount_cents), 0)
          )

        statement = %{
          payment_operation_id: payment.payment_operation_id,
          original_group_id: Repo.get!(Group, payment.group_record_id).group_id,
          recorded_cents: payment.recorded_cents,
          held_cents: held,
          refunded_cents: payment.refunded_cents,
          retained_cents: payment.retained_cents,
          converted_to_credit_cents: payment.converted_to_credit_cents,
          reduced_cents: payment.reduced_cents,
          charged_back_cents: payment.charged_back_cents
        }

        statement =
          if payment.participated_in_transfer,
            do: Map.put(statement, :held_by_group, held_by_group(payment.id)),
            else: statement

        {:ok, statement}
    end
  end

  defp target_payment(operation_id, code) do
    if valid_identifier?(operation_id) do
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        nil ->
          {:error, "operation_not_found"}

        _ ->
          case Repo.get_by(CashPayment, payment_operation_id: operation_id) do
            nil -> {:error, code}
            payment -> {:ok, payment, Repo.get!(Group, payment.group_record_id)}
          end
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp allocate_cash!(group, payment, amount) do
    fill_rooms!(group, amount, fn room, used ->
      insert_cash_allocation!(room.id, payment.id, used)
    end)
  end

  defp allocate_credit!(lots, group, operation_id, amount) do
    chunks =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, chunks} ->
        used = min(lot.remaining_cents, remaining)
        adjust_expiry!(lot, -used, operation_id)

        from(l in CreditLot, where: l.id == ^lot.id)
        |> Repo.update_all(set: [remaining_cents: lot.remaining_cents - used, updated_at: now()])

        state = {remaining - used, chunks ++ [{lot.id, used}]}
        if used == remaining, do: {:halt, state}, else: {:cont, state}
      end)
      |> elem(1)

    Enum.reduce(chunks, active_rooms(group.id), fn {lot_id, chunk}, rooms ->
      {_remaining, rooms} =
        fill_room_list!(rooms, chunk, fn room, used ->
          insert_credit_allocation!(group.id, room.id, lot_id, operation_id, used)
        end)

      rooms
    end)
  end

  defp fill_rooms!(group, amount, insert),
    do: fill_room_list!(active_rooms(group.id), amount, insert)

  defp fill_room_list!(rooms, amount, insert) do
    Enum.map_reduce(rooms, amount, fn room, remaining ->
      if remaining > 0 do
        capacity = room.deposit_due_cents - room_paid(room.id)
        used = min(capacity, remaining)
        if used > 0, do: insert.(room, used)
        {room, remaining - used}
      else
        {room, 0}
      end
    end)
    |> then(fn {rooms, remaining} -> {remaining, rooms} end)
  end

  defp room_paid(room_id) do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          where: a.room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    cash + credit
  end

  defp update_payment_dispositions!(allocations, group_id, field) do
    allocations
    |> Enum.reject(&is_nil(&1.cash_payment_id))
    |> Enum.group_by(& &1.cash_payment)
    |> Enum.each(fn {payment, rows} ->
      amount = Enum.sum(Enum.map(rows, & &1.amount_cents))
      update_payment!(payment, [{field, Map.fetch!(payment, field) + amount}])
      update_disposition!(payment.id, group_id, field, amount)
    end)
  end

  defp issue_credit!(_group, _operation, _occurred_on, 0, _allocations), do: 0

  defp issue_credit!(group, operation, occurred_on, converted, allocations) do
    issued = converted + rounded_percent(converted, 10)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 366)
      })

    adjust_expiry!(lot, issued, operation["operation_id"])

    contributions =
      allocations
      |> Enum.map(&{&1.cash_payment_id, &1.amount_cents})
      |> Enum.reduce([], fn {payment_id, amount}, acc ->
        case List.last(acc) do
          {^payment_id, existing} -> List.replace_at(acc, -1, {payment_id, existing + amount})
          _ -> acc ++ [{payment_id, amount}]
        end
      end)

    Enum.reduce(contributions, 0, fn {payment_id, principal}, preceding ->
      cumulative = preceding + principal

      entitlement =
        cumulative + rounded_percent(cumulative, 10) -
          (preceding + rounded_percent(preceding, 10))

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        cash_payment_id: payment_id,
        principal_cents: principal,
        entitlement_cents: entitlement
      })

      cumulative
    end)

    issued
  end

  defp restore_credit!(allocations, occurred_on, operation_id) do
    allocations
    |> Enum.group_by(& &1.credit_lot)
    |> Enum.each(fn {lot, rows} ->
      restored = Enum.sum(Enum.map(rows, & &1.amount_cents))
      absorbed = min(restored, lot.unrecovered_clawback_cents)
      available = restored - absorbed
      add_back = if Date.compare(lot.expires_on, occurred_on) == :gt, do: available, else: 0
      adjust_expiry!(lot, add_back, operation_id)

      from(l in CreditLot, where: l.id == ^lot.id)
      |> Repo.update_all(
        inc: [remaining_cents: add_back],
        set: [
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
          updated_at: now()
        ]
      )
    end)
  end

  defp revoke_entitlements!(payment, operation_id) do
    Repo.all(
      from e in CreditEntitlement,
        where: e.cash_payment_id == ^payment.id and e.revoked_cents < e.entitlement_cents,
        preload: [:credit_lot]
    )
    |> Enum.each(fn entitlement ->
      revoke = entitlement.entitlement_cents - entitlement.revoked_cents
      from_lot = min(revoke, entitlement.credit_lot.remaining_cents)
      shortfall = revoke - from_lot
      adjust_expiry!(entitlement.credit_lot, -from_lot, operation_id)

      from(l in CreditLot, where: l.id == ^entitlement.credit_lot_id)
      |> Repo.update_all(
        inc: [remaining_cents: -from_lot, unrecovered_clawback_cents: shortfall],
        set: [updated_at: now()]
      )

      from(e in CreditEntitlement, where: e.id == ^entitlement.id)
      |> Repo.update_all(set: [revoked_cents: entitlement.entitlement_cents, updated_at: now()])
    end)
  end

  defp insert_cash_allocation!(room_id, payment_id, amount) do
    order = Repo.insert!(%AllocationOrder{})

    Repo.insert!(%CashAllocation{
      room_id: room_id,
      cash_payment_id: payment_id,
      allocation_order_id: order.id,
      amount_cents: amount
    })
  end

  defp insert_credit_allocation!(group_id, room_id, lot_id, operation_id, amount) do
    order = Repo.insert!(%AllocationOrder{})

    Repo.insert!(%CreditAllocation{
      credit_lot_id: lot_id,
      group_record_id: group_id,
      room_id: room_id,
      funding_operation_id: operation_id,
      allocation_order_id: order.id,
      amount_cents: amount
    })
  end

  defp update_disposition!(payment_id, group_id, field, amount) do
    case Repo.get_by(CashDisposition,
           cash_payment_id: payment_id,
           group_record_id: group_id
         ) do
      nil ->
        Repo.insert!(
          struct!(CashDisposition, [
            {:cash_payment_id, payment_id},
            {:group_record_id, group_id},
            {field, amount}
          ])
        )

      disposition ->
        from(d in CashDisposition, where: d.id == ^disposition.id)
        |> Repo.update_all(
          set: [{field, Map.fetch!(disposition, field) + amount}, {:updated_at, now()}]
        )
    end
  end

  defp payment_dispositions(payment_id),
    do: Repo.all(from d in CashDisposition, where: d.cash_payment_id == ^payment_id)

  defp held_by_group(payment_id) do
    Repo.all(
      from a in CashAllocation,
        join: r in assoc(a, :room),
        join: g in assoc(r, :group),
        where: a.cash_payment_id == ^payment_id and r.status == "active",
        group_by: g.group_id,
        order_by: g.group_id,
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  defp allocation_group_ids(allocations),
    do: allocations |> Enum.map(& &1.room.group_record_id) |> Enum.uniq()

  defp allocation_group_ids_for_amount(allocations, amount) do
    allocations
    |> Enum.reduce_while({amount, []}, fn allocation, {remaining, group_ids} ->
      group_ids = [allocation.room.group_record_id | group_ids]
      remaining = remaining - min(allocation.amount_cents, remaining)

      if remaining == 0,
        do: {:halt, {remaining, group_ids}},
        else: {:cont, {remaining, group_ids}}
    end)
    |> then(fn {_remaining, group_ids} -> Enum.uniq(group_ids) end)
  end

  defp delete_allocation!(allocation) do
    order_id = allocation.allocation_order_id
    Repo.delete!(allocation)
    if order_id, do: Repo.delete!(Repo.get!(AllocationOrder, order_id))
  end

  defp reduce_allocation!(%CashAllocation{} = allocation, amount) do
    from(a in CashAllocation, where: a.id == ^allocation.id)
    |> Repo.update_all(inc: [amount_cents: -amount], set: [updated_at: now()])
  end

  defp reduce_allocation!(%CreditAllocation{} = allocation, amount) do
    from(a in CreditAllocation, where: a.id == ^allocation.id)
    |> Repo.update_all(inc: [amount_cents: -amount], set: [updated_at: now()])
  end

  defp held_allocations(payment_id),
    do:
      Repo.all(
        from a in CashAllocation,
          where: a.cash_payment_id == ^payment_id,
          order_by: [desc: a.allocation_order_id],
          preload: [:room]
      )

  defp remove_allocations!(_allocations, 0), do: :ok

  defp remove_allocations!(allocations, amount) do
    Enum.reduce_while(allocations, amount, fn allocation, remaining ->
      removed = min(allocation.amount_cents, remaining)

      if removed == allocation.amount_cents,
        do: delete_allocation!(allocation),
        else: reduce_allocation!(allocation, removed)

      if removed == remaining, do: {:halt, 0}, else: {:cont, remaining - removed}
    end)
  end

  defp available_lots(guest_id, on),
    do:
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

  defp active_rooms(group_id),
    do:
      Repo.all(
        from r in Room,
          where: r.group_record_id == ^group_id and r.status == "active",
          order_by: r.position
      )

  defp preload_group(group) do
    Repo.preload(group,
      rooms: {from(r in Room, order_by: r.position), [:cash_allocations, :credit_allocations]}
    )
  end

  defp sync_group!(group, extra \\ []) do
    rooms = active_rooms(group.id)
    lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

    cash =
      Repo.one(
        from a in CashAllocation,
          join: r in assoc(a, :room),
          where: r.group_record_id == ^group.id and r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          join: r in assoc(a, :room),
          where: r.group_record_id == ^group.id and r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    attrs =
      Keyword.merge(
        [
          lodging_total_cents: lodging,
          deposit_due_cents: due,
          deposit_paid_cents: cash + credit,
          cash_paid_cents: cash,
          credit_paid_cents: credit
        ],
        extra
      )

    update!(group, attrs)
  end

  defp sync_groups!(group_ids, extras \\ %{}) do
    group_ids
    |> Enum.uniq()
    |> Map.new(fn group_id ->
      group = Repo.get!(Group, group_id)
      {group_id, sync_group!(group, Map.get(extras, group_id, []))}
    end)
  end

  defp update!(group, attrs) do
    {1, _} =
      from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
      |> Repo.update_all(set: Keyword.put(attrs, :updated_at, now()), inc: [revision: 1])

    Repo.get!(Group, group.id)
  end

  defp update_payment!(payment, attrs) do
    from(p in CashPayment, where: p.id == ^payment.id)
    |> Repo.update_all(set: Keyword.put(attrs, :updated_at, now()))
  end

  defp check_revision(group, operation) do
    expected = operation["expected_revision"]

    if not is_nil(expected) and expected != group.revision,
      do:
        {:error,
         %{
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }},
      else: :ok
  end

  defp normalize_check_revision(group, operation) do
    case check_revision(group, operation) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp group_error(code, group_id), do: {:error, %{code: code, group_id: group_id}}

  defp outstanding(%Group{status: "active"} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding(_group), do: 0
  defp rounded_percent(amount, percent), do: div(amount * percent + 50, 100)
  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  defp refundable_until(%Group{policy_version: "flex-14"} = group),
    do: Date.add(group.arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30"} = group),
    do: Date.add(group.arrival_on, -30)

  defp refundable_until(_), do: nil

  defp refundable?(group, occurred_on),
    do:
      case(refundable_until(group),
        do: (
          nil -> false
          date -> Date.compare(occurred_on, date) != :gt
        )
      )

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_date(value) when is_binary(value),
    do:
      case(Date.from_iso8601(value),
        do: (
          {:ok, date} -> {:ok, date}
          _ -> :error
        )
      )

  defp parse_date(_), do: :error
  defp identifiers?(operation, keys), do: Enum.all?(keys, &valid_identifier?(operation[&1]))
  defp required_fields?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))
  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp unique_error?(changeset, field),
    do:
      Enum.any?(changeset.errors, fn {key, {_message, options}} ->
        key == field and options[:constraint] == :unique
      end)

  defp normalize_apply_result({:error, reason}), do: {:error, reason}
  defp normalize_apply_result(result), do: {:ok, result}
  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil

  defp deserialize_result(result),
    do:
      Map.new(result, fn
        {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
        pair -> pair
      end)

  defp rejected(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}
end
