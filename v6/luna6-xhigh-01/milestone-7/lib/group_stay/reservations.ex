defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.{
    Repo,
    Reservation,
    PartnerOperation,
    ReservationRoom,
    HotelCreditLot,
    HotelCreditAllocation,
    CashPaymentAllocation,
    HotelCreditLotEntitlement,
    FinanceReporting,
    FinancePosting,
    FinanceReportSnapshot
  }

  @max_sqlite_integer 9_223_372_036_854_775_807

  @doc """
  Applies partner operations independently and in order. Each operation has its own transaction,
  so a rejection cannot undo an earlier successful operation in the same batch.
  """
  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_operation(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_group(group_id) do
    case Repo.get(Reservation, group_id) do
      nil ->
        nil

      reservation ->
        rooms =
          Repo.all(
            from room in ReservationRoom,
              where: room.group_id == ^group_id,
              order_by: room.position
          )

        group_json(reservation, rooms)
    end
  end

  def get_payment(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      %PartnerOperation{
        operation_type: "record_cash_payment",
        result: %{"status" => "applied"} = result
      } = operation ->
        totals =
          Repo.one(
            from allocation in CashPaymentAllocation,
              where: allocation.payment_operation_id == ^payment_operation_id,
              select: %{
                held: sum(allocation.held_cents),
                refunded: sum(allocation.refunded_cents),
                retained: sum(allocation.retained_cents),
                converted: sum(allocation.converted_cents),
                reduced: sum(allocation.reduced_cents),
                charged_back: sum(allocation.charged_back_cents)
              }
          )

        amounts = %{
          held: totals.held || 0,
          refunded: totals.refunded || 0,
          retained: totals.retained || 0,
          converted: totals.converted || 0,
          reduced: totals.reduced || 0,
          charged_back: totals.charged_back || 0
        }

        statement = %{
          payment_operation_id: operation.operation_id,
          original_group_id: result["group_id"],
          recorded_cents: result["amount_cents"],
          held_cents: amounts.held,
          refunded_cents: amounts.refunded,
          retained_cents: amounts.retained,
          converted_to_credit_cents: amounts.converted,
          reduced_cents: amounts.reduced,
          charged_back_cents: amounts.charged_back
        }

        was_transferred =
          Repo.exists?(
            from allocation in CashPaymentAllocation,
              where:
                allocation.payment_operation_id == ^payment_operation_id and
                  allocation.transferred == true
          )

        if was_transferred do
          held_by_group =
            Repo.all(
              from allocation in CashPaymentAllocation,
                where:
                  allocation.payment_operation_id == ^payment_operation_id and
                    allocation.held_cents > 0,
                group_by: allocation.group_id,
                order_by: allocation.group_id,
                select: {allocation.group_id, sum(allocation.held_cents)}
            )
            |> Enum.map(fn {group_id, amount} ->
              %{group_id: group_id, amount_cents: amount}
            end)

          {:ok, Map.put(statement, :held_by_group, held_by_group)}
        else
          {:ok, statement}
        end

      %PartnerOperation{} ->
        :not_reconcilable
    end
  end

  def ledger(as_of_date \\ Date.utc_today()) do
    cash =
      Repo.one(
        from allocation in CashPaymentAllocation,
          select: %{
            held: sum(allocation.held_cents),
            refunded: sum(allocation.refunded_cents),
            retained: sum(allocation.retained_cents),
            converted: sum(allocation.converted_cents),
            reduced: sum(allocation.reduced_cents),
            charged_back: sum(allocation.charged_back_cents)
          }
      )

    available_credit =
      Repo.one(
        from lot in HotelCreditLot,
          where:
            lot.issued_on <= ^as_of_date and lot.expires_on >= ^as_of_date and
              lot.remaining_cents > 0,
          select: sum(lot.remaining_cents)
      ) || 0

    applied_credit =
      Repo.one(
        from allocation in HotelCreditAllocation,
          join: reservation in Reservation,
          on: reservation.group_id == allocation.group_id,
          where: reservation.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    credit_shortfall =
      Repo.all(
        from lot in HotelCreditLot,
          left_join: allocation in HotelCreditAllocation,
          on: allocation.credit_lot_id == lot.id,
          left_join: reservation in Reservation,
          on: reservation.group_id == allocation.group_id and reservation.status == "active",
          group_by: [lot.id, lot.unrecovered_clawback_cents],
          select:
            {lot.unrecovered_clawback_cents,
             sum(
               fragment(
                 "CASE WHEN ? IS NULL THEN 0 ELSE ? END",
                 reservation.group_id,
                 allocation.amount_cents
               )
             )}
      )
      |> Enum.reduce(0, fn {clawback, applied}, total -> total + min(clawback, applied || 0) end)

    %{
      cash_held_cents: cash.held || 0,
      cash_refunded_cents: cash.refunded || 0,
      cash_retained_cents: cash.retained || 0,
      cash_converted_to_credit_cents: cash.converted || 0,
      cash_reduced_cents: cash.reduced || 0,
      cash_charged_back_cents: cash.charged_back || 0,
      credit_liability_cents: available_credit + applied_credit,
      credit_shortfall_cents: credit_shortfall
    }
  end

  def guest_credit(guest_id, as_of_date \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in HotelCreditLot,
          where:
            lot.guest_id == ^guest_id and lot.issued_on <= ^as_of_date and
              lot.expires_on >= ^as_of_date and lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  def daily_finance_report(%Date{} = date) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        nil

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          nil
        else
          case Repo.get(FinanceReportSnapshot, date) do
            %FinanceReportSnapshot{data: report} -> report
            nil -> build_daily_finance_report(reporting, date, "open")
          end
        end
    end
  end

  defp build_daily_finance_report(reporting, date, status, all_postings \\ nil) do
    all_postings = all_postings || finance_postings()

    postings = Enum.filter(all_postings, &(Date.compare(&1.posting_date, date) != :gt))
    {late_postings, ordinary_postings} = Enum.split_with(postings, & &1.late_adjustment)

    ordinary_cash_movements = Enum.reduce(ordinary_postings, %{}, &merge_cash_movements/2)
    late_cash_movements = Enum.reduce(late_postings, %{}, &merge_cash_movements/2)

    ordinary_expired = expired_credit_cents(reporting, date, all_postings, :ordinary)
    late_expired = expired_credit_cents(reporting, date, all_postings, :late)

    ordinary_credit_movements =
      ordinary_postings
      |> Enum.reduce(empty_credit_movements(), &merge_credit_movements/2)
      |> Map.update!("expired_cents", &(&1 + ordinary_expired))

    late_credit_movements =
      late_postings
      |> Enum.reduce(empty_credit_movements(), &merge_credit_movements/2)
      |> Map.update!("expired_cents", &(&1 + late_expired))

    property_ids =
      Map.keys(reporting.opening_cash_by_property) ++
        Map.keys(ordinary_cash_movements) ++ Map.keys(late_cash_movements)

    cash =
      property_ids
      |> Enum.uniq()
      |> Enum.map(fn property_id ->
        opening = Map.get(reporting.opening_cash_by_property, property_id, 0)
        ordinary = Map.get(ordinary_cash_movements, property_id, empty_cash_movements())
        late = Map.get(late_cash_movements, property_id, empty_cash_movements())
        total = add_movements(ordinary, late)

        closing =
          opening + total["received_cents"] + total["transferred_in_cents"] -
            total["transferred_out_cents"] - total["refunded_cents"] -
            total["retained_cents"] - total["converted_to_credit_cents"] -
            total["reduced_cents"] - total["charged_back_cents"]

        if opening == 0 and closing == 0 and Enum.all?(Map.values(total), &(&1 == 0)) do
          nil
        else
          %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: ordinary,
            closing_held_cents: closing
          }
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.property_id)

    late_cash =
      late_cash_movements
      |> Enum.map(fn {property_id, movements} ->
        %{property_id: property_id, movements: Map.merge(empty_cash_movements(), movements)}
      end)
      |> Enum.reject(fn entry -> Enum.all?(Map.values(entry.movements), &(&1 == 0)) end)
      |> Enum.sort_by(& &1.property_id)

    opening_credit = reporting.opening_credit_liability_cents
    total_credit_movements = add_movements(ordinary_credit_movements, late_credit_movements)

    closing_credit =
      opening_credit + total_credit_movements["issued_cents"] -
        total_credit_movements["expired_cents"] - total_credit_movements["consumed_cents"] -
        total_credit_movements["revoked_cents"] - total_credit_movements["absorbed_cents"]

    %{
      date: date,
      status: status,
      cash: cash,
      credit: %{
        opening_liability_cents: opening_credit,
        movements: ordinary_credit_movements,
        closing_liability_cents: closing_credit
      },
      late_adjustments: %{
        cash: late_cash,
        credit: late_credit_movements
      }
    }
  end

  defp add_movements(left, right) do
    Map.new(left, fn {key, amount} -> {key, amount + Map.get(right, key, 0)} end)
  end

  defp finance_postings do
    Repo.all(
      from posting in FinancePosting,
        order_by: [asc: posting.posting_date, asc: posting.operation_id]
    )
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      process_durable_operation(operation, operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_durable_operation(operation, operation_id) do
    submission = operation |> Jason.encode!() |> Jason.decode!()

    case Repo.transaction(
           fn ->
             case Repo.get_by(PartnerOperation, operation_id: operation_id) do
               %PartnerOperation{submission: ^submission, result: result} ->
                 result

               %PartnerOperation{} ->
                 rejected(operation_id, "operation_id_conflict")

               nil ->
                 result = apply_first_operation(operation, operation_id)

                 result_json = result |> Jason.encode!() |> Jason.decode!()

                 Repo.insert!(%PartnerOperation{
                   operation_id: operation_id,
                   operation_type: operation_type(operation),
                   submission: submission,
                   result: result_json
                 })

                 result_json
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, reason} -> raise "operation transaction failed: #{inspect(reason)}"
    end
  end

  defp apply_first_operation(operation, operation_id) do
    type = Map.get(operation, "type")
    reporting = if type == "start_finance_reporting", do: nil, else: Repo.get(FinanceReporting, 1)

    before_snapshot =
      if reporting, do: finance_snapshot(), else: nil

    result =
      try do
        case type do
          type when is_binary(type) ->
            normalize_rejection(do_process_operation(type, operation, operation_id))

          _ ->
            rejected(operation_id, "invalid_operation")
        end
      catch
        # Handled domain rejections occur before the operation's first write. Catching them here
        # lets the outer transaction commit the original rejection alongside its submission.
        :throw, {:handled_rejection, handled_result} -> handled_result
      end

    if reporting && type != "close_finance_period" && result_status(result) == "applied" do
      record_finance_posting!(operation, operation_id, reporting, before_snapshot, result)
    end

    result
  end

  defp normalize_rejection({:error, result}), do: result
  defp normalize_rejection(result), do: result

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp finance_snapshot do
    cash_rows =
      Repo.all(
        from allocation in CashPaymentAllocation,
          join: reservation in Reservation,
          on: reservation.group_id == allocation.group_id,
          group_by: reservation.property_id,
          select:
            {reservation.property_id, sum(allocation.held_cents), sum(allocation.refunded_cents),
             sum(allocation.retained_cents), sum(allocation.converted_cents),
             sum(allocation.reduced_cents), sum(allocation.charged_back_cents)}
      )

    cash_by_property =
      Map.new(cash_rows, fn {property_id, held, refunded, retained, converted, reduced, charged} ->
        {property_id,
         %{
           held: held || 0,
           refunded: refunded || 0,
           retained: retained || 0,
           converted: converted || 0,
           reduced: reduced || 0,
           charged_back: charged || 0
         }}
      end)

    cash_by_group =
      Repo.all(
        from allocation in CashPaymentAllocation,
          where: allocation.held_cents > 0,
          group_by: allocation.group_id,
          select: {allocation.group_id, sum(allocation.held_cents)}
      )
      |> Map.new(fn {group_id, held} -> {group_id, held || 0} end)

    lots =
      Repo.all(from(lot in HotelCreditLot))
      |> Map.new(fn lot ->
        {lot.id,
         %{
           remaining: lot.remaining_cents,
           unrecovered_clawback: lot.unrecovered_clawback_cents,
           expires_on: lot.expires_on,
           source_operation_id: lot.source_operation_id
         }}
      end)

    applied_by_group_lot =
      Repo.all(
        from allocation in HotelCreditAllocation,
          join: reservation in Reservation,
          on: reservation.group_id == allocation.group_id,
          where: reservation.status == "active",
          group_by: [allocation.group_id, allocation.credit_lot_id],
          select: {allocation.group_id, allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new(fn {group_id, lot_id, amount} -> {{group_id, lot_id}, amount || 0} end)

    groups =
      Repo.all(from(reservation in Reservation))
      |> Map.new(&{&1.group_id, &1})

    %{
      cash_by_property: cash_by_property,
      cash_by_group: cash_by_group,
      lots: lots,
      applied_by_group_lot: applied_by_group_lot,
      groups: groups
    }
  end

  defp record_finance_posting!(operation, operation_id, reporting, before_snapshot, result) do
    {posting_date, late_adjustment?} = finance_posting_date(operation, reporting)
    after_snapshot = finance_snapshot()

    {credit_movements, credit_lot_movements} =
      report_credit_movements(
        operation,
        operation_id,
        posting_date,
        before_snapshot,
        after_snapshot,
        result
      )

    Repo.insert!(%FinancePosting{
      operation_id: operation_id,
      posting_date: posting_date,
      late_adjustment: late_adjustment?,
      cash_movements: report_cash_movements(operation, before_snapshot, after_snapshot),
      credit_movements: credit_movements,
      credit_lot_movements: credit_lot_movements
    })
  end

  defp finance_posting_date(operation, reporting) do
    occurred_on =
      case parse_date(Map.get(operation, "occurred_on")) do
        {:ok, date} -> date
        :error -> reporting.starts_on
      end

    natural_posting_date = later_date(occurred_on, reporting.starts_on)

    first_open_date =
      case reporting.latest_closed_on do
        %Date{} = cutoff -> later_date(reporting.starts_on, Date.add(cutoff, 1))
        nil -> reporting.starts_on
      end

    posting_date = later_date(natural_posting_date, first_open_date)

    late_adjustment? =
      reporting.latest_closed_on != nil and
        Date.compare(posting_date, natural_posting_date) == :gt

    {posting_date, late_adjustment?}
  end

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp report_cash_movements(operation, before_snapshot, after_snapshot) do
    case Map.get(operation, "type") do
      "record_cash_payment" ->
        group_id = Map.get(operation, "group_id")
        reservation = Map.get(after_snapshot.groups, group_id)

        if reservation do
          put_cash_movement(
            %{},
            reservation.property_id,
            "received_cents",
            Map.get(operation, "amount_cents", 0)
          )
        else
          %{}
        end

      "transfer_deposit" ->
        source_group_id = Map.get(operation, "source_group_id")
        destination_group_id = Map.get(operation, "destination_group_id")
        source = Map.get(before_snapshot.groups, source_group_id)
        destination = Map.get(before_snapshot.groups, destination_group_id)

        movements = %{}

        movements =
          if source do
            moved =
              max(
                Map.get(before_snapshot.cash_by_group, source_group_id, 0) -
                  Map.get(after_snapshot.cash_by_group, source_group_id, 0),
                0
              )

            put_cash_movement(movements, source.property_id, "transferred_out_cents", moved)
          else
            movements
          end

        if destination do
          moved =
            max(
              Map.get(after_snapshot.cash_by_group, destination_group_id, 0) -
                Map.get(before_snapshot.cash_by_group, destination_group_id, 0),
              0
            )

          put_cash_movement(movements, destination.property_id, "transferred_in_cents", moved)
        else
          movements
        end

      type
      when type in ["cancel_group", "cancel_rooms", "reduce_cash_payment", "charge_back_payment"] ->
        keys =
          case type do
            "cancel_group" ->
              [
                refunded: "refunded_cents",
                retained: "retained_cents",
                converted: "converted_to_credit_cents"
              ]

            "cancel_rooms" ->
              [
                refunded: "refunded_cents",
                retained: "retained_cents",
                converted: "converted_to_credit_cents"
              ]

            "reduce_cash_payment" ->
              [reduced: "reduced_cents"]

            "charge_back_payment" ->
              [
                refunded: "refunded_cents",
                retained: "retained_cents",
                converted: "converted_to_credit_cents",
                charged_back: "charged_back_cents"
              ]
          end

        properties =
          (Map.keys(before_snapshot.cash_by_property) ++ Map.keys(after_snapshot.cash_by_property))
          |> Enum.uniq()

        Enum.reduce(properties, %{}, fn property_id, movements ->
          before_values = Map.get(before_snapshot.cash_by_property, property_id, %{})
          after_values = Map.get(after_snapshot.cash_by_property, property_id, %{})

          Enum.reduce(keys, movements, fn {category, report_key}, acc ->
            change = Map.get(after_values, category, 0) - Map.get(before_values, category, 0)
            put_cash_movement(acc, property_id, report_key, change)
          end)
        end)

      _ ->
        %{}
    end
  end

  defp put_cash_movement(movements, _property_id, _key, 0), do: movements

  defp put_cash_movement(movements, property_id, key, amount) do
    per_property = Map.get(movements, property_id, %{})
    Map.put(movements, property_id, Map.update(per_property, key, amount, &(&1 + amount)))
  end

  defp report_credit_movements(
         operation,
         _operation_id,
         posting_date,
         before_snapshot,
         after_snapshot,
         result
       ) do
    case Map.get(operation, "type") do
      type when type in ["cancel_group", "cancel_rooms"] ->
        group_id = Map.get(operation, "group_id")
        reservation = Map.get(before_snapshot.groups, group_id)
        occurred_on = operation_date_value(operation)
        refundable = reservation && refundable?(reservation, occurred_on)

        removed_allocations =
          (Map.keys(before_snapshot.applied_by_group_lot) ++
             Map.keys(after_snapshot.applied_by_group_lot))
          |> Enum.uniq()
          |> Enum.filter(fn {allocation_group_id, _lot_id} -> allocation_group_id == group_id end)
          |> Enum.map(fn {_group_id, lot_id} = key ->
            removed =
              max(
                Map.get(before_snapshot.applied_by_group_lot, key, 0) -
                  Map.get(after_snapshot.applied_by_group_lot, key, 0),
                0
              )

            {lot_id, removed}
          end)
          |> Enum.filter(fn {_lot_id, amount} -> amount > 0 end)

        {consumed, expired, absorbed} =
          if refundable do
            Enum.reduce(removed_allocations, {0, 0, 0}, fn {lot_id, removed},
                                                           {used, expired_sum, absorbed_sum} ->
              before_lot = Map.get(before_snapshot.lots, lot_id, %{})
              after_lot = Map.get(after_snapshot.lots, lot_id, %{})

              restored_available =
                max(Map.get(after_lot, :remaining, 0) - Map.get(before_lot, :remaining, 0), 0)

              restored_absorbed =
                max(
                  Map.get(before_lot, :unrecovered_clawback, 0) -
                    Map.get(after_lot, :unrecovered_clawback, 0),
                  0
                )

              {used, expired_sum + max(removed - restored_available - restored_absorbed, 0),
               absorbed_sum + restored_absorbed}
            end)
          else
            {Enum.reduce(removed_allocations, 0, fn {_lot_id, amount}, sum -> sum + amount end),
             0, 0}
          end

        issued = result_value(result, :credit_issued_cents, 0)

        movements = %{
          "issued_cents" => issued,
          "expired_cents" => expired,
          "consumed_cents" => consumed,
          "revoked_cents" => 0,
          "absorbed_cents" => absorbed
        }

        {movements, %{}}

      "charge_back_payment" ->
        {revoked, by_lot} =
          Enum.reduce(before_snapshot.lots, {0, %{}}, fn {lot_id, before_lot}, {sum, by_lot} ->
            after_lot = Map.get(after_snapshot.lots, lot_id, before_lot)
            removed = max(before_lot.remaining - after_lot.remaining, 0)

            credit_lot_movements =
              if removed > 0,
                do: Map.put(by_lot, Integer.to_string(lot_id), removed),
                else: by_lot

            if removed > 0 and Date.compare(posting_date, before_lot.expires_on) != :gt do
              {sum + removed, credit_lot_movements}
            else
              {sum, credit_lot_movements}
            end
          end)

        {%{
           "issued_cents" => 0,
           "expired_cents" => 0,
           "consumed_cents" => 0,
           "revoked_cents" => revoked,
           "absorbed_cents" => 0
         }, by_lot}

      _ ->
        {empty_credit_movements(), %{}}
    end
  end

  defp empty_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp empty_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp merge_cash_movements(posting, acc) do
    Enum.reduce(posting.cash_movements || %{}, acc, fn {property_id, movement}, properties ->
      existing = Map.get(properties, property_id, empty_cash_movements())

      merged =
        Enum.reduce(movement, existing, fn {key, amount}, values ->
          Map.update(values, key, amount, &(&1 + amount))
        end)

      Map.put(properties, property_id, merged)
    end)
  end

  defp merge_credit_movements(posting, acc) do
    Enum.reduce(posting.credit_movements || %{}, acc, fn {key, amount}, movements ->
      if Map.has_key?(movements, key),
        do: Map.update!(movements, key, &(&1 + amount)),
        else: movements
    end)
  end

  defp expired_credit_cents(reporting, date, postings, bucket) do
    source_postings =
      Map.new(postings, &{&1.operation_id, %{date: &1.posting_date, late?: &1.late_adjustment}})

    revoked_by_lot =
      Enum.reduce(postings, %{}, fn posting, acc ->
        Enum.reduce(posting.credit_lot_movements || %{}, acc, fn {lot_id, amount}, totals ->
          Map.update(
            totals,
            lot_id,
            [{posting.posting_date, amount}],
            &[{posting.posting_date, amount} | &1]
          )
        end)
      end)

    Repo.all(from(lot in HotelCreditLot))
    |> Enum.reduce(0, fn lot, total ->
      natural_expiry = Date.add(lot.expires_on, 1)
      source_posting = Map.get(source_postings, lot.source_operation_id)
      source_posting_date = source_posting && source_posting.date

      effective_expiry =
        [natural_expiry, reporting.starts_on, source_posting_date]
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(fn candidate, current ->
          if Date.compare(candidate, current) == :gt, do: candidate, else: current
        end)

      reportable_expiry? =
        Date.compare(effective_expiry, reporting.starts_on) == :gt or
          (Date.compare(effective_expiry, reporting.starts_on) == :eq and
             source_posting_date == reporting.starts_on)

      late_expiry? =
        source_posting && source_posting.late? &&
          Date.compare(source_posting_date, natural_expiry) == :gt

      include_expiry? =
        case bucket do
          :late -> late_expiry?
          :ordinary -> not late_expiry?
        end

      if include_expiry? and reportable_expiry? and
           Date.compare(effective_expiry, date) != :gt do
        later_revocations =
          revoked_by_lot
          |> Map.get(Integer.to_string(lot.id), [])
          |> Enum.reduce(0, fn {posting_date, amount}, sum ->
            if Date.compare(posting_date, effective_expiry) != :lt, do: sum + amount, else: sum
          end)

        total + lot.remaining_cents + later_revocations
      else
        total
      end
    end)
  end

  defp result_status(result), do: Map.get(result, :status, Map.get(result, "status"))

  defp result_value(result, key, default) do
    Map.get(result, key, Map.get(result, Atom.to_string(key), default))
  end

  defp do_process_operation("open_group", operation, operation_id) do
    with {:ok, booked_on} <- operation_date(operation, operation_id),
         :ok <-
           require_identifiers(operation, ["group_id", "guest_id", "property_id"], operation_id),
         {:ok, stay} <- open_stay(operation, operation_id),
         {:ok, rate_plan} <- rate_plan(operation, operation_id),
         {:ok, rooms} <- rooms(operation, operation_id),
         {:ok, totals} <- totals(rooms, stay.nights, rate_plan, operation_id) do
      group_id = operation["group_id"]

      if Repo.get(Reservation, group_id) do
        reject!(rejected(operation_id, "group_already_exists", group_id: group_id))
      end

      reservation =
        Repo.insert!(%Reservation{
          group_id: group_id,
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: stay.arrival_on,
          departure_on: stay.departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version_for(rate_plan, booked_on),
          status: "active",
          lodging_total_cents: totals.lodging,
          deposit_due_cents: totals.deposit,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          revision: 1
        })

      Enum.with_index(rooms)
      |> Enum.each(fn {room, position} ->
        lodging = room.nightly_rate_cents * stay.nights
        room_due = room_deposit(lodging, rate_plan)

        Repo.insert!(%ReservationRoom{
          group_id: reservation.group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          deposit_due_cents: room_due,
          status: "active"
        })
      end)

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group_id,
        deposit_due_cents: totals.deposit,
        revision: 1
      }
    else
      {:error, result} -> result
    end
  end

  defp do_process_operation("close_finance_period", operation, operation_id) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        rejected(operation_id, "invalid_period")

      reporting ->
        with {:ok, period_end_on} <-
               parse_domain_date(
                 Map.get(operation, "period_end_on"),
                 "invalid_period",
                 operation_id
               ) do
          valid_start? = Date.compare(period_end_on, reporting.starts_on) != :lt

          later_than_previous_close? =
            is_nil(reporting.latest_closed_on) or
              Date.compare(period_end_on, reporting.latest_closed_on) == :gt

          if valid_start? and later_than_previous_close? do
            snapshot_finance_reports!(reporting, period_end_on)

            Repo.update!(Ecto.Changeset.change(reporting, latest_closed_on: period_end_on))

            %{
              operation_id: operation_id,
              status: "applied",
              period_end_on: period_end_on
            }
          else
            rejected(operation_id, "invalid_period")
          end
        else
          {:error, result} -> result
        end
    end
  end

  defp do_process_operation("start_finance_reporting", operation, operation_id) do
    case Repo.get(FinanceReporting, 1) do
      %FinanceReporting{} ->
        rejected(operation_id, "reporting_already_started")

      nil ->
        with {:ok, starts_on} <-
               parse_domain_date(
                 Map.get(operation, "starts_on"),
                 "invalid_reporting_date",
                 operation_id
               ) do
          cash_by_property =
            Repo.all(
              from allocation in CashPaymentAllocation,
                join: reservation in Reservation,
                on: reservation.group_id == allocation.group_id,
                where: reservation.status == "active" and allocation.held_cents > 0,
                group_by: reservation.property_id,
                select: {reservation.property_id, sum(allocation.held_cents)}
            )
            |> Map.new(fn {property_id, amount} -> {property_id, amount || 0} end)

          Repo.insert!(%FinanceReporting{
            id: 1,
            starts_on: starts_on,
            opening_cash_by_property: cash_by_property,
            opening_credit_liability_cents: ledger(starts_on).credit_liability_cents
          })

          %{operation_id: operation_id, status: "applied", starts_on: starts_on}
        else
          {:error, result} -> result
        end
    end
  end

  defp do_process_operation(type, operation, operation_id)
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group",
              "cancel_rooms"
            ] do
    with :ok <- require_identifiers(operation, ["group_id"], operation_id) do
      group_id = operation["group_id"]

      case Repo.get(Reservation, group_id) do
        nil ->
          reject!(rejected(operation_id, "group_not_found", group_id: group_id))

        reservation ->
          check_revision!(reservation, operation, operation_id)
          check_operation_date!(operation, operation_id, group_id)
          apply_to_reservation(type, operation, reservation, operation_id)
      end
    else
      {:error, result} -> result
    end
  end

  defp do_process_operation("transfer_deposit", operation, operation_id) do
    with :ok <-
           require_identifiers(
             operation,
             ["source_group_id", "destination_group_id"],
             operation_id
           ) do
      source_group_id = operation["source_group_id"]
      destination_group_id = operation["destination_group_id"]

      case Repo.get(Reservation, source_group_id) do
        nil ->
          reject!(rejected(operation_id, "group_not_found", group_id: source_group_id))

        source ->
          case Repo.get(Reservation, destination_group_id) do
            nil ->
              reject!(rejected(operation_id, "group_not_found", group_id: destination_group_id))

            destination ->
              check_revision!(source, operation, operation_id)

              check_revision!(
                destination,
                operation,
                operation_id,
                "destination_expected_revision"
              )

              apply_deposit_transfer(source, destination, operation, operation_id)
          end
      end
    else
      {:error, result} -> result
    end
  end

  defp do_process_operation(type, operation, operation_id)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    payment_operation_id = Map.get(operation, "payment_operation_id")

    if not valid_identifier?(payment_operation_id) do
      rejected(operation_id, "invalid_operation")
    else
      case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
        nil ->
          rejected(operation_id, "operation_not_found")

        payment ->
          group_id = get_in(payment.result || %{}, ["group_id"])

          case Repo.get(Reservation, group_id) do
            %Reservation{} = reservation ->
              check_revision!(reservation, operation, operation_id)
              apply_payment_correction(type, operation, reservation, payment, operation_id)

            nil ->
              if applied_cash_payment?(payment) do
                reject!(rejected(operation_id, "group_not_found", group_id: group_id))
              else
                code =
                  if type == "reduce_cash_payment",
                    do: "payment_not_reducible",
                    else: "payment_not_chargeable"

                rejected(operation_id, code)
              end
          end
      end
    end
  end

  defp do_process_operation(_unknown, _operation, operation_id),
    do: rejected(operation_id, "invalid_operation")

  defp snapshot_finance_reports!(reporting, period_end_on) do
    postings = finance_postings()

    first_snapshot_date =
      case reporting.latest_closed_on do
        %Date{} = cutoff -> later_date(reporting.starts_on, Date.add(cutoff, 1))
        nil -> reporting.starts_on
      end

    first_snapshot_date
    |> Date.range(period_end_on)
    |> Stream.chunk_every(400)
    |> Enum.each(fn dates ->
      snapshots =
        Enum.map(dates, fn date ->
          data =
            reporting
            |> build_daily_finance_report(date, "closed", postings)
            |> Jason.encode!()
            |> Jason.decode!()

          %{date: date, data: data}
        end)

      Repo.insert_all(FinanceReportSnapshot, snapshots)
    end)
  end

  defp apply_deposit_transfer(source, destination, operation, operation_id) do
    if source.group_id == destination.group_id or source.guest_id != destination.guest_id do
      reject!(rejected(operation_id, "invalid_transfer"))
    end

    ensure_active!(source, operation_id)
    ensure_active!(destination, operation_id)

    amount = Map.get(operation, "amount_cents")

    unless is_integer(amount) and amount > 0 do
      reject!(rejected(operation_id, "invalid_amount"))
    end

    funding = active_funding_allocations(source.group_id)
    held = Enum.reduce(funding, 0, &(&1.amount + &2))

    if amount > held do
      reject!(rejected(operation_id, "transfer_exceeds_held_funding"))
    end

    destination_outstanding = outstanding(destination)

    if amount > destination_outstanding do
      reject!(rejected(operation_id, "transfer_exceeds_outstanding"))
    end

    source_chunks = take_funding_chunks(funding, amount)
    destination_rooms = active_rooms(destination.group_id)
    transfer_plan = plan_transfer_allocations(source_chunks, destination_rooms)

    move_funding_allocations!(transfer_plan, operation_id, destination.group_id)
    adjust_transfer_room_funding!(transfer_plan, source.group_id, destination.group_id)

    updated_source = refresh_reservation!(source)
    updated_destination = refresh_reservation!(destination)

    %{
      operation_id: operation_id,
      status: "applied",
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding(updated_source),
      destination_outstanding_deposit_cents: outstanding(updated_destination),
      source_revision: updated_source.revision,
      destination_revision: updated_destination.revision
    }
  end

  defp active_funding_allocations(group_id) do
    cash_allocations =
      Repo.all(
        from allocation in CashPaymentAllocation,
          where: allocation.group_id == ^group_id and allocation.held_cents > 0
      )

    credit_allocations =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group_id and allocation.amount_cents > 0
      )

    creator_ids =
      (Enum.map(cash_allocations, &(&1.allocation_operation_id || &1.payment_operation_id)) ++
         Enum.map(credit_allocations, &(&1.allocation_operation_id || &1.funding_operation_id)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    creator_orders =
      if creator_ids == [] do
        %{}
      else
        Repo.all(
          from operation in PartnerOperation,
            where: operation.operation_id in ^creator_ids,
            select: {operation.operation_id, operation.id}
        )
        |> Map.new()
      end

    cash_entries =
      Enum.map(cash_allocations, fn allocation ->
        creator_id = allocation.allocation_operation_id || allocation.payment_operation_id

        %{
          kind: :cash,
          allocation: allocation,
          amount: allocation.held_cents,
          order_key:
            allocation_order_key(
              creator_id,
              allocation.allocation_position,
              allocation.id,
              0,
              creator_orders
            )
        }
      end)

    credit_entries =
      Enum.map(credit_allocations, fn allocation ->
        creator_id = allocation.allocation_operation_id || allocation.funding_operation_id

        %{
          kind: :credit,
          allocation: allocation,
          amount: allocation.amount_cents,
          order_key:
            allocation_order_key(
              creator_id,
              allocation.allocation_position,
              allocation.id,
              1,
              creator_orders
            )
        }
      end)

    (cash_entries ++ credit_entries)
    |> Enum.sort_by(& &1.order_key, :desc)
  end

  defp allocation_order_key(nil, _position, id, kind_order, _creator_orders),
    do: {0, kind_order, id}

  defp allocation_order_key(creator_id, position, id, kind_order, creator_orders) do
    creator_order = Map.get(creator_orders, creator_id, 0)

    {1, creator_order, position || id, kind_order, id}
  end

  defp take_funding_chunks(funding, amount) do
    {chunks, _remaining} =
      Enum.reduce_while(funding, {[], amount}, fn entry, {chunks, remaining} ->
        piece = min(entry.amount, remaining)
        next_chunks = if piece > 0, do: chunks ++ [%{entry: entry, amount: piece}], else: chunks
        left = remaining - piece

        if left == 0,
          do: {:halt, {next_chunks, 0}},
          else: {:cont, {next_chunks, left}}
      end)

    chunks
  end

  defp plan_transfer_allocations(chunks, destination_rooms) do
    capacities =
      Map.new(destination_rooms, fn room ->
        {room.room_id,
         max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)}
      end)

    {plan, _capacities, unplaced, _position} =
      Enum.reduce(
        chunks,
        {[], capacities, 0, 0},
        fn chunk, {plan, room_caps, unplaced, position} ->
          {next_plan, next_caps, chunk_left, next_position} =
            Enum.reduce(destination_rooms, {plan, room_caps, chunk.amount, position}, fn room,
                                                                                         {rows,
                                                                                          caps,
                                                                                          left,
                                                                                          current_position} ->
              room_capacity = Map.get(caps, room.room_id, 0)
              piece = min(room_capacity, left)

              if piece > 0 do
                row = %{
                  entry: chunk.entry,
                  amount: piece,
                  destination_room_id: room.room_id,
                  allocation_position: current_position + 1
                }

                {rows ++ [row], Map.put(caps, room.room_id, room_capacity - piece), left - piece,
                 current_position + 1}
              else
                {rows, caps, left, current_position}
              end
            end)

          {next_plan, next_caps, unplaced + chunk_left, next_position}
        end
      )

    if unplaced != 0 do
      raise "validated transfer amount did not fit destination room deposits"
    end

    plan
  end

  defp move_funding_allocations!(plan, operation_id, destination_group_id) do
    moved_by_allocation =
      Enum.reduce(plan, %{}, fn row, amounts ->
        entry = row.entry
        key = {entry.kind, entry.allocation.id}
        Map.update(amounts, key, row.amount, &(&1 + row.amount))
      end)

    source_entries =
      plan
      |> Enum.map(& &1.entry)
      |> Enum.uniq_by(fn entry -> {entry.kind, entry.allocation.id} end)

    Enum.each(source_entries, fn entry ->
      moved = Map.fetch!(moved_by_allocation, {entry.kind, entry.allocation.id})

      case entry.kind do
        :cash ->
          entry.allocation
          |> Ecto.Changeset.change(
            recorded_cents: entry.allocation.recorded_cents - moved,
            held_cents: entry.allocation.held_cents - moved,
            transferred: true
          )
          |> Repo.update!()

        :credit ->
          entry.allocation
          |> Ecto.Changeset.change(amount_cents: entry.allocation.amount_cents - moved)
          |> Repo.update!()
      end
    end)

    Enum.each(plan, fn row ->
      entry = row.entry

      case entry.kind do
        :cash ->
          Repo.insert!(%CashPaymentAllocation{
            group_id: destination_group_id,
            room_id: row.destination_room_id,
            payment_operation_id: entry.allocation.payment_operation_id,
            recorded_cents: row.amount,
            held_cents: row.amount,
            transferred: true,
            allocation_operation_id: operation_id,
            allocation_position: row.allocation_position
          })

        :credit ->
          Repo.insert!(%HotelCreditAllocation{
            credit_lot_id: entry.allocation.credit_lot_id,
            group_id: destination_group_id,
            room_id: row.destination_room_id,
            funding_operation_id: entry.allocation.funding_operation_id,
            amount_cents: row.amount,
            allocation_operation_id: operation_id,
            allocation_position: row.allocation_position
          })
      end
    end)

    :ok
  end

  defp adjust_transfer_room_funding!(plan, source_group_id, destination_group_id) do
    deltas =
      Enum.reduce(plan, %{}, fn row, amounts ->
        kind = if row.entry.kind == :cash, do: :cash_paid_cents, else: :credit_paid_cents
        source_key = {source_group_id, row.entry.allocation.room_id, kind}
        destination_key = {destination_group_id, row.destination_room_id, kind}

        amounts
        |> Map.update(source_key, -row.amount, &(&1 - row.amount))
        |> Map.update(destination_key, row.amount, &(&1 + row.amount))
      end)

    Enum.each(deltas, fn {{group_id, room_id, field}, delta} ->
      room = Repo.get_by!(ReservationRoom, group_id: group_id, room_id: room_id)
      value = Map.fetch!(room, field) + delta

      room
      |> Ecto.Changeset.change(%{field => value})
      |> Repo.update!()
    end)
  end

  defp apply_to_reservation("record_cash_payment", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    amount = Map.get(operation, "amount_cents")

    unless is_integer(amount) and amount > 0 do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    outstanding = reservation.deposit_due_cents - reservation.deposit_paid_cents

    if amount > outstanding do
      reject!(
        rejected(operation_id, "payment_exceeds_outstanding", group_id: reservation.group_id)
      )
    end

    allocate_cash_to_rooms!(reservation, operation_id, amount)

    updated =
      update_reservation!(reservation, %{
        deposit_paid_cents: reservation.deposit_paid_cents + amount,
        cash_paid_cents: reservation.cash_paid_cents + amount
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
      revision: updated.revision
    }
  end

  defp apply_to_reservation("apply_hotel_credit", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    amount = Map.get(operation, "amount_cents")

    unless is_integer(amount) and amount > 0 do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    outstanding = reservation.deposit_due_cents - reservation.deposit_paid_cents

    if amount > outstanding do
      reject!(
        rejected(operation_id, "payment_exceeds_outstanding", group_id: reservation.group_id)
      )
    end

    occurred_on = operation_date_value(operation)

    lots =
      Repo.all(
        from lot in HotelCreditLot,
          where:
            lot.guest_id == ^reservation.guest_id and lot.issued_on <= ^occurred_on and
              lot.expires_on >= ^occurred_on and lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available < amount do
      reject!(rejected(operation_id, "insufficient_credit", group_id: reservation.group_id))
    end

    allocate_credit_to_rooms!(lots, reservation, operation_id, amount)

    updated =
      update_reservation!(reservation, %{
        deposit_paid_cents: reservation.deposit_paid_cents + amount,
        credit_paid_cents: reservation.credit_paid_cents + amount
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
      revision: updated.revision
    }
  end

  defp apply_to_reservation("reschedule_group", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    with {:ok, new_arrival} <-
           parse_domain_date(Map.get(operation, "new_arrival_on"), "invalid_stay", operation_id,
             group_id: reservation.group_id
           ),
         true <- Date.compare(new_arrival, operation_date_value(operation)) == :gt do
      shift = Date.diff(new_arrival, reservation.arrival_on)
      new_departure = Date.add(reservation.departure_on, shift)

      updated =
        update_reservation!(reservation, %{arrival_on: new_arrival, departure_on: new_departure})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated.group_id,
        new_arrival_on: new_arrival,
        new_departure_on: new_departure,
        policy_version: policy_version(updated),
        refundable_until: refundable_until(updated),
        revision: updated.revision
      }
    else
      false ->
        reject!(rejected(operation_id, "invalid_stay", group_id: reservation.group_id))

      {:error, result} ->
        reject!(result)
    end
  end

  defp apply_to_reservation("cancel_group", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)
    occurred_on = operation_date_value(operation)

    refund_method = Map.get(operation, "refund_method", "cash")

    unless refund_method in ["cash", "hotel_credit"] do
      reject!(rejected(operation_id, "invalid_operation", group_id: reservation.group_id))
    end

    refundable? = refundable?(reservation, occurred_on)

    if refund_method == "hotel_credit" and not refundable? do
      reject!(
        rejected(operation_id, "refund_method_not_available", group_id: reservation.group_id)
      )
    end

    rooms = active_rooms(reservation.group_id)

    settlement =
      settle_rooms!(reservation, rooms, operation_id, occurred_on, refund_method, refundable?)

    updated = settlement.reservation

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      refunded_cents: settlement.refunded_cents,
      retained_cents: settlement.retained_cents,
      credit_issued_cents: settlement.credit_issued_cents,
      revision: updated.revision
    }
  end

  defp apply_to_reservation("cancel_rooms", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    with {:ok, selected} <-
           selected_rooms(reservation, Map.get(operation, "room_ids"), operation_id),
         {:ok, occurred_on} <- operation_date(operation, operation_id) do
      refund_method = Map.get(operation, "refund_method", "cash")

      unless refund_method in ["cash", "hotel_credit"] do
        reject!(rejected(operation_id, "invalid_operation", group_id: reservation.group_id))
      end

      refundable? = refundable?(reservation, occurred_on)

      if refund_method == "hotel_credit" and not refundable? do
        reject!(
          rejected(operation_id, "refund_method_not_available", group_id: reservation.group_id)
        )
      end

      settlement =
        settle_rooms!(
          reservation,
          selected,
          operation_id,
          occurred_on,
          refund_method,
          refundable?
        )

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: settlement.reservation.group_id,
        cancelled_room_ids: Enum.map(selected, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: settlement.reservation.revision
      }
    else
      {:error, result} -> result
    end
  end

  defp reject!(result), do: throw({:handled_rejection, result})

  defp check_revision!(reservation, operation, operation_id, revision_key \\ "expected_revision") do
    case Map.fetch(operation, revision_key) do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        if expected == reservation.revision do
          :ok
        else
          reject!(
            rejected(operation_id, "stale_revision",
              group_id: reservation.group_id,
              expected_revision: expected,
              actual_revision: reservation.revision
            )
          )
        end

      {:ok, _invalid} ->
        reject!(rejected(operation_id, "invalid_operation", group_id: reservation.group_id))
    end
  end

  defp update_reservation!(reservation, changes) do
    reservation
    |> Ecto.Changeset.change(Map.put(changes, :revision, reservation.revision + 1))
    |> Repo.update!()
  end

  defp refresh_reservation!(reservation, extra_changes \\ %{}) do
    rooms = active_rooms(reservation.group_id)
    lodging = Enum.reduce(rooms, 0, &(room_lodging(&1, reservation) + &2))
    due = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))
    cash = Enum.reduce(rooms, 0, &(&1.cash_paid_cents + &2))
    credit = Enum.reduce(rooms, 0, &(&1.credit_paid_cents + &2))

    update_reservation!(
      reservation,
      Map.merge(
        %{
          lodging_total_cents: lodging,
          deposit_due_cents: due,
          deposit_paid_cents: cash + credit,
          cash_paid_cents: cash,
          credit_paid_cents: credit
        },
        extra_changes
      )
    )
  end

  defp allocate_cash_to_rooms!(reservation, operation_id, amount) do
    rooms = active_rooms(reservation.group_id)

    {allocated, _remaining} =
      Enum.reduce(rooms, {0, amount}, fn room, {allocated, remaining} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        piece = min(max(capacity, 0), remaining)

        if piece > 0 do
          Repo.insert!(%CashPaymentAllocation{
            group_id: reservation.group_id,
            room_id: room.room_id,
            payment_operation_id: operation_id,
            allocation_operation_id: operation_id,
            recorded_cents: piece,
            held_cents: piece
          })

          room
          |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + piece)
          |> Repo.update!()
        end

        {allocated + piece, remaining - piece}
      end)

    if allocated != amount do
      raise "cash allocation did not match validated payment amount"
    end
  end

  defp allocate_credit_to_rooms!(lots, reservation, operation_id, amount) do
    rooms = active_rooms(reservation.group_id)

    {allocated, remaining_lots} =
      Enum.reduce(rooms, {0, lots}, fn room, {allocated, available_lots} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        room_amount = min(max(capacity, 0), amount - allocated)

        {consumed, updated_lots} =
          consume_credit_lots_for_room!(available_lots, room, operation_id, room_amount)

        if consumed > 0 do
          room
          |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + consumed)
          |> Repo.update!()
        end

        {allocated + consumed, updated_lots}
      end)

    _ = remaining_lots

    if allocated != amount do
      raise "credit allocation did not match validated application amount"
    end
  end

  defp consume_credit_lots_for_room!(lots, room, operation_id, amount) do
    Enum.reduce_while(lots, {0, amount, []}, fn lot, {consumed, remaining, updated_lots} ->
      piece = min(lot.remaining_cents, remaining)

      if piece > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - piece)
        |> Repo.update!()

        Repo.insert!(%HotelCreditAllocation{
          credit_lot_id: lot.id,
          group_id: room.group_id,
          room_id: room.room_id,
          funding_operation_id: operation_id,
          allocation_operation_id: operation_id,
          amount_cents: piece
        })
      end

      next_lot =
        if piece > 0, do: %{lot | remaining_cents: lot.remaining_cents - piece}, else: lot

      left = remaining - piece
      next = {consumed + piece, left, updated_lots ++ [next_lot]}
      if left == 0, do: {:halt, next}, else: {:cont, next}
    end)
    |> then(fn {consumed, _remaining, updated_lots} ->
      {consumed, updated_lots ++ Enum.drop(lots, length(updated_lots))}
    end)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in ReservationRoom,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
    )
  end

  defp selected_rooms(reservation, room_ids, operation_id)
       when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &valid_identifier?/1) and
         length(room_ids) == MapSet.size(MapSet.new(room_ids)) do
      rooms = active_rooms(reservation.group_id)
      selected_ids = MapSet.new(room_ids)
      selected = Enum.filter(rooms, &MapSet.member?(selected_ids, &1.room_id))

      if length(selected) == length(room_ids) do
        {:ok, selected}
      else
        {:error, rejected(operation_id, "invalid_rooms", group_id: reservation.group_id)}
      end
    else
      {:error, rejected(operation_id, "invalid_rooms", group_id: reservation.group_id)}
    end
  end

  defp selected_rooms(reservation, _room_ids, operation_id),
    do: {:error, rejected(operation_id, "invalid_rooms", group_id: reservation.group_id)}

  defp settle_rooms!(reservation, rooms, operation_id, occurred_on, refund_method, refundable?) do
    room_ids = Enum.map(rooms, & &1.room_id)

    cash_allocations =
      Repo.all(
        from allocation in CashPaymentAllocation,
          where:
            allocation.group_id == ^reservation.group_id and allocation.room_id in ^room_ids and
              allocation.held_cents > 0,
          order_by: allocation.id
      )

    cash_held = Enum.reduce(cash_allocations, 0, &(&1.held_cents + &2))
    converted = if refundable? and refund_method == "hotel_credit", do: cash_held, else: 0
    refunded = if refundable? and refund_method == "cash", do: cash_held, else: 0
    retained = if refundable?, do: 0, else: cash_held
    credit_issued = credit_for_cash(converted)

    if credit_issued > @max_sqlite_integer do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    Enum.each(cash_allocations, fn allocation ->
      changes =
        cond do
          converted > 0 ->
            [held_cents: 0, converted_cents: allocation.converted_cents + allocation.held_cents]

          refunded > 0 ->
            [held_cents: 0, refunded_cents: allocation.refunded_cents + allocation.held_cents]

          true ->
            [held_cents: 0, retained_cents: allocation.retained_cents + allocation.held_cents]
        end

      allocation |> Ecto.Changeset.change(changes) |> Repo.update!()
    end)

    restore_or_consume_applied_credit!(reservation.group_id, room_ids, occurred_on, refundable?)

    if converted > 0 do
      lot =
        Repo.insert!(%HotelCreditLot{
          guest_id: reservation.guest_id,
          source_operation_id: operation_id,
          remaining_cents: credit_issued,
          issued_on: occurred_on,
          expires_on: Date.add(occurred_on, 365)
        })

      record_lot_entitlements!(lot, cash_allocations)
    end

    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(
        status: "cancelled",
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      )
      |> Repo.update!()
    end)

    remaining_rooms = active_rooms(reservation.group_id)
    lodging_total = Enum.reduce(remaining_rooms, 0, &(room_lodging(&1, reservation) + &2))
    due_total = Enum.reduce(remaining_rooms, 0, &(&1.deposit_due_cents + &2))
    cash_total = Enum.reduce(remaining_rooms, 0, &(&1.cash_paid_cents + &2))
    credit_total = Enum.reduce(remaining_rooms, 0, &(&1.credit_paid_cents + &2))

    updated =
      update_reservation!(reservation, %{
        status: if(remaining_rooms == [], do: "cancelled", else: "active"),
        lodging_total_cents: lodging_total,
        deposit_due_cents: due_total,
        deposit_paid_cents: cash_total + credit_total,
        cash_paid_cents: cash_total,
        credit_paid_cents: credit_total,
        refunded_cents: reservation.refunded_cents + refunded,
        retained_cents: reservation.retained_cents + retained,
        cash_converted_to_credit_cents: reservation.cash_converted_to_credit_cents + converted
      })

    %{
      reservation: updated,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued
    }
  end

  defp record_lot_entitlements!(lot, cash_allocations) do
    by_source =
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id, & &1.held_cents)
      |> Enum.map(fn {operation_id, amounts} -> {operation_id, Enum.sum(amounts)} end)
      |> Enum.filter(fn {_operation_id, amount} -> amount > 0 end)
      |> Enum.sort_by(fn
        {nil, _amount} ->
          {0, 0}

        {operation_id, _amount} ->
          id =
            Repo.one(
              from operation in PartnerOperation,
                where: operation.operation_id == ^operation_id,
                select: operation.id
            )

          {1, id || 0}
      end)

    {_running_cash, _running_credit} =
      Enum.reduce(by_source, {0, 0}, fn {operation_id, amount}, {running_cash, running_credit} ->
        next_cash = running_cash + amount
        next_credit = credit_for_cash(next_cash)
        entitlement = next_credit - running_credit

        Repo.insert!(%HotelCreditLotEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: operation_id,
          cash_cents: amount,
          entitlement_cents: entitlement
        })

        {next_cash, next_credit}
      end)
  end

  defp restore_or_consume_applied_credit!(group_id, room_ids, occurred_on, refundable?) do
    allocations =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
          preload: [:credit_lot]
      )

    if refundable? do
      allocations
      |> Enum.group_by(& &1.credit_lot_id)
      |> Enum.each(fn {_lot_id, lot_allocations} ->
        lot = hd(lot_allocations).credit_lot

        restore_credit_lot!(
          lot,
          Enum.reduce(lot_allocations, 0, &(&1.amount_cents + &2)),
          occurred_on
        )
      end)
    end

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp restore_credit_lot!(lot, amount, occurred_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    remaining_clawback = lot.unrecovered_clawback_cents - absorbed
    excess = amount - absorbed

    available =
      if Date.compare(lot.expires_on, occurred_on) != :lt,
        do: lot.remaining_cents + excess,
        else: lot.remaining_cents

    lot
    |> Ecto.Changeset.change(
      remaining_cents: available,
      unrecovered_clawback_cents: remaining_clawback
    )
    |> Repo.update!()
  end

  defp apply_payment_correction(
         "reduce_cash_payment",
         operation,
         reservation,
         payment,
         operation_id
       ) do
    unless applied_cash_payment?(payment) do
      reject!(rejected(operation_id, "payment_not_reducible", group_id: reservation.group_id))
    end

    payment_id = payment.operation_id
    allocations = payment_allocations(payment_id)
    held = Enum.reduce(allocations, 0, &(&1.held_cents + &2))

    if held == 0 do
      reject!(rejected(operation_id, "payment_not_reducible", group_id: reservation.group_id))
    end

    amount = Map.get(operation, "amount_cents")

    unless is_integer(amount) and amount > 0 do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    if amount > held do
      reject!(
        rejected(operation_id, "reduction_exceeds_held_cash", group_id: reservation.group_id)
      )
    end

    reduce_allocations!(allocations, amount)
    changed_groups = adjust_room_cash!(allocations, amount, :reduce)
    updated_groups = refresh_funding_groups!(reservation, Map.keys(changed_groups))
    updated = Map.fetch!(updated_groups, reservation.group_id)

    %{
      operation_id: operation_id,
      status: "applied",
      payment_operation_id: payment_id,
      group_id: reservation.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp apply_payment_correction(
         "charge_back_payment",
         _operation,
         reservation,
         payment,
         operation_id
       ) do
    unless applied_cash_payment?(payment) do
      reject!(rejected(operation_id, "payment_not_chargeable", group_id: reservation.group_id))
    end

    payment_id = payment.operation_id
    allocations = payment_allocations(payment_id)
    recorded = Enum.reduce(allocations, 0, &(&1.recorded_cents + &2))
    reduced = Enum.reduce(allocations, 0, &(&1.reduced_cents + &2))
    already_charged_back = Enum.reduce(allocations, 0, &(&1.charged_back_cents + &2))

    if recorded == reduced or already_charged_back > 0 do
      reject!(rejected(operation_id, "payment_not_chargeable", group_id: reservation.group_id))
    end

    held = Enum.reduce(allocations, 0, &(&1.held_cents + &2))
    charged_back = recorded - reduced

    disposition_changes =
      allocations
      |> Enum.group_by(& &1.group_id)
      |> Enum.reduce(%{}, fn {group_id, group_allocations}, changes_by_group ->
        changes = %{
          refunded_cents: Enum.reduce(group_allocations, 0, &(&1.refunded_cents + &2)),
          retained_cents: Enum.reduce(group_allocations, 0, &(&1.retained_cents + &2)),
          cash_converted_to_credit_cents:
            Enum.reduce(group_allocations, 0, &(&1.converted_cents + &2))
        }

        if Enum.any?(Map.values(changes), &(&1 > 0)),
          do: Map.put(changes_by_group, group_id, changes),
          else: changes_by_group
      end)

    Enum.each(allocations, fn allocation ->
      movable =
        allocation.held_cents + allocation.refunded_cents + allocation.retained_cents +
          allocation.converted_cents

      allocation
      |> Ecto.Changeset.change(
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: allocation.charged_back_cents + movable
      )
      |> Repo.update!()
    end)

    changed_groups = adjust_room_cash!(allocations, held, :chargeback)
    revoke_credit_entitlements!(payment_id)

    group_changes =
      Map.new(disposition_changes, fn {group_id, changes} ->
        current =
          if group_id == reservation.group_id,
            do: reservation,
            else: Repo.get!(Reservation, group_id)

        updated_changes = %{
          refunded_cents: max(current.refunded_cents - changes.refunded_cents, 0),
          retained_cents: max(current.retained_cents - changes.retained_cents, 0),
          cash_converted_to_credit_cents:
            max(
              current.cash_converted_to_credit_cents - changes.cash_converted_to_credit_cents,
              0
            )
        }

        {group_id, updated_changes}
      end)

    updated_groups =
      refresh_funding_groups!(
        reservation,
        Map.keys(changed_groups) ++ Map.keys(group_changes),
        group_changes
      )

    updated = Map.fetch!(updated_groups, reservation.group_id)

    %{
      operation_id: operation_id,
      status: "applied",
      payment_operation_id: payment_id,
      group_id: reservation.group_id,
      charged_back_cents: charged_back,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp applied_cash_payment?(%PartnerOperation{
         operation_type: "record_cash_payment",
         result: %{"status" => "applied", "amount_cents" => amount, "group_id" => group_id}
       })
       when is_integer(amount) and amount > 0 and is_binary(group_id),
       do: true

  defp applied_cash_payment?(_), do: false

  defp payment_allocations(payment_id) do
    Repo.all(
      from allocation in CashPaymentAllocation,
        where: allocation.payment_operation_id == ^payment_id,
        order_by: [desc: allocation.id]
    )
  end

  defp reduce_allocations!(allocations, amount) do
    {_left, _} =
      Enum.reduce_while(allocations, {amount, 0}, fn allocation, {remaining, _unused} ->
        reduced = min(allocation.held_cents, remaining)

        if reduced > 0 do
          allocation
          |> Ecto.Changeset.change(
            held_cents: allocation.held_cents - reduced,
            reduced_cents: allocation.reduced_cents + reduced
          )
          |> Repo.update!()
        end

        left = remaining - reduced
        if left == 0, do: {:halt, {0, reduced}}, else: {:cont, {left, reduced}}
      end)
  end

  defp adjust_room_cash!(allocations, amount, _reason) do
    # Allocation structs were loaded before reductions/chargebacks, so use the requested
    # amount across reverse fill order and update each affected room by its removed portion.
    {_left, changes} =
      Enum.reduce(allocations, {amount, []}, fn allocation, {remaining, changes} ->
        removed = min(allocation.held_cents, remaining)

        next_changes =
          if removed > 0,
            do: changes ++ [{{allocation.group_id, allocation.room_id}, removed}],
            else: changes

        {remaining - removed, next_changes}
      end)

    grouped = Enum.group_by(changes, &elem(&1, 0))

    Enum.each(grouped, fn {{group_id, room_id}, entries} ->
      removed = Enum.reduce(entries, 0, fn {_key, piece}, total -> total + piece end)

      if removed > 0 do
        room = Repo.get_by!(ReservationRoom, group_id: group_id, room_id: room_id)

        room
        |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents - removed)
        |> Repo.update!()
      end
    end)

    Enum.reduce(grouped, %{}, fn {{group_id, _room_id}, entries}, totals ->
      removed = Enum.reduce(entries, 0, fn {_key, piece}, total -> total + piece end)
      Map.update(totals, group_id, removed, &(&1 + removed))
    end)
  end

  defp refresh_funding_groups!(reservation, changed_group_ids, group_changes \\ %{}) do
    group_ids = Enum.uniq([reservation.group_id | changed_group_ids])

    Map.new(group_ids, fn group_id ->
      current =
        if group_id == reservation.group_id,
          do: reservation,
          else: Repo.get!(Reservation, group_id)

      changes = Map.get(group_changes, group_id, %{})
      {group_id, refresh_reservation!(current, changes)}
    end)
  end

  defp revoke_credit_entitlements!(payment_id) do
    entitlements =
      Repo.all(
        from entitlement in HotelCreditLotEntitlement,
          where: entitlement.payment_operation_id == ^payment_id,
          preload: [:credit_lot]
      )

    Enum.each(entitlements, fn entitlement ->
      lot = entitlement.credit_lot
      removed = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered = entitlement.entitlement_cents - removed

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
      )
      |> Repo.update!()
    end)
  end

  defp outstanding(%Reservation{status: "active"} = reservation),
    do: max(reservation.deposit_due_cents - reservation.deposit_paid_cents, 0)

  defp outstanding(_reservation), do: 0

  defp room_lodging(room, reservation),
    do: room.nightly_rate_cents * Date.diff(reservation.departure_on, reservation.arrival_on)

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp ensure_active!(%Reservation{status: "active"}, _operation_id), do: :ok

  defp ensure_active!(reservation, operation_id) do
    reject!(rejected(operation_id, "group_not_active", group_id: reservation.group_id))
  end

  defp refundable?(%Reservation{rate_plan: "flexible"} = reservation, occurred_on) do
    Date.diff(reservation.arrival_on, occurred_on) >= cancellation_window(reservation)
  end

  defp refundable?(_reservation, _occurred_on), do: false

  defp policy_version(%Reservation{policy_version: version}) when is_binary(version), do: version

  defp policy_version(%Reservation{rate_plan: rate_plan, booked_on: booked_on}) do
    policy_version_for(rate_plan, booked_on)
  end

  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp cancellation_window(%Reservation{rate_plan: "advance_purchase"}), do: 0

  defp cancellation_window(reservation),
    do: if(policy_version(reservation) == "flex-30", do: 30, else: 14)

  defp refundable_until(%Reservation{rate_plan: "advance_purchase"}), do: nil

  defp refundable_until(reservation) do
    Date.add(reservation.arrival_on, -cancellation_window(reservation))
  end

  defp credit_for_cash(0), do: 0

  defp credit_for_cash(cash_cents) do
    bonus = div(cash_cents * 10 + 50, 100)
    cash_cents + bonus
  end

  defp operation_date(operation, operation_id) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, rejected(operation_id, "invalid_operation")}
    end
  end

  defp operation_date_value(operation), do: elem(parse_date(operation["occurred_on"]), 1)

  defp check_operation_date!(operation, operation_id, group_id) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, _date} -> :ok
      :error -> reject!(rejected(operation_id, "invalid_operation", group_id: group_id))
    end
  end

  defp open_stay(operation, operation_id) do
    with {:ok, arrival} <-
           parse_domain_date(Map.get(operation, "arrival_on"), "invalid_stay", operation_id),
         {:ok, departure} <-
           parse_domain_date(Map.get(operation, "departure_on"), "invalid_stay", operation_id),
         true <- Date.compare(departure, arrival) == :gt do
      {:ok,
       %{arrival_on: arrival, departure_on: departure, nights: Date.diff(departure, arrival)}}
    else
      false -> {:error, rejected(operation_id, "invalid_stay")}
      {:error, result} -> {:error, result}
    end
  end

  defp rate_plan(operation, operation_id) do
    case Map.get(operation, "rate_plan") do
      plan when plan in ["flexible", "advance_purchase"] -> {:ok, plan}
      _ -> {:error, rejected(operation_id, "invalid_rate_plan")}
    end
  end

  defp rooms(operation, operation_id) do
    case Map.get(operation, "rooms") do
      room_list when is_list(room_list) and room_list != [] ->
        parsed = Enum.map(room_list, &parse_room/1)

        if Enum.all?(parsed, &match?({:ok, _}, &1)) do
          room_values = Enum.map(parsed, fn {:ok, room} -> room end)
          room_ids = Enum.map(room_values, & &1.room_id)

          if length(room_ids) == MapSet.size(MapSet.new(room_ids)) do
            {:ok, room_values}
          else
            {:error, rejected(operation_id, "invalid_rooms")}
          end
        else
          {:error, rejected(operation_id, "invalid_rooms")}
        end

      _ ->
        {:error, rejected(operation_id, "invalid_rooms")}
    end
  end

  defp parse_room(room) when is_map(room) do
    room_id = Map.get(room, "room_id")
    rate = Map.get(room, "nightly_rate_cents")

    if valid_identifier?(room_id) and is_integer(rate) and rate > 0 and
         rate <= @max_sqlite_integer do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
    else
      :error
    end
  end

  defp parse_room(_), do: :error

  defp totals(rooms, nights, rate_plan, operation_id) do
    Enum.reduce_while(rooms, {:ok, %{lodging: 0, deposit: 0}}, fn room, {:ok, acc} ->
      lodging = room.nightly_rate_cents * nights

      deposit =
        case rate_plan do
          "flexible" -> div(lodging * 20 + 50, 100)
          "advance_purchase" -> lodging
        end

      next = %{lodging: acc.lodging + lodging, deposit: acc.deposit + deposit}

      if lodging <= @max_sqlite_integer and deposit <= @max_sqlite_integer and
           next.lodging <= @max_sqlite_integer and next.deposit <= @max_sqlite_integer do
        {:cont, {:ok, next}}
      else
        {:halt, {:error, rejected(operation_id, "invalid_rooms")}}
      end
    end)
  end

  defp require_identifiers(operation, keys, operation_id) do
    if Enum.all?(keys, &valid_identifier?(Map.get(operation, &1))) do
      :ok
    else
      {:error, rejected(operation_id, "invalid_operation")}
    end
  end

  defp parse_domain_date(value, code, operation_id, extra \\ []) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, rejected(operation_id, code, extra)}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp valid_identifier?(value), do: is_binary(value) and String.trim(value) != ""

  defp rejected(operation_id, code, extra \\ []) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(extra))
  end

  defp group_json(reservation, rooms) do
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))
    lodging_total = Enum.reduce(active_rooms, 0, &(room_lodging(&1, reservation) + &2))
    deposit_due = Enum.reduce(active_rooms, 0, &(&1.deposit_due_cents + &2))
    cash_paid = Enum.reduce(active_rooms, 0, &(&1.cash_paid_cents + &2))
    credit_paid = Enum.reduce(active_rooms, 0, &(&1.credit_paid_cents + &2))
    deposit_paid = cash_paid + credit_paid

    %{
      group_id: reservation.group_id,
      guest_id: reservation.guest_id,
      property_id: reservation.property_id,
      revision: reservation.revision,
      booked_on: Date.to_iso8601(reservation.booked_on),
      arrival_on: Date.to_iso8601(reservation.arrival_on),
      departure_on: Date.to_iso8601(reservation.departure_on),
      rate_plan: reservation.rate_plan,
      policy_version: policy_version(reservation),
      refundable_until: refundable_until(reservation),
      status: reservation.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents: room_lodging(room, reservation),
            status: room.status,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: deposit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid,
      outstanding_deposit_cents: max(deposit_due - deposit_paid, 0)
    }
  end
end
