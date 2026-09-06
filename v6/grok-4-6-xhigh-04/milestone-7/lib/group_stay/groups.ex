defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Finance
  alias GroupStay.Repo
  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.CreditAllocation
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.LotEntitlement
  alias GroupStay.Groups.Operation
  alias GroupStay.Groups.PaymentTransferParticipation

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
  @held "held"
  @refunded "refunded"
  @retained "retained"
  @converted "converted"
  @reduced "reduced"
  @charged_back "charged_back"

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

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :not_found}
      operation -> {:ok, operation.result}
    end
  end

  def get_operation(_), do: {:error, :not_found}

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        {:error, :not_found}

      operation ->
        if applied_cash_payment?(operation) do
          {:ok, payment_statement(operation)}
        else
          {:error, :not_reconcilable}
        end
    end
  end

  def get_payment(_), do: {:error, :not_found}

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

  def daily_report(date) do
    Finance.daily_report(date)
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
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0,
          applied_credit: 0
        },
        fn group, acc ->
          {held, applied} =
            if group.status == @active do
              rooms = projected_room_maps(group)
              active = Enum.filter(rooms, &(&1.status == @active))
              cash = Enum.reduce(active, 0, fn room, sum -> sum + room.cash_paid_cents end)
              credit = Enum.reduce(active, 0, fn room, sum -> sum + room.credit_paid_cents end)
              {acc.cash_held_cents + cash, acc.applied_credit + credit}
            else
              {acc.cash_held_cents, acc.applied_credit}
            end

          %{
            cash_held_cents: held,
            cash_refunded_cents: acc.cash_refunded_cents + group.refunded_cents,
            cash_retained_cents: acc.cash_retained_cents + group.retained_cents,
            cash_converted_to_credit_cents:
              acc.cash_converted_to_credit_cents + converted_to_credit(group),
            cash_reduced_cents: acc.cash_reduced_cents + (group.cash_reduced_cents || 0),
            cash_charged_back_cents:
              acc.cash_charged_back_cents + (group.cash_charged_back_cents || 0),
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
      cash_reduced_cents: cash.cash_reduced_cents,
      cash_charged_back_cents: cash.cash_charged_back_cents,
      credit_liability_cents: available + cash.applied_credit,
      credit_shortfall_cents: credit_shortfall_cents()
    }
  end

  defp apply_one(op) when is_map(op) do
    op_id = fetch(op, "operation_id")

    case apply_durable(op, op_id) do
      {:ok, result} ->
        result

      :conflict ->
        %{operation_id: op_id, status: "rejected", code: "operation_id_conflict"}
    end
  end

  defp apply_one(_op) do
    %{operation_id: nil, status: "rejected", code: "invalid_operation"}
  end

  defp apply_durable(op, op_id) when is_binary(op_id) and byte_size(op_id) > 0 do
    case Repo.transaction(fn -> persist_and_run(op, op_id) end, mode: :immediate) do
      {:ok, result} -> {:ok, result}
      {:error, :conflict} -> :conflict
    end
  end

  defp apply_durable(op, op_id) do
    case Repo.transaction(fn -> run_operation(op, op_id) end) do
      {:ok, result} -> {:ok, result}
    end
  end

  defp persist_and_run(op, op_id) do
    claim =
      %Operation{}
      |> Operation.changeset(%{
        operation_id: op_id,
        type: operation_type(op),
        payload: jsonable(op),
        result: %{}
      })

    case Repo.insert(claim) do
      {:ok, record} ->
        result = run_operation(op, op_id)

        record
        |> Ecto.Changeset.change(%{result: result})
        |> Repo.update!()

        result

      {:error, changeset} ->
        if unique_operation_id?(changeset) do
          existing = Repo.get_by!(Operation, operation_id: op_id)

          if payloads_equivalent?(existing.payload, op) do
            existing.result
          else
            Repo.rollback(:conflict)
          end
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp run_operation(op, op_id) do
    case dispatch(op) do
      {:applied, payload} ->
        jsonable(Map.merge(%{operation_id: op_id, status: "applied"}, payload))

      {:rejected, payload} ->
        jsonable(Map.merge(%{operation_id: op_id, status: "rejected"}, payload))
    end
  end

  defp operation_type(op) do
    case fetch(op, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp unique_operation_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp payloads_equivalent?(left, right) do
    canonicalize(jsonable(left)) == canonicalize(jsonable(right))
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp jsonable(term) do
    term
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp dispatch(op) do
    case fetch(op, "type") do
      "open_group" -> open_group(op)
      "record_cash_payment" -> record_cash_payment(op)
      "reschedule_group" -> reschedule_group(op)
      "cancel_group" -> cancel_group(op)
      "cancel_rooms" -> cancel_rooms(op)
      "apply_hotel_credit" -> apply_hotel_credit(op)
      "reduce_cash_payment" -> reduce_cash_payment(op)
      "charge_back_payment" -> charge_back_payment(op)
      "transfer_deposit" -> transfer_deposit(op)
      "start_finance_reporting" -> start_finance_reporting(op)
      "close_finance_period" -> close_finance_period(op)
      _ -> {:rejected, %{code: "invalid_operation"}}
    end
  end

  defp start_finance_reporting(op) do
    with {:ok, starts_on} <- require_reporting_date(op) do
      if Finance.started?() do
        {:rejected, %{code: "reporting_already_started"}}
      else
        opening_cash = opening_cash_by_property()
        opening_credit = ledger().credit_liability_cents
        opening_lots = opening_credit_lots()

        case Finance.persist_start(
               starts_on,
               fetch(op, "operation_id"),
               opening_cash,
               opening_credit,
               opening_lots
             ) do
          :ok ->
            {:applied, %{starts_on: starts_on}}

          {:error, :already_started} ->
            {:rejected, %{code: "reporting_already_started"}}

          {:error, _changeset} ->
            {:rejected, %{code: "invalid_operation"}}
        end
      end
    end
  end

  defp close_finance_period(op) do
    with {:ok, period_end_on} <- require_period_end_on(op) do
      case Finance.persist_close(period_end_on) do
        :ok ->
          {:applied, %{period_end_on: period_end_on}}

        {:error, :invalid_period} ->
          {:rejected, %{code: "invalid_period"}}
      end
    end
  end

  defp opening_cash_by_property do
    Repo.all(Group)
    |> Enum.reduce(%{}, fn group, acc ->
      held =
        if group.status == @active do
          group
          |> projected_room_maps()
          |> Enum.filter(&(&1.status == @active))
          |> Enum.reduce(0, fn room, sum -> sum + room.cash_paid_cents end)
        else
          0
        end

      if held == 0 do
        acc
      else
        Map.update(acc, group.property_id, held, &(&1 + held))
      end
    end)
  end

  defp opening_credit_lots do
    today = Date.utc_today()

    from(l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^today)
    |> Repo.all()
    |> Enum.map(fn lot ->
      %{
        "source_operation_id" => lot.source_operation_id,
        "remaining_cents" => lot.remaining_cents,
        "expires_on" => Date.to_iso8601(lot.expires_on)
      }
    end)
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
          rooms = decorate_new_rooms(rooms, nights, rate_plan)
          lodging = lodging_total(rooms, nights)
          deposit = Enum.reduce(rooms, 0, fn room, acc -> acc + room.deposit_due_cents end)

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
            cash_reduced_cents: 0,
            cash_charged_back_cents: 0,
            allocations_ready: true,
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

        true ->
          group = ensure_room_accounting(group)
          rooms = fill_cash(group, amount, fetch(op, "operation_id"))
          revision = group.revision + 1
          {lodging, due, paid, cash, credit} = totals_from_rooms(rooms, nights(group))

          save_group(group, %{
            rooms: rooms,
            lodging_total_cents: lodging,
            deposit_due_cents: due,
            deposit_paid_cents: paid,
            cash_paid_cents: cash,
            credit_paid_cents: credit,
            revision: revision
          })

          Finance.cash(
            group.property_id,
            "received",
            amount,
            occurred_on,
            fetch(op, "operation_id")
          )

          {:applied,
           %{
             group_id: group.group_id,
             amount_cents: amount,
             outstanding_deposit_cents: due - paid,
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
          group = ensure_room_accounting(group)
          room_ids = active_room_ids(group)
          settle_rooms(group, room_ids, op, occurred_on, refund_method, :cancel_group)
      end
    end
  end

  defp cancel_rooms(op) do
    with {:ok, group} <- load_group_for_update(op),
         {:ok, occurred_on} <- require_date(op, "occurred_on"),
         {:ok, refund_method} <- require_refund_method(op),
         {:ok, room_ids} <- require_cancel_room_ids(op, group) do
      cond do
        refund_method == @hotel_credit and not refundable?(group, occurred_on) ->
          {:rejected, %{code: "refund_method_not_available"}}

        true ->
          group = ensure_room_accounting(group)
          settle_rooms(group, room_ids, op, occurred_on, refund_method, :cancel_rooms)
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
          group = ensure_room_accounting(group)
          rooms = consume_credit(group, amount, occurred_on, fetch(op, "operation_id"))
          revision = group.revision + 1
          {lodging, due, paid, cash, credit} = totals_from_rooms(rooms, nights(group))

          save_group(group, %{
            rooms: rooms,
            lodging_total_cents: lodging,
            deposit_due_cents: due,
            deposit_paid_cents: paid,
            cash_paid_cents: cash,
            credit_paid_cents: credit,
            revision: revision
          })

          {:applied,
           %{
             group_id: group.group_id,
             amount_cents: amount,
             outstanding_deposit_cents: due - paid,
             revision: revision
           }}
      end
    end
  end

  defp transfer_deposit(op) do
    with {:ok, source_id} <- require_id(op, "source_group_id"),
         {:ok, dest_id} <- require_id(op, "destination_group_id") do
      case Repo.get_by(Group, group_id: source_id) do
        nil ->
          {:rejected, %{code: "group_not_found", group_id: source_id}}

        source ->
          case Repo.get_by(Group, group_id: dest_id) do
            nil ->
              {:rejected, %{code: "group_not_found", group_id: dest_id}}

            dest ->
              with :ok <- revision_gate(source, op),
                   :ok <- destination_revision_gate(dest, op) do
                apply_transfer(op, source, dest)
              end
          end
      end
    end
  end

  defp apply_transfer(op, source, dest) do
    source = ensure_room_accounting(source)
    dest = ensure_room_accounting(dest)
    amount = fetch(op, "amount_cents")

    cond do
      source.group_id == dest.group_id or source.guest_id != dest.guest_id ->
        {:rejected, %{code: "invalid_transfer"}}

      source.status != @active ->
        {:rejected, %{code: "group_not_active", group_id: source.group_id}}

      dest.status != @active ->
        {:rejected, %{code: "group_not_active", group_id: dest.group_id}}

      not has_field?(op, "amount_cents") ->
        {:rejected, %{code: "invalid_operation"}}

      not valid_payment_amount?(amount) ->
        {:rejected, %{code: "invalid_amount"}}

      held_funding(source) < amount ->
        {:rejected, %{code: "transfer_exceeds_held_funding"}}

      outstanding(dest) < amount ->
        {:rejected, %{code: "transfer_exceeds_outstanding"}}

      true ->
        do_transfer(op, source, dest, amount)
    end
  end

  defp do_transfer(op, source, dest, amount) do
    slices = held_alloc_slices(source)
    {drawn, source_rooms} = draw_from_source(source, slices, amount)

    Enum.each(drawn, fn
      {:cash, alloc, _take} -> mark_transfer_participation(alloc.payment_operation_id)
      _ -> :ok
    end)

    lot_amounts =
      Enum.reduce(drawn, %{}, fn
        {:credit, alloc, take}, acc ->
          Map.update(acc, alloc.lot_source_operation_id, take, &(&1 + take))

        _, acc ->
          acc
      end)

    move_credit_applications(source.group_id, dest, lot_amounts)
    dest_rooms = fill_destination(dest, drawn)
    {source_rev, source_out} = save_funding_change(source, source_rooms, %{})
    {dest_rev, dest_out} = save_funding_change(dest, dest_rooms, %{})

    occurred_on = occurred_on_or_nil(op)
    op_id = fetch(op, "operation_id")
    Finance.cash(source.property_id, "transferred_out", amount, occurred_on, op_id)
    Finance.cash(dest.property_id, "transferred_in", amount, occurred_on, op_id)

    {:applied,
     %{
       source_group_id: source.group_id,
       destination_group_id: dest.group_id,
       amount_cents: amount,
       source_outstanding_deposit_cents: source_out,
       destination_outstanding_deposit_cents: dest_out,
       source_revision: source_rev,
       destination_revision: dest_rev
     }}
  end

  defp held_funding(group) do
    group
    |> room_maps()
    |> Enum.filter(&(&1.status == @active))
    |> Enum.reduce(0, fn room, acc -> acc + room.cash_paid_cents + room.credit_paid_cents end)
  end

  defp held_alloc_slices(group) do
    active_ids = active_room_ids(group)

    cash =
      from(a in CashAllocation,
        where:
          a.group_id == ^group.group_id and a.disposition == ^@held and a.room_id in ^active_ids
      )
      |> Repo.all()
      |> Enum.map(&{:cash, &1})

    credit =
      from(a in CreditAllocation,
        where: a.group_id == ^group.group_id and a.room_id in ^active_ids
      )
      |> Repo.all()
      |> Enum.map(&{:credit, &1})

    Enum.sort_by(cash ++ credit, fn
      {:cash, a} -> {-a.fill_seq, -a.id, 0}
      {:credit, a} -> {-a.fill_seq, -a.id, 1}
    end)
  end

  defp draw_from_source(source, slices, amount) do
    rooms = room_maps(source)

    {drawn, rooms, _left} =
      Enum.reduce(slices, {[], rooms, amount}, fn slice, {drawn, rooms, left} ->
        if left <= 0 do
          {drawn, rooms, left}
        else
          {kind, alloc} = slice
          take = min(alloc.amount_cents, left)
          remaining = alloc.amount_cents - take

          if remaining == 0 do
            Repo.delete!(alloc)
          else
            alloc
            |> Ecto.Changeset.change(%{amount_cents: remaining})
            |> Repo.update!()
          end

          rooms =
            Enum.map(rooms, fn room ->
              if room.room_id == alloc.room_id do
                case kind do
                  :cash -> %{room | cash_paid_cents: room.cash_paid_cents - take}
                  :credit -> %{room | credit_paid_cents: room.credit_paid_cents - take}
                end
              else
                room
              end
            end)

          {drawn ++ [{kind, alloc, take}], rooms, left - take}
        end
      end)

    {drawn, rooms}
  end

  defp fill_destination(dest, drawn) do
    seq = next_fill_seq(dest.group_id)

    {rooms, _seq} =
      Enum.reduce(drawn, {room_maps(dest), seq}, fn {kind, alloc, take}, {rooms, seq} ->
        case kind do
          :cash ->
            {rooms, _left, seq} =
              persist_fill_cash(dest.group_id, rooms, take, alloc.payment_operation_id, seq)

            {rooms, seq}

          :credit ->
            persist_fill_credit(
              dest.group_id,
              rooms,
              take,
              alloc.apply_operation_id,
              alloc.lot_source_operation_id,
              seq
            )
        end
      end)

    rooms
  end

  defp move_credit_applications(_source_id, _dest, lot_amounts) when lot_amounts == %{}, do: :ok

  defp move_credit_applications(source_id, dest, lot_amounts) do
    Enum.each(lot_amounts, fn {lot_source, amount} ->
      reduce_credit_applications(source_id, lot_source, amount)

      lot =
        Repo.get_by!(CreditLot,
          guest_id: dest.guest_id,
          source_operation_id: lot_source
        )

      %CreditApplication{}
      |> CreditApplication.changeset(%{
        group_id: dest.group_id,
        source_operation_id: lot_source,
        expires_on: lot.expires_on,
        amount_cents: amount
      })
      |> Repo.insert!()
    end)
  end

  defp mark_transfer_participation(nil), do: :ok

  defp mark_transfer_participation(payment_id) do
    %PaymentTransferParticipation{payment_operation_id: payment_id}
    |> Repo.insert(on_conflict: :nothing, conflict_target: :payment_operation_id)

    :ok
  end

  defp destination_revision_gate(group, op) do
    case fetch(op, "destination_expected_revision") do
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

  defp save_funding_change(group, rooms, extra) do
    revision = group.revision + 1
    {lodging, due, paid, cash, credit} = totals_from_rooms(rooms, nights(group))

    save_group(
      group,
      Map.merge(
        %{
          rooms: rooms,
          lodging_total_cents: lodging,
          deposit_due_cents: due,
          deposit_paid_cents: paid,
          cash_paid_cents: cash,
          credit_paid_cents: credit,
          revision: revision
        },
        extra
      )
    )

    {revision, due - paid}
  end

  defp reduce_cash_payment(op) do
    with {:ok, payment_id} <- require_id(op, "payment_operation_id"),
         {:ok, record} <- fetch_stored_operation(payment_id) do
      reduce_after_lookup(op, record, payment_id)
    end
  end

  defp reduce_after_lookup(op, record, payment_id) do
    if record.type == "record_cash_payment" do
      case load_payment_group(record, op) do
        {:rejected, _} = rejected ->
          rejected

        {:ok, nil} ->
          {:rejected, %{code: "payment_not_reducible"}}

        {:ok, group} ->
          group = ensure_room_accounting(group)
          apply_reduce(op, group, record, payment_id)
      end
    else
      {:rejected, %{code: "payment_not_reducible"}}
    end
  end

  defp apply_reduce(op, group, record, payment_id) do
    held = held_cash_for_payment(payment_id)

    cond do
      not applied_cash_payment?(record) or held <= 0 ->
        {:rejected, %{code: "payment_not_reducible"}}

      not has_field?(op, "amount_cents") ->
        {:rejected, %{code: "invalid_operation"}}

      true ->
        amount = fetch(op, "amount_cents")

        cond do
          not valid_payment_amount?(amount) ->
            {:rejected, %{code: "invalid_amount"}}

          amount > held ->
            {:rejected, %{code: "reduction_exceeds_held_cash"}}

          true ->
            do_reduce(op, group, payment_id, amount)
        end
    end
  end

  defp do_reduce(op, original_group, payment_id, amount) do
    allocs =
      from(a in CashAllocation,
        where: a.payment_operation_id == ^payment_id and a.disposition == ^@held,
        order_by: [desc: a.id]
      )
      |> Repo.all()

    takes_by_group =
      allocs
      |> Enum.reduce_while({%{}, amount}, fn alloc, {acc, left} ->
        if left <= 0 do
          {:halt, {acc, left}}
        else
          take = min(alloc.amount_cents, left)
          remaining = alloc.amount_cents - take

          if remaining == 0 do
            alloc
            |> Ecto.Changeset.change(%{disposition: @reduced})
            |> Repo.update!()
          else
            alloc
            |> Ecto.Changeset.change(%{amount_cents: remaining})
            |> Repo.update!()

            %CashAllocation{}
            |> CashAllocation.changeset(%{
              group_id: alloc.group_id,
              room_id: alloc.room_id,
              payment_operation_id: alloc.payment_operation_id,
              amount_cents: take,
              disposition: @reduced,
              fill_seq: alloc.fill_seq
            })
            |> Repo.insert!()
          end

          acc =
            Map.update(acc, alloc.group_id, %{alloc.room_id => take}, fn rooms ->
              Map.update(rooms, alloc.room_id, take, &(&1 + take))
            end)

          {:cont, {acc, left - take}}
        end
      end)
      |> elem(0)

    touched_ids =
      takes_by_group
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.put(original_group.group_id)

    {revision, outstanding} =
      Enum.reduce(touched_ids, {nil, nil}, fn gid, acc ->
        group =
          if gid == original_group.group_id do
            original_group
          else
            ensure_room_accounting(Repo.get_by!(Group, group_id: gid))
          end

        room_takes = Map.get(takes_by_group, gid, %{})

        rooms =
          Enum.map(room_maps(group), fn room ->
            case Map.get(room_takes, room.room_id) do
              nil -> room
              take -> %{room | cash_paid_cents: room.cash_paid_cents - take}
            end
          end)

        extra =
          if gid == original_group.group_id do
            %{cash_reduced_cents: (group.cash_reduced_cents || 0) + amount}
          else
            %{}
          end

        take_total = room_takes |> Map.values() |> Enum.sum()

        Finance.cash(
          group.property_id,
          "reduced",
          take_total,
          occurred_on_or_nil(op),
          fetch(op, "operation_id")
        )

        result = save_funding_change(group, rooms, extra)

        if gid == original_group.group_id, do: result, else: acc
      end)

    {:applied,
     %{
       payment_operation_id: payment_id,
       group_id: original_group.group_id,
       amount_cents: amount,
       outstanding_deposit_cents: outstanding,
       revision: revision
     }}
  end

  defp charge_back_payment(op) do
    with {:ok, payment_id} <- require_id(op, "payment_operation_id"),
         {:ok, record} <- fetch_stored_operation(payment_id) do
      chargeback_after_lookup(op, record, payment_id)
    end
  end

  defp chargeback_after_lookup(op, record, payment_id) do
    if record.type == "record_cash_payment" do
      case load_payment_group(record, op) do
        {:rejected, _} = rejected ->
          rejected

        {:ok, nil} ->
          {:rejected, %{code: "payment_not_chargeable"}}

        {:ok, group} ->
          group = ensure_room_accounting(group)
          apply_chargeback(op, group, record, payment_id)
      end
    else
      {:rejected, %{code: "payment_not_chargeable"}}
    end
  end

  defp apply_chargeback(op, group, record, payment_id) do
    totals = payment_disposition_totals(payment_id)
    reversible = totals[@held] + totals[@refunded] + totals[@retained] + totals[@converted]

    cond do
      not applied_cash_payment?(record) ->
        {:rejected, %{code: "payment_not_chargeable"}}

      totals[@charged_back] > 0 ->
        {:rejected, %{code: "payment_not_chargeable"}}

      reversible <= 0 ->
        {:rejected, %{code: "payment_not_chargeable"}}

      true ->
        do_chargeback(op, group, payment_id, totals, reversible)
    end
  end

  defp do_chargeback(op, original_group, payment_id, _totals, charged) do
    held_allocs =
      from(a in CashAllocation,
        where: a.payment_operation_id == ^payment_id and a.disposition == ^@held,
        order_by: [desc: a.id]
      )
      |> Repo.all()

    settled_allocs =
      from(a in CashAllocation,
        where:
          a.payment_operation_id == ^payment_id and
            a.disposition in ^[@refunded, @retained, @converted]
      )
      |> Repo.all()

    held_by_group =
      Enum.reduce(held_allocs, %{}, fn alloc, acc ->
        Map.update(acc, alloc.group_id, %{alloc.room_id => alloc.amount_cents}, fn rooms ->
          Map.update(rooms, alloc.room_id, alloc.amount_cents, &(&1 + alloc.amount_cents))
        end)
      end)

    settled_by_group =
      Enum.reduce(settled_allocs, %{}, fn alloc, acc ->
        inner =
          Map.get(acc, alloc.group_id, %{@refunded => 0, @retained => 0, @converted => 0})

        inner = Map.update!(inner, alloc.disposition, &(&1 + alloc.amount_cents))
        Map.put(acc, alloc.group_id, inner)
      end)

    from(a in CashAllocation,
      where:
        a.payment_operation_id == ^payment_id and
          a.disposition in ^[@held, @refunded, @retained, @converted]
    )
    |> Repo.update_all(set: [disposition: @charged_back])

    occurred_on = occurred_on_or_nil(op)
    op_id = fetch(op, "operation_id")
    revoke_entitlements(payment_id, occurred_on, op_id)

    touched =
      [original_group.group_id]
      |> Enum.concat(Map.keys(held_by_group))
      |> Enum.concat(Map.keys(settled_by_group))
      |> Enum.uniq()

    {revision, outstanding} =
      Enum.reduce(touched, {nil, nil}, fn gid, acc ->
        group =
          if gid == original_group.group_id do
            original_group
          else
            ensure_room_accounting(Repo.get_by!(Group, group_id: gid))
          end

        room_takes = Map.get(held_by_group, gid, %{})

        rooms =
          Enum.map(room_maps(group), fn room ->
            take = Map.get(room_takes, room.room_id, 0)

            if take > 0 and room.status == @active do
              %{room | cash_paid_cents: room.cash_paid_cents - take}
            else
              room
            end
          end)

        settled =
          Map.get(settled_by_group, gid, %{@refunded => 0, @retained => 0, @converted => 0})

        extra = %{
          refunded_cents: group.refunded_cents - settled[@refunded],
          retained_cents: group.retained_cents - settled[@retained],
          cash_converted_to_credit_cents: converted_to_credit(group) - settled[@converted]
        }

        extra =
          if gid == original_group.group_id do
            Map.put(
              extra,
              :cash_charged_back_cents,
              (group.cash_charged_back_cents || 0) + charged
            )
          else
            extra
          end

        held_amt = room_takes |> Map.values() |> Enum.sum()
        refunded_amt = settled[@refunded]
        retained_amt = settled[@retained]
        converted_amt = settled[@converted]

        Finance.cash(
          group.property_id,
          "charged_back",
          held_amt + refunded_amt + retained_amt + converted_amt,
          occurred_on,
          op_id
        )

        Finance.cash(group.property_id, "refunded", -refunded_amt, occurred_on, op_id)
        Finance.cash(group.property_id, "retained", -retained_amt, occurred_on, op_id)

        Finance.cash(
          group.property_id,
          "converted_to_credit",
          -converted_amt,
          occurred_on,
          op_id
        )

        result = save_funding_change(group, rooms, extra)
        if gid == original_group.group_id, do: result, else: acc
      end)

    {:applied,
     %{
       payment_operation_id: payment_id,
       group_id: original_group.group_id,
       charged_back_cents: charged,
       outstanding_deposit_cents: outstanding,
       revision: revision
     }}
  end

  defp settle_rooms(group, room_ids, op, occurred_on, refund_method, result_kind) do
    room_id_set = MapSet.new(room_ids)

    ordered_ids =
      group.rooms
      |> Enum.map(& &1.room_id)
      |> Enum.filter(&MapSet.member?(room_id_set, &1))

    held_cash_allocs =
      from(a in CashAllocation,
        where:
          a.group_id == ^group.group_id and a.room_id in ^room_ids and a.disposition == ^@held
      )
      |> Repo.all()

    cash = Enum.reduce(held_cash_allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)
    refundable = refundable?(group, occurred_on)

    {refunded, retained, converted, issued} =
      cond do
        refundable and refund_method == @hotel_credit ->
          {0, 0, cash, credit_from_cash(cash)}

        refundable ->
          {cash, 0, 0, 0}

        true ->
          {0, cash, 0, 0}
      end

    new_disposition =
      cond do
        converted > 0 -> @converted
        refunded > 0 -> @refunded
        retained > 0 -> @retained
        true -> nil
      end

    if new_disposition do
      Enum.each(held_cash_allocs, fn alloc ->
        alloc
        |> Ecto.Changeset.change(%{disposition: new_disposition})
        |> Repo.update!()
      end)
    end

    op_id = fetch(op, "operation_id")

    if issued > 0 do
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: op_id,
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 365),
        unrecovered_clawback_cents: 0
      })
      |> Repo.insert!()

      insert_entitlements(op_id, held_cash_allocs)
    end

    {consumed, expired, absorbed} =
      restore_or_consume_credit_for_rooms(group, room_ids, occurred_on, refundable, op_id)

    Finance.cash(group.property_id, "refunded", refunded, occurred_on, op_id)
    Finance.cash(group.property_id, "retained", retained, occurred_on, op_id)
    Finance.cash(group.property_id, "converted_to_credit", converted, occurred_on, op_id)

    Finance.credit("issued", issued, occurred_on, op_id,
      lot_source: op_id,
      expires_on: Date.add(occurred_on, 365)
    )

    Finance.credit("consumed", consumed, occurred_on, op_id)
    Finance.credit("expired", expired, occurred_on, op_id)
    Finance.credit("absorbed", absorbed, occurred_on, op_id)

    rooms =
      Enum.map(room_maps(group), fn room ->
        if MapSet.member?(room_id_set, room.room_id) do
          %{room | status: @cancelled, cash_paid_cents: 0, credit_paid_cents: 0}
        else
          room
        end
      end)

    revision = group.revision + 1
    {lodging, due, paid, cash_held, credit_held} = totals_from_rooms(rooms, nights(group))
    any_active? = Enum.any?(rooms, &(&1.status == @active))

    save_group(group, %{
      rooms: rooms,
      status: if(any_active?, do: @active, else: @cancelled),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: paid,
      cash_paid_cents: cash_held,
      credit_paid_cents: credit_held,
      refunded_cents: group.refunded_cents + refunded,
      retained_cents: group.retained_cents + retained,
      cash_converted_to_credit_cents: converted_to_credit(group) + converted,
      revision: revision
    })

    payload = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: revision
    }

    payload =
      if result_kind == :cancel_rooms do
        Map.put(payload, :cancelled_room_ids, ordered_ids)
      else
        payload
      end

    {:applied, payload}
  end

  defp restore_or_consume_credit_for_rooms(group, room_ids, occurred_on, refundable, op_id) do
    allocs =
      from(a in CreditAllocation,
        where: a.group_id == ^group.group_id and a.room_id in ^room_ids
      )
      |> Repo.all()

    totals =
      allocs
      |> Enum.group_by(& &1.lot_source_operation_id)
      |> Enum.reduce({0, 0, 0}, fn {lot_source, lot_allocs}, {consumed, expired, absorbed} ->
        amount = Enum.reduce(lot_allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)

        {consumed, expired, absorbed} =
          if refundable do
            lot =
              Repo.get_by!(CreditLot,
                guest_id: group.guest_id,
                source_operation_id: lot_source
              )

            {abs, exp, restored} = restore_to_lot(lot, amount, occurred_on)

            if restored > 0 do
              Finance.lot_delta(lot_source, lot.expires_on, restored, occurred_on, op_id)
            end

            {consumed, expired + exp, absorbed + abs}
          else
            {consumed + amount, expired, absorbed}
          end

        reduce_credit_applications(group.group_id, lot_source, amount)
        {consumed, expired, absorbed}
      end)

    ids = Enum.map(allocs, & &1.id)

    if ids != [] do
      from(a in CreditAllocation, where: a.id in ^ids) |> Repo.delete_all()
    end

    totals
  end

  defp restore_to_lot(lot, amount, occurred_on) do
    unrecovered = lot.unrecovered_clawback_cents || 0
    absorb = min(amount, unrecovered)
    excess = amount - absorb
    unrecovered = unrecovered - absorb

    {remaining, expired, restored} =
      if excess > 0 and Date.compare(lot.expires_on, occurred_on) != :lt do
        {lot.remaining_cents + excess, 0, excess}
      else
        {lot.remaining_cents, excess, 0}
      end

    lot
    |> Ecto.Changeset.change(%{
      remaining_cents: remaining,
      unrecovered_clawback_cents: unrecovered
    })
    |> Repo.update!()

    {absorb, expired, restored}
  end

  defp reduce_credit_applications(group_id, lot_source, amount) do
    apps =
      from(a in CreditApplication,
        where: a.group_id == ^group_id and a.source_operation_id == ^lot_source
      )
      |> Repo.all()

    Enum.reduce(apps, amount, fn app, left ->
      if left <= 0 do
        left
      else
        take = min(app.amount_cents, left)
        new_amount = app.amount_cents - take

        if new_amount == 0 do
          Repo.delete!(app)
        else
          app
          |> Ecto.Changeset.change(%{amount_cents: new_amount})
          |> Repo.update!()
        end

        left - take
      end
    end)
  end

  defp consume_credit(group, amount, occurred_on, apply_op_id) do
    lots = available_lots(group.guest_id, occurred_on)
    seq = next_fill_seq(group.group_id)

    {rooms, _left, _seq} =
      Enum.reduce_while(lots, {room_maps(group), amount, seq}, fn lot, {rooms, left, seq} ->
        if left == 0 do
          {:halt, {rooms, 0, seq}}
        else
          take = min(lot.remaining_cents, left)

          lot
          |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents - take})
          |> Repo.update!()

          Finance.lot_delta(
            lot.source_operation_id,
            lot.expires_on,
            -take,
            occurred_on,
            apply_op_id
          )

          %CreditApplication{}
          |> CreditApplication.changeset(%{
            group_id: group.group_id,
            source_operation_id: lot.source_operation_id,
            expires_on: lot.expires_on,
            amount_cents: take
          })
          |> Repo.insert!()

          {rooms, seq} =
            persist_fill_credit(
              group.group_id,
              rooms,
              take,
              apply_op_id,
              lot.source_operation_id,
              seq
            )

          {:cont, {rooms, left - take, seq}}
        end
      end)

    rooms
  end

  defp fill_cash(group, amount, payment_operation_id) do
    seq = next_fill_seq(group.group_id)

    {rooms, _left, _seq} =
      persist_fill_cash(group.group_id, room_maps(group), amount, payment_operation_id, seq)

    rooms
  end

  defp persist_fill_cash(group_id, rooms, amount, payment_operation_id, seq) do
    Enum.reduce(rooms, {[], amount, seq}, fn room, {acc, left, seq} ->
      take = min(remaining_space(room), left)

      if take <= 0 do
        {acc ++ [room], left, seq}
      else
        %CashAllocation{}
        |> CashAllocation.changeset(%{
          group_id: group_id,
          room_id: room.room_id,
          payment_operation_id: payment_operation_id,
          amount_cents: take,
          disposition: @held,
          fill_seq: seq
        })
        |> Repo.insert!()

        room = %{room | cash_paid_cents: room.cash_paid_cents + take}
        {acc ++ [room], left - take, seq + 1}
      end
    end)
  end

  defp persist_fill_credit(group_id, rooms, amount, apply_op_id, lot_source, seq) do
    {rooms, _left, seq} =
      Enum.reduce(rooms, {[], amount, seq}, fn room, {acc, left, seq} ->
        take = min(remaining_space(room), left)

        if take <= 0 do
          {acc ++ [room], left, seq}
        else
          %CreditAllocation{}
          |> CreditAllocation.changeset(%{
            group_id: group_id,
            room_id: room.room_id,
            apply_operation_id: apply_op_id,
            lot_source_operation_id: lot_source,
            amount_cents: take,
            fill_seq: seq
          })
          |> Repo.insert!()

          room = %{room | credit_paid_cents: room.credit_paid_cents + take}
          {acc ++ [room], left - take, seq + 1}
        end
      end)

    {rooms, seq}
  end

  defp insert_entitlements(lot_source_id, cash_allocs) do
    cash_allocs
    |> Enum.map(fn alloc ->
      %{
        payment_operation_id: alloc.payment_operation_id,
        amount_cents: alloc.amount_cents
      }
    end)
    |> entitlement_attrs(lot_source_id)
    |> Enum.each(fn attrs ->
      %LotEntitlement{}
      |> LotEntitlement.changeset(attrs)
      |> Repo.insert!()
    end)
  end

  defp entitlement_attrs(amount_rows, lot_source_id) do
    principals =
      amount_rows
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {id, rows} ->
        {id, Enum.reduce(rows, 0, fn row, acc -> acc + row.amount_cents end)}
      end)

    ordered = payment_ids_in_funding_order(Enum.map(principals, &elem(&1, 0)))
    principal_map = Map.new(principals)

    {attrs, _running, _prev} =
      Enum.reduce(ordered, {[], 0, 0}, fn pay_id, {acc, running, prev} ->
        principal = Map.fetch!(principal_map, pay_id)
        running = running + principal
        new_credit = credit_from_cash(running)

        attr = %{
          lot_source_operation_id: lot_source_id,
          payment_operation_id: pay_id,
          principal_cents: principal,
          entitlement_cents: new_credit - prev
        }

        {acc ++ [attr], running, new_credit}
      end)

    attrs
  end

  defp payment_ids_in_funding_order(ids) do
    ids = Enum.uniq(ids)
    {legacy, durable} = Enum.split_with(ids, &is_nil/1)

    durable_ordered =
      if durable == [] do
        []
      else
        from(o in Operation,
          where: o.operation_id in ^durable,
          order_by: [asc: o.id],
          select: o.operation_id
        )
        |> Repo.all()
      end

    missing = durable -- durable_ordered
    legacy ++ durable_ordered ++ missing
  end

  defp revoke_entitlements(payment_id, occurred_on, op_id) do
    ents =
      from(e in LotEntitlement, where: e.payment_operation_id == ^payment_id)
      |> Repo.all()

    Enum.each(ents, fn ent ->
      case Repo.get_by(CreditLot, source_operation_id: ent.lot_source_operation_id) do
        nil -> :ok
        lot -> clawback_lot(lot, ent.entitlement_cents, occurred_on, op_id)
      end

      Repo.delete!(ent)
    end)
  end

  defp clawback_lot(lot, entitlement, occurred_on, op_id) do
    take = min(lot.remaining_cents, entitlement)

    lot
    |> Ecto.Changeset.change(%{
      remaining_cents: lot.remaining_cents - take,
      unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + (entitlement - take)
    })
    |> Repo.update!()

    if take > 0 and Finance.available_on_posting?(lot.expires_on, occurred_on) do
      Finance.credit("revoked", take, occurred_on, op_id, lot_source: lot.source_operation_id)
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

  defp load_payment_group(record, op) do
    group_id = operation_group_id(record)

    cond do
      not is_binary(group_id) or group_id == "" ->
        {:ok, nil}

      true ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            {:ok, nil}

          group ->
            case revision_gate(group, op) do
              :ok -> {:ok, group}
              rejected -> rejected
            end
        end
    end
  end

  defp fetch_stored_operation(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:rejected, %{code: "operation_not_found"}}
      record -> {:ok, record}
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
    rooms = projected_room_maps(group)
    active = Enum.filter(rooms, &(&1.status == @active))
    due = Enum.reduce(active, 0, fn room, acc -> acc + room.deposit_due_cents end)

    paid =
      Enum.reduce(active, 0, fn room, acc ->
        acc + room.cash_paid_cents + room.credit_paid_cents
      end)

    due - paid
  end

  defp lodging_total(rooms, nights) do
    Enum.reduce(rooms, 0, fn room, acc ->
      acc + room.nightly_rate_cents * nights
    end)
  end

  defp room_deposit(room, nights, @advance_purchase), do: room.nightly_rate_cents * nights

  defp room_deposit(room, nights, @flexible) do
    round_half_up_percent(room.nightly_rate_cents * nights, 20)
  end

  defp decorate_new_rooms(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      Map.merge(room, %{
        status: @active,
        deposit_due_cents: room_deposit(room, nights, rate_plan),
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })
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
    rooms = projected_room_maps(group)
    active = Enum.filter(rooms, &(&1.status == @active))
    nights = nights(group)
    lodging = lodging_total(active, nights)
    due = Enum.reduce(active, 0, fn room, acc -> acc + room.deposit_due_cents end)
    cash = Enum.reduce(active, 0, fn room, acc -> acc + room.cash_paid_cents end)
    credit = Enum.reduce(active, 0, fn room, acc -> acc + room.credit_paid_cents end)
    paid = cash + credit

    outstanding =
      if group.status == @cancelled do
        0
      else
        due - paid
      end

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
      rooms: Enum.map(rooms, &serialize_room/1),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: paid,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: outstanding
    }
  end

  defp serialize_room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
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

  defp credit_shortfall_cents do
    applied =
      from(a in CreditAllocation,
        join: g in Group,
        on: g.group_id == a.group_id,
        where: g.status == ^@active,
        group_by: a.lot_source_operation_id,
        select: {a.lot_source_operation_id, sum(a.amount_cents)}
      )
      |> Repo.all()
      |> Map.new()

    from(l in CreditLot)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, acc ->
      applied_amt = Map.get(applied, lot.source_operation_id, 0) || 0
      unrecovered = lot.unrecovered_clawback_cents || 0
      acc + min(unrecovered, applied_amt)
    end)
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

  defp require_reporting_date(op) do
    case fetch(op, "starts_on") do
      nil ->
        {:rejected, %{code: "invalid_reporting_date"}}

      value ->
        case parse_date(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:rejected, %{code: "invalid_reporting_date"}}
        end
    end
  end

  defp require_period_end_on(op) do
    case fetch(op, "period_end_on") do
      nil ->
        {:rejected, %{code: "invalid_period"}}

      value ->
        case parse_date(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:rejected, %{code: "invalid_period"}}
        end
    end
  end

  defp occurred_on_or_nil(op) do
    case fetch(op, "occurred_on") do
      nil ->
        nil

      value ->
        case parse_date(value) do
          {:ok, date} -> date
          _ -> nil
        end
    end
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

  defp require_refund_method(op) do
    case fetch(op, "refund_method") do
      nil -> {:ok, @cash}
      @cash -> {:ok, @cash}
      @hotel_credit -> {:ok, @hotel_credit}
      _ -> {:rejected, %{code: "invalid_operation"}}
    end
  end

  defp require_cancel_room_ids(op, group) do
    case fetch(op, "room_ids") do
      nil ->
        {:rejected, %{code: "invalid_operation"}}

      ids when is_list(ids) ->
        rooms_by_id = Map.new(group.rooms, &{&1.room_id, &1})

        valid? =
          ids != [] and Enum.uniq(ids) == ids and
            Enum.all?(ids, fn id ->
              is_binary(id) and byte_size(id) > 0 and
                case Map.get(rooms_by_id, id) do
                  nil -> false
                  room -> room_status(group, room) == @active
                end
            end)

        if valid? do
          {:ok, ids}
        else
          {:rejected, %{code: "invalid_rooms"}}
        end

      _ ->
        {:rejected, %{code: "invalid_rooms"}}
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
  defp atom_key("room_ids"), do: :room_ids
  defp atom_key("payment_operation_id"), do: :payment_operation_id
  defp atom_key("source_group_id"), do: :source_group_id
  defp atom_key("destination_group_id"), do: :destination_group_id
  defp atom_key("destination_expected_revision"), do: :destination_expected_revision
  defp atom_key("starts_on"), do: :starts_on
  defp atom_key("period_end_on"), do: :period_end_on
  defp atom_key(_), do: nil

  defp nights(group), do: Date.diff(group.departure_on, group.arrival_on)

  defp room_maps(group) do
    nights = nights(group)

    Enum.map(group.rooms, fn room ->
      %{
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        status: room_status(group, room),
        deposit_due_cents: room.deposit_due_cents || room_deposit(room, nights, group.rate_plan),
        cash_paid_cents: room.cash_paid_cents || 0,
        credit_paid_cents: room.credit_paid_cents || 0
      }
    end)
  end

  defp room_status(%Group{status: @cancelled}, _room), do: @cancelled
  defp room_status(_group, %{status: status}) when is_binary(status), do: status
  defp room_status(_group, _room), do: @active

  defp remaining_space(%{status: status}) when status != @active, do: 0

  defp remaining_space(room) do
    max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
  end

  defp totals_from_rooms(rooms, nights) do
    active = Enum.filter(rooms, &(&1.status == @active))
    lodging = lodging_total(active, nights)
    due = Enum.reduce(active, 0, fn room, acc -> acc + (room.deposit_due_cents || 0) end)
    cash = Enum.reduce(active, 0, fn room, acc -> acc + (room.cash_paid_cents || 0) end)
    credit = Enum.reduce(active, 0, fn room, acc -> acc + (room.credit_paid_cents || 0) end)
    {lodging, due, cash + credit, cash, credit}
  end

  defp active_room_ids(group) do
    group
    |> room_maps()
    |> Enum.filter(&(&1.status == @active))
    |> Enum.map(& &1.room_id)
  end

  defp save_group(group, attrs) do
    rooms = Map.get(attrs, :rooms)
    scalar = Map.delete(attrs, :rooms)
    cs = Ecto.Changeset.change(group, scalar)

    cs =
      if rooms do
        Ecto.Changeset.put_embed(cs, :rooms, rooms)
      else
        cs
      end

    Repo.update!(cs)
  end

  defp next_fill_seq(group_id) do
    cash =
      from(a in CashAllocation, where: a.group_id == ^group_id, select: max(a.fill_seq))
      |> Repo.one() || 0

    credit =
      from(a in CreditAllocation, where: a.group_id == ^group_id, select: max(a.fill_seq))
      |> Repo.one() || 0

    max(cash, credit) + 1
  end

  defp ensure_room_accounting(%Group{allocations_ready: true} = group), do: group

  defp ensure_room_accounting(group) do
    {rooms, cash_attrs, credit_attrs, entitlement_rows} = build_accounting(group)

    Enum.each(cash_attrs, fn attrs ->
      %CashAllocation{}
      |> CashAllocation.changeset(attrs)
      |> Repo.insert!()
    end)

    Enum.each(credit_attrs, fn attrs ->
      %CreditAllocation{}
      |> CreditAllocation.changeset(attrs)
      |> Repo.insert!()
    end)

    Enum.each(entitlement_rows, fn attrs ->
      %LotEntitlement{}
      |> LotEntitlement.changeset(attrs)
      |> Repo.insert!()
    end)

    save_group(group, %{rooms: rooms, allocations_ready: true})
    Repo.get!(Group, group.id)
  end

  defp projected_room_maps(%Group{allocations_ready: true} = group), do: room_maps(group)

  defp projected_room_maps(group) do
    {rooms, _cash, _credit, _ents} = build_accounting(group)
    rooms
  end

  defp build_accounting(group) do
    nights = nights(group)

    rooms =
      Enum.map(group.rooms, fn room ->
        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: @active,
          deposit_due_cents: room_deposit(room, nights, group.rate_plan),
          cash_paid_cents: 0,
          credit_paid_cents: 0
        }
      end)

    ops = funding_operations(group.group_id)

    recorded_cash =
      ops
      |> Enum.filter(&(&1.type == "record_cash_payment"))
      |> Enum.reduce(0, fn op, acc -> acc + operation_amount(op) end)

    recorded_credit =
      ops
      |> Enum.filter(&(&1.type == "apply_hotel_credit"))
      |> Enum.reduce(0, fn op, acc -> acc + operation_amount(op) end)

    legacy_cash = max(cash_paid(group) - recorded_cash, 0)
    legacy_credit = max(credit_paid(group) - recorded_credit, 0)

    sources =
      if group.status == @cancelled do
        cancelled_cash_sources(legacy_cash, ops)
      else
        app_pools = credit_application_pools(group.group_id)

        {sources, _pools} =
          {[], app_pools}
          |> add_cash_source(nil, legacy_cash)
          |> add_credit_sources(nil, legacy_credit)
          |> add_durable_sources(ops)

        sources
      end

    {rooms, cash_attrs, credit_attrs, _seq} =
      allocate_sources(group.group_id, rooms, sources)

    if group.status == @cancelled do
      disposition = cancelled_cash_disposition(group)

      cash_attrs =
        if disposition do
          Enum.map(cash_attrs, &Map.put(&1, :disposition, disposition))
        else
          cash_attrs
        end

      rooms =
        Enum.map(rooms, fn room ->
          %{room | status: @cancelled, cash_paid_cents: 0, credit_paid_cents: 0}
        end)

      entitlements =
        if disposition == @converted do
          init_converted_entitlements(group, cash_attrs)
        else
          []
        end

      {rooms, cash_attrs, [], entitlements}
    else
      {rooms, cash_attrs, credit_attrs, []}
    end
  end

  defp cancelled_cash_sources(legacy_cash, ops) do
    sources = if legacy_cash > 0, do: [{:cash, nil, legacy_cash}], else: []

    Enum.reduce(ops, sources, fn op, acc ->
      if op.type == "record_cash_payment" do
        acc ++ [{:cash, op.operation_id, operation_amount(op)}]
      else
        acc
      end
    end)
  end

  defp add_cash_source({sources, pools}, _pay_id, amount) when amount <= 0, do: {sources, pools}

  defp add_cash_source({sources, pools}, pay_id, amount) do
    {sources ++ [{:cash, pay_id, amount}], pools}
  end

  defp add_credit_sources({sources, pools}, _apply_id, amount) when amount <= 0 do
    {sources, pools}
  end

  defp add_credit_sources({sources, pools}, apply_id, amount) do
    {slices, pools} = take_from_pools(pools, amount)
    extra = Enum.map(slices, fn {lot_id, amt} -> {:credit, apply_id, lot_id, amt} end)
    {sources ++ extra, pools}
  end

  defp add_durable_sources({sources, pools}, ops) do
    Enum.reduce(ops, {sources, pools}, fn op, acc ->
      amount = operation_amount(op)

      case op.type do
        "record_cash_payment" -> add_cash_source(acc, op.operation_id, amount)
        "apply_hotel_credit" -> add_credit_sources(acc, op.operation_id, amount)
        _ -> acc
      end
    end)
  end

  defp allocate_sources(group_id, rooms, sources) do
    Enum.reduce(sources, {rooms, [], [], 1}, fn source, {rooms, cash_attrs, credit_attrs, seq} ->
      case source do
        {:cash, pay_id, amount} ->
          {rooms, attrs, seq} = simulate_fill_cash(group_id, rooms, amount, pay_id, seq)
          {rooms, cash_attrs ++ attrs, credit_attrs, seq}

        {:credit, apply_id, lot_id, amount} ->
          {rooms, attrs, seq} =
            simulate_fill_credit(group_id, rooms, amount, apply_id, lot_id, seq)

          {rooms, cash_attrs, credit_attrs ++ attrs, seq}
      end
    end)
  end

  defp simulate_fill_cash(group_id, rooms, amount, payment_operation_id, seq) do
    Enum.reduce(rooms, {[], [], amount, seq}, fn room, {acc, attrs, left, seq} ->
      take = min(remaining_space(room), left)

      if take <= 0 do
        {acc ++ [room], attrs, left, seq}
      else
        attr = %{
          group_id: group_id,
          room_id: room.room_id,
          payment_operation_id: payment_operation_id,
          amount_cents: take,
          disposition: @held,
          fill_seq: seq
        }

        room = %{room | cash_paid_cents: room.cash_paid_cents + take}
        {acc ++ [room], attrs ++ [attr], left - take, seq + 1}
      end
    end)
    |> then(fn {rooms, attrs, _left, seq} -> {rooms, attrs, seq} end)
  end

  defp simulate_fill_credit(group_id, rooms, amount, apply_op_id, lot_source, seq) do
    Enum.reduce(rooms, {[], [], amount, seq}, fn room, {acc, attrs, left, seq} ->
      take = min(remaining_space(room), left)

      if take <= 0 do
        {acc ++ [room], attrs, left, seq}
      else
        attr = %{
          group_id: group_id,
          room_id: room.room_id,
          apply_operation_id: apply_op_id,
          lot_source_operation_id: lot_source,
          amount_cents: take,
          fill_seq: seq
        }

        room = %{room | credit_paid_cents: room.credit_paid_cents + take}
        {acc ++ [room], attrs ++ [attr], left - take, seq + 1}
      end
    end)
    |> then(fn {rooms, attrs, _left, seq} -> {rooms, attrs, seq} end)
  end

  defp credit_application_pools(group_id) do
    from(a in CreditApplication, where: a.group_id == ^group_id)
    |> Repo.all()
    |> Enum.sort_by(fn app -> {app.expires_on, app.source_operation_id} end)
    |> Enum.map(fn app -> {app.source_operation_id, app.amount_cents} end)
  end

  defp take_from_pools(pools, amount), do: take_from_pools(pools, amount, [])

  defp take_from_pools(pools, left, slices) when left <= 0 or pools == [] do
    {Enum.reverse(slices), pools}
  end

  defp take_from_pools([{lot, avail} | rest], left, slices) do
    take = min(avail, left)
    slices = if take > 0, do: [{lot, take} | slices], else: slices
    rest_pools = if avail > take, do: [{lot, avail - take} | rest], else: rest
    take_from_pools(rest_pools, left - take, slices)
  end

  defp funding_operations(group_id) do
    from(o in Operation, order_by: [asc: o.id])
    |> Repo.all()
    |> Enum.filter(fn op ->
      op.type in ["record_cash_payment", "apply_hotel_credit"] and
        result_status(op) == "applied" and
        operation_group_id(op) == group_id
    end)
  end

  defp cancelled_cash_disposition(group) do
    cond do
      converted_to_credit(group) > 0 -> @converted
      group.refunded_cents > 0 -> @refunded
      group.retained_cents > 0 -> @retained
      true -> nil
    end
  end

  defp init_converted_entitlements(group, cash_attrs) do
    cancel_op =
      from(o in Operation, where: o.type == "cancel_group", order_by: [desc: o.id])
      |> Repo.all()
      |> Enum.find(fn op ->
        result_status(op) == "applied" and operation_group_id(op) == group.group_id
      end)

    cond do
      cancel_op == nil ->
        []

      Repo.get_by(CreditLot, source_operation_id: cancel_op.operation_id) == nil ->
        []

      true ->
        entitlement_attrs(cash_attrs, cancel_op.operation_id)
    end
  end

  defp applied_cash_payment?(record) do
    record.type == "record_cash_payment" and result_status(record) == "applied"
  end

  defp result_status(record) do
    case record.result do
      %{"status" => status} -> status
      %{status: status} -> status
      _ -> nil
    end
  end

  defp operation_group_id(record) do
    result = record.result || %{}
    payload = record.payload || %{}
    Map.get(result, "group_id") || Map.get(payload, "group_id")
  end

  defp operation_amount(record) do
    result = record.result || %{}
    payload = record.payload || %{}
    Map.get(result, "amount_cents") || Map.get(payload, "amount_cents") || 0
  end

  defp held_cash_for_payment(payment_id) do
    from(a in CashAllocation,
      where: a.payment_operation_id == ^payment_id and a.disposition == ^@held,
      select: coalesce(sum(a.amount_cents), 0)
    )
    |> Repo.one()
  end

  defp payment_disposition_totals(payment_id) do
    empty = %{
      @held => 0,
      @refunded => 0,
      @retained => 0,
      @converted => 0,
      @reduced => 0,
      @charged_back => 0
    }

    from(a in CashAllocation, where: a.payment_operation_id == ^payment_id)
    |> Repo.all()
    |> Enum.reduce(empty, fn alloc, acc ->
      Map.update(acc, alloc.disposition, alloc.amount_cents, &(&1 + alloc.amount_cents))
    end)
  end

  defp payment_statement(operation) do
    payment_id = operation.operation_id
    group_id = operation_group_id(operation)
    recorded = operation_amount(operation)

    allocs =
      from(a in CashAllocation, where: a.payment_operation_id == ^payment_id)
      |> Repo.all()

    totals =
      if allocs == [] do
        derive_payment_totals(group_id, recorded)
      else
        empty = %{
          @held => 0,
          @refunded => 0,
          @retained => 0,
          @converted => 0,
          @reduced => 0,
          @charged_back => 0
        }

        Enum.reduce(allocs, empty, fn alloc, acc ->
          Map.update(acc, alloc.disposition, alloc.amount_cents, &(&1 + alloc.amount_cents))
        end)
      end

    statement = %{
      payment_operation_id: payment_id,
      original_group_id: group_id,
      recorded_cents: recorded,
      held_cents: Map.get(totals, @held, 0),
      refunded_cents: Map.get(totals, @refunded, 0),
      retained_cents: Map.get(totals, @retained, 0),
      converted_to_credit_cents: Map.get(totals, @converted, 0),
      reduced_cents: Map.get(totals, @reduced, 0),
      charged_back_cents: Map.get(totals, @charged_back, 0)
    }

    if payment_transferred?(payment_id) do
      held_by_group =
        allocs
        |> Enum.filter(&(&1.disposition == @held))
        |> Enum.group_by(& &1.group_id)
        |> Enum.map(fn {gid, list} ->
          %{
            group_id: gid,
            amount_cents: Enum.reduce(list, 0, fn alloc, acc -> acc + alloc.amount_cents end)
          }
        end)
        |> Enum.reject(&(&1.amount_cents <= 0))
        |> Enum.sort_by(& &1.group_id)

      Map.put(statement, :held_by_group, held_by_group)
    else
      statement
    end
  end

  defp payment_transferred?(payment_id) do
    Repo.get(PaymentTransferParticipation, payment_id) != nil
  end

  defp derive_payment_totals(group_id, recorded) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        %{@held => recorded}

      %Group{status: @active} ->
        %{@held => recorded}

      group ->
        cond do
          converted_to_credit(group) > 0 -> %{@converted => recorded}
          group.refunded_cents > 0 -> %{@refunded => recorded}
          group.retained_cents > 0 -> %{@retained => recorded}
          true -> %{}
        end
    end
  end
end
