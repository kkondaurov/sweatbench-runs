defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{
    Accounting,
    CashPayment,
    CreditLot,
    Finance,
    Group,
    OperationRecord,
    Repo,
    Room,
    RoomFundingAllocation
  }

  @rate_plans ~w(flexible advance_purchase)
  @active "active"
  @cancelled "cancelled"
  @policy_cutoff ~D[2027-01-01]
  @max_integer 9_223_372_036_854_775_807

  def submit_batch(operations) do
    Enum.map(operations, &execute/1)
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        group = Accounting.ensure_group(group)
        rooms = Accounting.all_rooms(group)

        render_group(group, rooms)
    end
  end

  def get_operation(operation_id) do
    case operation_record(operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_payment(payment_operation_id) do
    case operation_record(payment_operation_id) do
      nil ->
        :not_found

      record ->
        if applied_cash_payment?(record) do
          group_id = result_value(record.result, "group_id")
          group = Repo.get_by!(Group, group_id: group_id) |> Accounting.ensure_group()
          payment = Repo.get!(CashPayment, payment_operation_id)

          statement = %{
            payment_operation_id: payment.payment_operation_id,
            original_group_id: group.group_id,
            recorded_cents: payment.recorded_cents,
            held_cents: payment.held_cents,
            refunded_cents: payment.refunded_cents,
            retained_cents: payment.retained_cents,
            converted_to_credit_cents: payment.converted_to_credit_cents,
            reduced_cents: payment.reduced_cents,
            charged_back_cents: payment.charged_back_cents
          }

          statement =
            if payment.participated_in_transfer do
              held_by_group =
                Repo.all(
                  from allocation in RoomFundingAllocation,
                    join: room in Room,
                    on: room.id == allocation.room_record_id,
                    join: held_group in Group,
                    on: held_group.id == allocation.group_record_id,
                    where:
                      allocation.kind == "cash" and
                        allocation.source_operation_id == ^payment_operation_id and
                        room.status == @active,
                    group_by: held_group.group_id,
                    order_by: held_group.group_id,
                    select: %{
                      group_id: held_group.group_id,
                      amount_cents: sum(allocation.amount_cents)
                    }
                )

              Map.put(statement, :held_by_group, held_by_group)
            else
              statement
            end

          {:ok, statement}
        else
          :not_reconcilable
        end
    end
  end

  def guest_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on_days |> Date.from_gregorian_days() |> Date.to_iso8601()
          }
        end)
    }
  end

  def ledger(on) do
    Accounting.ensure_all()
    on_days = Date.to_gregorian_days(on)

    cash_held =
      Repo.aggregate(
        from(allocation in RoomFundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_record_id,
          where: allocation.kind == "cash" and room.status == @active
        ),
        :sum,
        :amount_cents
      ) || 0

    cash_totals =
      Repo.all(Group)
      |> Enum.reduce(
        %{
          cash_held_cents: cash_held,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0
        },
        fn group, totals ->
          totals
          |> Map.update!(:cash_refunded_cents, &(&1 + group.cash_refunded_cents))
          |> Map.update!(:cash_retained_cents, &(&1 + group.cash_retained_cents))
          |> Map.update!(
            :cash_converted_to_credit_cents,
            &(&1 + group.cash_converted_to_credit_cents)
          )
          |> Map.update!(:cash_reduced_cents, &(&1 + group.cash_reduced_cents))
          |> Map.update!(:cash_charged_back_cents, &(&1 + group.cash_charged_back_cents))
        end
      )

    available_credit =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.remaining_cents > 0 and lot.issued_on_days <= ^on_days and
              lot.expires_on_days >= ^on_days,
          select: lot.remaining_cents
      )
      |> Enum.sum()

    applied_credit =
      Repo.all(
        from allocation in RoomFundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_record_id,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where:
            allocation.kind == "credit" and room.status == @active and
              lot.issued_on_days <= ^on_days,
          select: allocation.amount_cents
      )
      |> Enum.sum()

    cash_totals
    |> Map.put(:credit_liability_cents, available_credit + applied_credit)
    |> Map.put(:credit_shortfall_cents, Accounting.credit_shortfall())
  end

  def daily_finance_report(date), do: Finance.report(date)

  defp execute(operation) when is_map(operation) do
    operation_id = operation_id(operation)

    if valid_identifier?(operation_id) do
      case operation_record(operation_id) do
        nil -> execute_first_attempt(operation, operation_id)
        record -> replay_or_conflict(record, operation, operation_id)
      end
    else
      execute_without_record(operation)
    end
  end

  defp execute(operation), do: execute_without_record(operation)

  defp execute_first_attempt(operation, operation_id) do
    transaction(fn ->
      case operation_record(operation_id) do
        nil ->
          result = apply_operation(operation)

          Repo.insert!(%OperationRecord{
            operation_id: operation_id,
            operation_type: submitted_type(operation),
            submission: operation,
            result: result
          })

          result

        record ->
          replay_or_conflict(record, operation, operation_id)
      end
    end)
  end

  defp execute_without_record(operation) do
    transaction(fn -> apply_operation(operation) end)
  end

  defp transaction(callback) do
    case Repo.transaction(callback, mode: :immediate) do
      {:ok, result} -> result
      {:error, reason} -> raise "operation transaction rolled back: #{inspect(reason)}"
    end
  end

  defp replay_or_conflict(record, operation, operation_id) do
    if record.submission == operation do
      record.result
    else
      rejected(operation_id, "operation_id_conflict")
    end
  end

  defp operation_record(operation_id) do
    Repo.get_by(OperationRecord, operation_id: operation_id)
  end

  defp submitted_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      case Map.get(operation, "type") do
        "open_group" -> open_group(operation, operation_id)
        "record_cash_payment" -> record_cash_payment(operation, operation_id)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id)
        "reschedule_group" -> reschedule_group(operation, operation_id)
        "cancel_group" -> cancel_group(operation, operation_id)
        "cancel_rooms" -> cancel_rooms(operation, operation_id)
        "transfer_deposit" -> transfer_deposit(operation, operation_id)
        "reduce_cash_payment" -> reduce_cash_payment(operation, operation_id)
        "charge_back_payment" -> charge_back_payment(operation, operation_id)
        "start_finance_reporting" -> start_finance_reporting(operation, operation_id)
        "close_finance_period" -> close_finance_period(operation, operation_id)
        _ -> rejected(operation_id, "invalid_operation")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_operation(operation), do: rejected(operation_id(operation), "invalid_operation")

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> validate_and_open(operation, operation_id, group_id)
        _group -> rejected(operation_id, "group_already_exists")
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp validate_and_open(operation, operation_id, group_id) do
    with {:ok, booked_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, arrival_on, departure_on, nights} <- validate_stay(operation),
         {:ok, rooms} <- validate_rooms(operation, nights),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         {:ok, rooms, lodging_total, deposit_due} <- calculate_totals(rooms, rate_plan) do
      policy_version = policy_version(rate_plan, booked_on)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version,
        status: @active,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        accounting_initialized: true,
        revision: 1
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          now_rooms =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              %{
                id: Ecto.UUID.generate(),
                group_record_id: group.id,
                position: position,
                room_id: room.room_id,
                nightly_rate_cents: room.nightly_rate_cents,
                status: @active,
                lodging_cents: room.lodging_cents,
                deposit_due_cents: room.deposit_cents
              }
            end)

          Repo.insert_all(Room, now_rooms)

          applied(operation_id, %{
            group_id: group_id,
            deposit_due_cents: deposit_due,
            revision: 1
          })

        {:error, changeset} ->
          if changeset.errors[:group_id] do
            rejected(operation_id, "group_already_exists")
          else
            rejected(operation_id, "invalid_operation")
          end
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp record_cash_payment(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, amount} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount) do
        revision = group.revision + 1
        paid = group.deposit_paid_cents + amount
        cash_paid = group.cash_paid_cents + amount

        Repo.insert!(%CashPayment{
          payment_operation_id: operation_id,
          group_record_id: group.id,
          recorded_cents: amount,
          held_cents: amount
        })

        Accounting.fund_cash(group, operation_id, amount)

        Finance.record(
          operation_id,
          occurred_on,
          [{group.property_id, "received", amount}],
          [],
          []
        )

        update_group(group,
          deposit_paid_cents: paid,
          cash_paid_cents: cash_paid,
          revision: revision
        )

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - paid,
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp apply_hotel_credit(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, amount} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount),
           {:ok, lots} <- sufficient_credit(group.guest_id, occurred_on, amount) do
        balance_events = Accounting.fund_credit(group, operation_id, lots, amount)
        Finance.record(operation_id, occurred_on, [], [], balance_events)

        revision = group.revision + 1
        paid = group.deposit_paid_cents + amount
        credit_paid = group.credit_paid_cents + amount

        update_group(group,
          deposit_paid_cents: paid,
          credit_paid_cents: credit_paid,
          revision: revision
        )

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - paid,
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp reschedule_group(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, new_arrival} <- required_date(operation, "new_arrival_on", "invalid_stay"),
           :ok <- arrival_after_operation(new_arrival, occurred_on) do
        nights = Date.diff(group.departure_on, group.arrival_on)
        new_departure = Date.add(new_arrival, nights)
        revision = group.revision + 1
        policy_version = group_policy_version(group)

        update_group(group,
          arrival_on: new_arrival,
          departure_on: new_departure,
          revision: revision
        )

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(new_arrival),
          new_departure_on: Date.to_iso8601(new_departure),
          policy_version: policy_version,
          refundable_until: refundable_until(policy_version, new_arrival),
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp cancel_group(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, refund_method} <- refund_method(operation),
           refundable = refundable?(group, occurred_on),
           :ok <- refund_method_available(refund_method, refundable) do
        rooms = Accounting.active_rooms(group)

        settlement =
          settle_rooms(group, rooms, operation_id, occurred_on, refund_method, refundable)

        applied(operation_id, %{
          group_id: group.group_id,
          refunded_cents: settlement.refunded_cents,
          retained_cents: settlement.retained_cents,
          credit_issued_cents: settlement.credit_issued_cents,
          revision: settlement.revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp cancel_rooms(operation, operation_id) do
    with_group(operation, operation_id, fn group ->
      with :ok <- active(group),
           {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, refund_method} <- refund_method(operation),
           refundable = refundable?(group, occurred_on),
           {:ok, rooms} <- selected_rooms(group, operation),
           :ok <- refund_method_available(refund_method, refundable) do
        settlement =
          settle_rooms(group, rooms, operation_id, occurred_on, refund_method, refundable)

        applied(operation_id, %{
          group_id: group.group_id,
          cancelled_room_ids: Enum.map(rooms, & &1.room_id),
          refunded_cents: settlement.refunded_cents,
          retained_cents: settlement.retained_cents,
          credit_issued_cents: settlement.credit_issued_cents,
          revision: settlement.revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp transfer_deposit(operation, operation_id) do
    with {:ok, source_group_id} <- required_identifier(operation, "source_group_id") do
      case Repo.get_by(Group, group_id: source_group_id) do
        nil ->
          rejected(operation_id, "group_not_found", %{group_id: source_group_id})

        source_group ->
          with {:ok, destination_group_id} <-
                 required_identifier(operation, "destination_group_id") do
            case Repo.get_by(Group, group_id: destination_group_id) do
              nil ->
                rejected(operation_id, "group_not_found", %{group_id: destination_group_id})

              destination_group ->
                source_group = Accounting.ensure_group(source_group)
                destination_group = Accounting.ensure_group(destination_group)

                with :ok <- transfer_revision(operation, source_group, "expected_revision"),
                     :ok <-
                       transfer_revision(
                         operation,
                         destination_group,
                         "destination_expected_revision"
                       ),
                     :ok <- valid_transfer_groups(source_group, destination_group),
                     :ok <- transfer_active(source_group),
                     :ok <- transfer_active(destination_group),
                     {:ok, occurred_on} <-
                       required_date(operation, "occurred_on", "invalid_operation"),
                     {:ok, amount} <- payment_amount(operation),
                     :ok <- transfer_within_held(source_group, amount),
                     :ok <- transfer_within_outstanding(destination_group, amount) do
                  moved = Accounting.move_held_funding(source_group, destination_group, amount)

                  moved_cash =
                    moved
                    |> Enum.filter(&(&1.kind == "cash"))
                    |> Enum.map(& &1.amount_cents)
                    |> Enum.sum()

                  Finance.record(
                    operation_id,
                    occurred_on,
                    [
                      {source_group.property_id, "transferred_out", moved_cash},
                      {destination_group.property_id, "transferred_in", moved_cash}
                    ],
                    [],
                    []
                  )

                  source_totals = Accounting.group_totals(source_group)
                  destination_totals = Accounting.group_totals(destination_group)
                  source_revision = source_group.revision + 1
                  destination_revision = destination_group.revision + 1

                  update_group_funding(source_group, source_totals, source_revision)

                  update_group_funding(
                    destination_group,
                    destination_totals,
                    destination_revision
                  )

                  applied(operation_id, %{
                    source_group_id: source_group.group_id,
                    destination_group_id: destination_group.group_id,
                    amount_cents: amount,
                    source_outstanding_deposit_cents: outstanding(source_totals),
                    destination_outstanding_deposit_cents: outstanding(destination_totals),
                    source_revision: source_revision,
                    destination_revision: destination_revision
                  })
                else
                  :error ->
                    rejected(operation_id, "invalid_operation")

                  {:error, code} ->
                    rejected(operation_id, code)

                  {:inactive, group_id} ->
                    rejected(operation_id, "group_not_active", %{group_id: group_id})

                  {:stale, group, expected} ->
                    stale_rejection(operation_id, group, expected)
                end
            end
          else
            :error -> rejected(operation_id, "invalid_operation")
          end
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp reduce_cash_payment(operation, operation_id) do
    with_payment_group(operation, operation_id, "payment_not_reducible", fn group, payment ->
      with {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           {:ok, amount} <- payment_amount(operation),
           :ok <- reducible(payment, amount) do
        reductions_by_group = Accounting.remove_held_cash(payment.payment_operation_id, amount)
        affected_group_ids = Map.keys(reductions_by_group)

        payment
        |> Ecto.Changeset.change(
          held_cents: payment.held_cents - amount,
          reduced_cents: payment.reduced_cents + amount
        )
        |> Repo.update!()

        {revision, totals} =
          update_payment_groups(group, affected_group_ids, fn current ->
            if current.id == group.id,
              do: [cash_reduced_cents: current.cash_reduced_cents + amount],
              else: []
          end)

        cash_entries =
          Enum.map(reductions_by_group, fn {group_id, reduced} ->
            property_id = Repo.get!(Group, group_id).property_id
            {property_id, "reduced", reduced}
          end)

        Finance.record(operation_id, occurred_on, cash_entries, [], [])

        applied(operation_id, %{
          payment_operation_id: payment.payment_operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents:
            totals.deposit_due_cents - totals.cash_paid_cents - totals.credit_paid_cents,
          revision: revision
        })
      else
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp charge_back_payment(operation, operation_id) do
    with_payment_group(operation, operation_id, "payment_not_chargeable", fn group, payment ->
      with {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
           true <- chargeable?(payment) do
        held = payment.held_cents
        charged_back = payment.recorded_cents - payment.reduced_cents

        held_by_group = Accounting.remove_held_cash(payment.payment_operation_id, held)
        held_group_ids = Map.keys(held_by_group)
        dispositions = Accounting.take_payment_dispositions(payment.payment_operation_id)
        revoked = Accounting.revoke_entitlements(payment.payment_operation_id)

        payment
        |> Ecto.Changeset.change(
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: charged_back
        )
        |> Repo.update!()

        disposition_by_group = Map.new(dispositions, &{&1.group_record_id, &1})
        affected_group_ids = held_group_ids ++ Map.keys(disposition_by_group)

        {revision, totals} =
          update_payment_groups(group, affected_group_ids, fn current ->
            disposition = Map.get(disposition_by_group, current.id)

            fields =
              if disposition do
                [
                  cash_refunded_cents: current.cash_refunded_cents - disposition.refunded_cents,
                  cash_retained_cents: current.cash_retained_cents - disposition.retained_cents,
                  cash_converted_to_credit_cents:
                    current.cash_converted_to_credit_cents -
                      disposition.converted_to_credit_cents
                ]
              else
                []
              end

            if current.id == group.id do
              Keyword.put(
                fields,
                :cash_charged_back_cents,
                current.cash_charged_back_cents + charged_back
              )
            else
              fields
            end
          end)

        held_entries =
          Enum.map(held_by_group, fn {group_id, amount} ->
            {Repo.get!(Group, group_id).property_id, "charged_back", amount}
          end)

        disposition_entries =
          Enum.flat_map(dispositions, fn disposition ->
            property_id = Repo.get!(Group, disposition.group_record_id).property_id

            [
              {property_id, "refunded", -disposition.refunded_cents},
              {property_id, "retained", -disposition.retained_cents},
              {property_id, "converted_to_credit", -disposition.converted_to_credit_cents},
              {property_id, "charged_back",
               disposition.refunded_cents + disposition.retained_cents +
                 disposition.converted_to_credit_cents}
            ]
          end)

        revoked_cents = Finance.revoked_cents(revoked.balance_events, occurred_on)

        Finance.record(
          operation_id,
          occurred_on,
          held_entries ++ disposition_entries,
          [{"revoked", revoked_cents}],
          revoked.balance_events
        )

        applied(operation_id, %{
          payment_operation_id: payment.payment_operation_id,
          group_id: group.group_id,
          charged_back_cents: charged_back,
          outstanding_deposit_cents:
            totals.deposit_due_cents - totals.cash_paid_cents - totals.credit_paid_cents,
          revision: revision
        })
      else
        false -> rejected(operation_id, "payment_not_chargeable")
        :error -> rejected(operation_id, "invalid_operation")
        {:error, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp start_finance_reporting(operation, operation_id) do
    case required_date(operation, "starts_on", "invalid_reporting_date") do
      {:ok, starts_on} ->
        case Finance.start(operation_id, starts_on) do
          :ok ->
            applied(operation_id, %{starts_on: Date.to_iso8601(starts_on)})

          {:error, code} ->
            rejected(operation_id, code)
        end

      :error ->
        rejected(operation_id, "invalid_reporting_date")

      {:error, code} ->
        rejected(operation_id, code)
    end
  end

  defp close_finance_period(operation, operation_id) do
    case required_date(operation, "period_end_on", "invalid_period") do
      {:ok, period_end_on} ->
        case Finance.close(period_end_on) do
          :ok -> applied(operation_id, %{period_end_on: Date.to_iso8601(period_end_on)})
          {:error, code} -> rejected(operation_id, code)
        end

      _error ->
        rejected(operation_id, "invalid_period")
    end
  end

  defp sufficient_credit(guest_id, occurred_on, amount) do
    lots = available_lots(guest_id, occurred_on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp available_lots(guest_id, on) do
    on_days = Date.to_gregorian_days(on)

    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.issued_on_days <= ^on_days and lot.expires_on_days >= ^on_days,
        order_by: [lot.expires_on_days, lot.source_operation_id, lot.id]
    )
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _other -> :error
    end
  end

  defp refund_method_available("hotel_credit", false),
    do: {:error, "refund_method_not_available"}

  defp refund_method_available(_refund_method, _refundable), do: :ok

  defp refundable?(group, occurred_on) do
    case refundable_until_date(group_policy_version(group), group.arrival_on) do
      nil -> false
      last_refundable_day -> not Date.after?(occurred_on, last_refundable_day)
    end
  end

  defp settle_rooms(group, rooms, operation_id, occurred_on, refund_method, refundable) do
    settled =
      Accounting.settle_rooms(group, rooms, operation_id, occurred_on, refund_method, refundable)

    refunded = if settled.disposition == :refunded_cents, do: settled.cash_cents, else: 0
    retained = if settled.disposition == :retained_cents, do: settled.cash_cents, else: 0

    converted =
      if settled.disposition == :converted_to_credit_cents, do: settled.cash_cents, else: 0

    cash_entries =
      case settled.disposition do
        :refunded_cents ->
          [{group.property_id, "refunded", settled.cash_cents}]

        :retained_cents ->
          [{group.property_id, "retained", settled.cash_cents}]

        :converted_to_credit_cents ->
          [{group.property_id, "converted_to_credit", settled.cash_cents}]
      end

    credit_entries = [
      {"issued", settled.issued_cents},
      {"expired", settled.expired_cents},
      {"consumed", settled.consumed_cents},
      {"absorbed", settled.absorbed_cents}
    ]

    Finance.record(
      operation_id,
      occurred_on,
      cash_entries,
      credit_entries,
      settled.balance_events
    )

    totals = Accounting.group_totals(group)
    status = if Accounting.active_rooms(group) == [], do: @cancelled, else: @active
    revision = group.revision + 1

    update_group(group,
      status: status,
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.cash_paid_cents + totals.credit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      cash_refunded_cents: group.cash_refunded_cents + refunded,
      cash_retained_cents: group.cash_retained_cents + retained,
      cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
      revision: revision
    )

    %{
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: settled.issued_cents,
      revision: revision
    }
  end

  defp selected_rooms(group, operation) do
    case Map.fetch(operation, "room_ids") do
      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &valid_identifier?/1) and
             MapSet.size(MapSet.new(room_ids)) == length(room_ids) do
          rooms =
            Repo.all(
              from room in Room,
                where:
                  room.group_record_id == ^group.id and room.status == @active and
                    room.room_id in ^room_ids,
                order_by: room.position
            )

          if length(rooms) == length(room_ids), do: {:ok, rooms}, else: {:error, "invalid_rooms"}
        else
          {:error, "invalid_rooms"}
        end

      {:ok, _other} ->
        {:error, "invalid_rooms"}

      :error ->
        :error
    end
  end

  defp with_group(operation, operation_id, callback) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          rejected(operation_id, "group_not_found")

        group ->
          group = Accounting.ensure_group(group)

          case check_revision(operation, group) do
            :ok ->
              callback.(group)

            {:stale, expected} ->
              rejected(operation_id, "stale_revision", %{
                group_id: group.group_id,
                expected_revision: expected,
                actual_revision: group.revision
              })

            :error ->
              rejected(operation_id, "invalid_operation")
          end
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp with_payment_group(operation, operation_id, invalid_target_code, callback) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id") do
      case operation_record(payment_operation_id) do
        nil ->
          rejected(operation_id, "operation_not_found")

        record ->
          if applied_cash_payment?(record) do
            group_id = result_value(record.result, "group_id")

            case Repo.get_by(Group, group_id: group_id) do
              nil ->
                rejected(operation_id, "group_not_found")

              group ->
                group = Accounting.ensure_group(group)

                case check_revision(operation, group) do
                  :ok ->
                    callback.(group, Repo.get!(CashPayment, payment_operation_id))

                  {:stale, expected} ->
                    rejected(operation_id, "stale_revision", %{
                      group_id: group.group_id,
                      expected_revision: expected,
                      actual_revision: group.revision
                    })

                  :error ->
                    rejected(operation_id, "invalid_operation")
                end
            end
          else
            rejected(operation_id, invalid_target_code)
          end
      end
    else
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp applied_cash_payment?(record) do
    record.operation_type == "record_cash_payment" and
      result_value(record.result, "status") == "applied"
  end

  defp reducible(%CashPayment{held_cents: 0}, _amount), do: {:error, "payment_not_reducible"}

  defp reducible(payment, amount) do
    if amount <= payment.held_cents, do: :ok, else: {:error, "reduction_exceeds_held_cash"}
  end

  defp chargeable?(payment) do
    payment.charged_back_cents == 0 and payment.recorded_cents > payment.reduced_cents
  end

  defp check_revision(operation, group, key \\ "expected_revision") do
    if Map.has_key?(operation, key) do
      case Map.get(operation, key) do
        expected when is_integer(expected) ->
          if expected == group.revision, do: :ok, else: {:stale, expected}

        _other ->
          :error
      end
    else
      :ok
    end
  end

  defp update_group(group, fields) do
    query = from item in Group, where: item.id == ^group.id and item.revision == ^group.revision
    {updated, _} = Repo.update_all(query, set: fields)

    if updated != 1, do: Repo.rollback(:concurrent_update)
  end

  defp update_group_funding(group, totals, revision) do
    update_group(group,
      deposit_paid_cents: totals.cash_paid_cents + totals.credit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      revision: revision
    )
  end

  defp update_payment_groups(addressed_group, affected_group_ids, extra_fields) do
    group_ids = Enum.uniq([addressed_group.id | affected_group_ids])

    Enum.reduce(group_ids, nil, fn group_id, addressed_result ->
      group =
        if group_id == addressed_group.id, do: addressed_group, else: Repo.get!(Group, group_id)

      totals = Accounting.group_totals(group)
      revision = group.revision + 1

      fields =
        [
          deposit_paid_cents: totals.cash_paid_cents + totals.credit_paid_cents,
          cash_paid_cents: totals.cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents,
          revision: revision
        ]
        |> Keyword.merge(extra_fields.(group))

      update_group(group, fields)

      if group.id == addressed_group.id,
        do: {revision, totals},
        else: addressed_result
    end)
  end

  defp transfer_revision(operation, group, key) do
    case check_revision(operation, group, key) do
      :ok -> :ok
      {:stale, expected} -> {:stale, group, expected}
      :error -> :error
    end
  end

  defp stale_rejection(operation_id, group, expected) do
    rejected(operation_id, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: expected,
      actual_revision: group.revision
    })
  end

  defp valid_transfer_groups(%Group{id: id}, %Group{id: id}), do: {:error, "invalid_transfer"}

  defp valid_transfer_groups(%Group{guest_id: guest_id}, %Group{guest_id: guest_id}), do: :ok
  defp valid_transfer_groups(_source, _destination), do: {:error, "invalid_transfer"}

  defp transfer_active(%Group{status: @active}), do: :ok
  defp transfer_active(group), do: {:inactive, group.group_id}

  defp transfer_within_held(group, amount) do
    totals = Accounting.group_totals(group)

    if totals.cash_paid_cents + totals.credit_paid_cents >= amount,
      do: :ok,
      else: {:error, "transfer_exceeds_held_funding"}
  end

  defp transfer_within_outstanding(group, amount) do
    if outstanding(Accounting.group_totals(group)) >= amount,
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp outstanding(totals) do
    totals.deposit_due_cents - totals.cash_paid_cents - totals.credit_paid_cents
  end

  defp active(%Group{status: @active}), do: :ok
  defp active(_group), do: {:error, "group_not_active"}

  defp payment_amount(operation) do
    if Map.has_key?(operation, "amount_cents") do
      case Map.get(operation, "amount_cents") do
        amount when is_integer(amount) and amount > 0 -> {:ok, amount}
        _other -> {:error, "invalid_amount"}
      end
    else
      :error
    end
  end

  defp payment_within_outstanding(group, amount) do
    totals = Accounting.group_totals(group)
    outstanding = totals.deposit_due_cents - totals.cash_paid_cents - totals.credit_paid_cents

    if amount <= outstanding do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp arrival_after_operation(arrival, occurred_on) do
    if Date.after?(arrival, occurred_on), do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_stay(operation) do
    with {:ok, arrival} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure} <- required_date(operation, "departure_on", "invalid_stay") do
      nights = Date.diff(departure, arrival)
      if nights > 0, do: {:ok, arrival, departure, nights}, else: {:error, "invalid_stay"}
    else
      :error -> :error
      {:error, _code} -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(operation, nights) do
    if Map.has_key?(operation, "rooms") do
      case Map.get(operation, "rooms") do
        rooms when is_list(rooms) and rooms != [] ->
          parsed = Enum.map(rooms, &validate_room(&1, nights))

          with true <- Enum.all?(parsed, &match?({:ok, _}, &1)),
               valid_rooms = Enum.map(parsed, fn {:ok, room} -> room end),
               true <- unique_room_ids?(valid_rooms) do
            {:ok, valid_rooms}
          else
            _other -> {:error, "invalid_rooms"}
          end

        _other ->
          {:error, "invalid_rooms"}
      end
    else
      :error
    end
  end

  defp validate_room(room, nights) when is_map(room) do
    with {:ok, room_id} <- required_identifier(room, "room_id"),
         rate when is_integer(rate) and rate > 0 <- Map.get(room, "nightly_rate_cents"),
         lodging = nights * rate,
         true <- lodging <= @max_integer do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate, lodging_cents: lodging}}
    else
      _other -> :error
    end
  end

  defp validate_room(_room, _nights), do: :error

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp validate_rate_plan(operation) do
    if Map.has_key?(operation, "rate_plan") do
      case Map.get(operation, "rate_plan") do
        rate_plan when rate_plan in @rate_plans -> {:ok, rate_plan}
        _other -> {:error, "invalid_rate_plan"}
      end
    else
      :error
    end
  end

  defp calculate_totals(rooms, rate_plan) do
    lodging_total = Enum.sum(Enum.map(rooms, & &1.lodging_cents))

    rooms =
      Enum.map(rooms, fn room ->
        deposit =
          case rate_plan do
            "flexible" -> div(room.lodging_cents * 20 + 50, 100)
            "advance_purchase" -> room.lodging_cents
          end

        Map.put(room, :deposit_cents, deposit)
      end)

    deposit_due = Enum.sum(Enum.map(rooms, & &1.deposit_cents))

    if lodging_total <= @max_integer and deposit_due <= @max_integer do
      {:ok, rooms, lodging_total, deposit_due}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, @policy_cutoff), do: "flex-14", else: "flex-30"
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp group_policy_version(group), do: policy_version(group.rate_plan, group.booked_on)

  defp refundable_until_date("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until_date("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until_date("advance-nonrefundable", _arrival_on), do: nil

  defp refundable_until(policy_version, arrival_on) do
    case refundable_until_date(policy_version, arrival_on) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp required_identifier(map, key) do
    if Map.has_key?(map, key) and valid_identifier?(Map.get(map, key)) do
      {:ok, Map.get(map, key)}
    else
      :error
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp required_date(map, key, invalid_code) do
    if Map.has_key?(map, key) do
      case Map.get(map, key) do
        value when is_binary(value) ->
          case Date.from_iso8601(value) do
            {:ok, date} -> {:ok, date}
            {:error, _reason} -> {:error, invalid_code}
          end

        _other ->
          {:error, invalid_code}
      end
    else
      :error
    end
  end

  defp render_group(group, rooms) do
    policy_version = group_policy_version(group)
    room_totals = Accounting.room_totals(rooms)

    active_room_totals =
      Enum.filter(room_totals, fn {room, _cash, _credit} -> room.status == @active end)

    lodging_total =
      Enum.sum(Enum.map(active_room_totals, fn {room, _cash, _credit} -> room.lodging_cents end))

    deposit_due =
      Enum.sum(
        Enum.map(active_room_totals, fn {room, _cash, _credit} -> room.deposit_due_cents end)
      )

    cash_paid = Enum.sum(Enum.map(active_room_totals, fn {_room, cash, _credit} -> cash end))
    credit_paid = Enum.sum(Enum.map(active_room_totals, fn {_room, _cash, credit} -> credit end))

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version,
      refundable_until: refundable_until(policy_version, group.arrival_on),
      status: group.status,
      rooms:
        Enum.map(room_totals, fn {room, cash, credit} ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: cash,
            credit_paid_cents: credit
          }
        end),
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: cash_paid + credit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid,
      outstanding_deposit_cents: deposit_due - cash_paid - credit_paid
    }
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejected(operation_id, code, fields \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp result_value(result, key), do: Map.get(result, key) || Map.get(result, String.to_atom(key))
end
