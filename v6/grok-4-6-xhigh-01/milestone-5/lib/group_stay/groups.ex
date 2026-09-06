defmodule GroupStay.Groups do
  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.CreditLotEntitlement
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Operation
  alias GroupStay.Groups.PaymentTransferFlag

  @rate_plans ~w(flexible advance_purchase)
  @policy_cutoff ~D[2027-01-01]
  @refund_methods ~w(cash hotel_credit)

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_by_group_id(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{} = group -> ensure_allocations!(group)
      nil -> nil
    end
  end

  def get_by_group_id(_), do: nil

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{result: result} -> result
      nil -> nil
    end
  end

  def get_operation_result(_), do: nil

  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      record ->
        if applied_cash_payment?(record) do
          case result_group_id(record.result) do
            group_id when is_binary(group_id) ->
              case Repo.get_by(Group, group_id: group_id) do
                %Group{} = group -> ensure_allocations!(group)
                _ -> :ok
              end

            _ ->
              :ok
          end

          {:ok, payment_statement(record)}
        else
          :not_reconcilable
        end
    end
  end

  def get_payment_statement(_), do: :not_found

  def backfill_room_accounting! do
    Repo.all(Group)
    |> Enum.each(fn group ->
      ensure_allocations!(group)
    end)
  end

  def ledger_totals(as_of \\ Date.utc_today()) do
    backfill_room_accounting!()

    totals =
      Repo.all(
        from a in CashAllocation,
          group_by: a.status,
          select: {a.status, coalesce(sum(a.amount_cents), 0)}
      )
      |> Map.new()

    %{
      cash_held_cents: Map.get(totals, "held", 0),
      cash_refunded_cents: Map.get(totals, "refunded", 0),
      cash_retained_cents: Map.get(totals, "retained", 0),
      cash_converted_to_credit_cents: Map.get(totals, "converted", 0),
      cash_reduced_cents: Map.get(totals, "reduced", 0),
      cash_charged_back_cents: Map.get(totals, "charged_back", 0),
      credit_liability_cents: credit_liability_cents(as_of),
      credit_shortfall_cents: credit_shortfall_cents()
    }
  end

  def guest_credit(guest_id, as_of \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

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

  def serialize(%Group{} = group) do
    group = ensure_allocations!(group)
    cash_by_room = held_cash_by_room(group.group_id)
    credit_by_room = held_credit_by_room(group.group_id)

    rooms =
      Enum.map(group.rooms, fn room ->
        status = room_status(room, group)

        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: status,
          deposit_due_cents: room_deposit_due(room, group),
          cash_paid_cents:
            if(status == "active", do: Map.get(cash_by_room, room.room_id, 0), else: 0),
          credit_paid_cents:
            if(status == "active", do: Map.get(credit_by_room, room.room_id, 0), else: 0)
        }
      end)

    active = Enum.filter(rooms, &(&1.status == "active"))
    due = Enum.reduce(active, 0, fn room, acc -> acc + room.deposit_due_cents end)
    cash = Enum.reduce(active, 0, fn room, acc -> acc + room.cash_paid_cents end)
    credit = Enum.reduce(active, 0, fn room, acc -> acc + room.credit_paid_cents end)
    paid = cash + credit

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: rooms,
      lodging_total_cents: active_lodging(group),
      deposit_due_cents: due,
      deposit_paid_cents: paid,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: if(group.status == "active", do: due - paid, else: 0)
    }
  end

  defp apply_operation(operation) when not is_map(operation) do
    rejected(operation, "invalid_operation")
  end

  defp apply_operation(operation) do
    operation = stringify_keys(operation)

    case rememberable_id(operation) do
      nil ->
        execute(operation)

      operation_id ->
        apply_remembered(operation_id, operation)
    end
  end

  defp apply_remembered(operation_id, operation) do
    case fetch_operation(operation_id) do
      %Operation{} = record ->
        replay_or_conflict(record, operation)

      nil ->
        case persist_first(operation_id, operation) do
          {:ok, result} ->
            result

          {:error, :taken} ->
            case fetch_operation(operation_id) do
              %Operation{} = record ->
                replay_or_conflict(record, operation)

              nil ->
                raise "missing idempotency record for #{operation_id}"
            end
        end
    end
  end

  defp persist_first(operation_id, operation) do
    case Repo.transaction(fn ->
           case fetch_operation(operation_id) do
             %Operation{} = record ->
               replay_or_conflict(record, operation)

             nil ->
               case claim(operation_id) do
                 {:ok, record} ->
                   result = result_of(operation)
                   finalize!(record, operation, result)
                   result

                 {:error, :taken} ->
                   Repo.rollback(:taken)
               end
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :taken} -> {:error, :taken}
    end
  end

  defp execute(operation) do
    case transact(fn -> dispatch(operation) end) do
      {:ok, result} -> canonicalize(result)
      {:error, result} when is_map(result) -> canonicalize(result)
      {:error, code} when is_binary(code) -> canonicalize(rejected(operation, code))
    end
  end

  defp result_of(operation) do
    Repo.query!("SAVEPOINT operation_domain")

    try do
      case dispatch(operation) do
        {:ok, result} ->
          Repo.query!("RELEASE SAVEPOINT operation_domain")
          canonicalize(result)

        {:error, result} when is_map(result) ->
          rollback_domain_savepoint()
          canonicalize(result)

        {:error, code} when is_binary(code) ->
          rollback_domain_savepoint()
          canonicalize(rejected(operation, code))
      end
    rescue
      exception ->
        _ = Repo.query("ROLLBACK TO SAVEPOINT operation_domain")
        reraise exception, __STACKTRACE__
    end
  end

  defp rollback_domain_savepoint do
    Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
    Repo.query!("RELEASE SAVEPOINT operation_domain")
  end

  defp rememberable_id(%{"operation_id" => id}) when is_binary(id) and id != "", do: id
  defp rememberable_id(_), do: nil

  defp fetch_operation(operation_id) do
    Repo.get_by(Operation, operation_id: operation_id)
  end

  defp claim(operation_id) do
    %Operation{}
    |> Operation.changeset(%{
      operation_id: operation_id,
      payload: %{},
      result: %{}
    })
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        if unique_error?(changeset, :operation_id) do
          {:error, :taken}
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp finalize!(record, operation, result) do
    record
    |> Operation.changeset(%{
      type: operation_type(operation),
      payload: canonicalize(operation),
      result: result
    })
    |> Repo.update!()
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil

  defp replay_or_conflict(%Operation{} = record, operation) do
    if equivalent_payload?(record.payload, operation) do
      record.result
    else
      canonicalize(%{
        operation_id: record.operation_id,
        status: "rejected",
        code: "operation_id_conflict"
      })
    end
  end

  defp equivalent_payload?(stored, incoming) do
    canonicalize(stored) == canonicalize(incoming)
  end

  defp canonicalize(%Date{} = date), do: Date.to_iso8601(date)

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), canonicalize(value)} end)
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)
  defp dispatch(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp dispatch(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp dispatch(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

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
              if unique_error?(changeset, :group_id) do
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
      group = ensure_allocations!(group)
      outstanding = outstanding(group)

      cond do
        amount > outstanding ->
          {:error, rejected(operation, "payment_exceeds_outstanding")}

        true ->
          allocate_cash!(group, amount, operation["operation_id"])
          {:ok, group} = persist_group_change(group, active_money_from_group(group))

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

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, amount} <- req_payment_amount(operation) do
      group = ensure_allocations!(group)
      outstanding = outstanding(group)

      cond do
        amount > outstanding ->
          {:error, rejected(operation, "payment_exceeds_outstanding")}

        true ->
          case consume_credit(group, amount, occurred_on, operation["operation_id"]) do
            :ok ->
              {:ok, group} = persist_group_change(group, active_money_from_group(group))

              {:ok,
               applied(operation, %{
                 group_id: group.group_id,
                 amount_cents: amount,
                 outstanding_deposit_cents: outstanding(group),
                 revision: group.revision
               })}

            {:error, code} ->
              {:error, rejected(operation, code)}
          end
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
        persist_group_change(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      {:ok,
       applied(operation, %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         policy_version: policy_version(group),
         refundable_until: refundable_until(group),
         revision: group.revision
       })}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- req_refund_method(operation) do
      group = ensure_allocations!(group)
      refundable? = refundable?(group, occurred_on)

      cond do
        refund_method == "hotel_credit" and not refundable? ->
          {:error, rejected(operation, "refund_method_not_available")}

        true ->
          room_ids = Enum.map(active_rooms(group), & &1.room_id)

          {group, refunded, retained, _converted, credit_issued} =
            settle_rooms(group, room_ids, occurred_on, refund_method, refundable?, operation)

          {:ok,
           applied(operation, %{
             group_id: group.group_id,
             refunded_cents: refunded,
             retained_cents: retained,
             credit_issued_cents: credit_issued,
             revision: group.revision
           })}
      end
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- req_refund_method(operation),
         {:ok, room_ids} <- req_room_ids(operation),
         :ok <- validate_cancellable_rooms(group, room_ids) do
      group = ensure_allocations!(group)
      refundable? = refundable?(group, occurred_on)

      cond do
        refund_method == "hotel_credit" and not refundable? ->
          {:error, rejected(operation, "refund_method_not_available")}

        true ->
          ordered_ids = rooms_in_original_order(group, room_ids)

          {group, refunded, retained, _converted, credit_issued} =
            settle_rooms(group, ordered_ids, occurred_on, refund_method, refundable?, operation)

          {:ok,
           applied(operation, %{
             group_id: group.group_id,
             cancelled_room_ids: ordered_ids,
             refunded_cents: refunded,
             retained_cents: retained,
             credit_issued_cents: credit_issued,
             revision: group.revision
           })}
      end
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment_id} <- req_id(operation, "payment_operation_id"),
         {:ok, record} <- fetch_operation_record(operation, payment_id),
         {:ok, group} <- reducible_group(operation, record),
         :ok <- match_revision(operation, group),
         {:ok, amount} <- req_payment_amount(operation) do
      held = held_cash_for_payment(payment_id)

      cond do
        held == 0 ->
          {:error, rejected(operation, "payment_not_reducible")}

        amount > held ->
          {:error, rejected(operation, "reduction_exceeds_held_cash")}

        true ->
          affected = reduce_held_cash!(payment_id, amount)
          group = persist_groups_after_correction!(group, affected)

          {:ok,
           applied(operation, %{
             payment_operation_id: payment_id,
             group_id: group.group_id,
             amount_cents: amount,
             outstanding_deposit_cents: outstanding(group),
             revision: group.revision
           })}
      end
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment_id} <- req_id(operation, "payment_operation_id"),
         {:ok, record} <- fetch_operation_record(operation, payment_id),
         {:ok, group} <- chargeable_group(operation, record),
         :ok <- match_revision(operation, group) do
      cond do
        already_charged_back?(payment_id) or chargeable_cents(payment_id) == 0 ->
          {:error, rejected(operation, "payment_not_chargeable")}

        true ->
          extras = settlement_extras_by_group(payment_id)
          charged = charge_back!(payment_id)
          group = persist_groups_after_correction!(group, Map.keys(extras), extras)

          {:ok,
           applied(operation, %{
             payment_operation_id: payment_id,
             group_id: group.group_id,
             charged_back_cents: charged,
             outstanding_deposit_cents: outstanding(group),
             revision: group.revision
           })}
      end
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source_id} <- req_id(operation, "source_group_id"),
         {:ok, dest_id} <- req_id(operation, "destination_group_id"),
         {:ok, source} <- fetch_group_named(operation, source_id),
         {:ok, dest} <- fetch_group_named(operation, dest_id),
         :ok <- match_revision(operation, source),
         :ok <- match_revision_key(operation, dest, "destination_expected_revision"),
         :ok <- validate_transfer_pair(operation, source, dest),
         :ok <- require_active_named(operation, source),
         :ok <- require_active_named(operation, dest),
         {:ok, amount} <- req_payment_amount(operation) do
      source = ensure_allocations!(source)
      dest = ensure_allocations!(dest)
      held = held_funding_total(source)
      dest_outstanding = outstanding(dest)

      cond do
        amount > held ->
          {:error, rejected(operation, "transfer_exceeds_held_funding")}

        amount > dest_outstanding ->
          {:error, rejected(operation, "transfer_exceeds_outstanding")}

        true ->
          transfer_funding!(source, dest, amount)
          {:ok, source} = persist_group_change(source, active_money_from_group(source))
          {:ok, dest} = persist_group_change(dest, active_money_from_group(dest))

          {:ok,
           applied(operation, %{
             source_group_id: source.group_id,
             destination_group_id: dest.group_id,
             amount_cents: amount,
             source_outstanding_deposit_cents: outstanding(source),
             destination_outstanding_deposit_cents: outstanding(dest),
             source_revision: source.revision,
             destination_revision: dest.revision
           })}
      end
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

      rooms =
        Enum.map(rooms, fn room ->
          lodging = nights * room.nightly_rate_cents

          Map.merge(room, %{
            status: "active",
            deposit_due_cents: room_deposit(lodging, rate_plan)
          })
        end)

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
         policy_version: implied_policy(rate_plan, occurred_on),
         rooms: rooms,
         lodging_total_cents: lodging,
         deposit_due_cents: deposit,
         deposit_paid_cents: 0,
         cash_paid_cents: 0,
         credit_paid_cents: 0,
         refunded_cents: 0,
         retained_cents: 0,
         cash_converted_to_credit_cents: 0,
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
      deposit = Map.get(room, :deposit_due_cents) || room_deposit(lodging, rate_plan)
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

  defp policy_version(%Group{policy_version: version} = group)
       when version not in ["flex-14", "flex-30", "advance-nonrefundable"] do
    implied_policy(group.rate_plan, group.booked_on)
  end

  defp policy_version(%Group{policy_version: version}), do: version

  defp implied_policy("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp implied_policy("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp implied_policy(_rate_plan, _booked_on), do: "advance-nonrefundable"

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      _ -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end

  defp settle_rooms(group, room_ids, occurred_on, refund_method, refundable?, operation) do
    cash_allocs =
      from(a in CashAllocation,
        where: a.group_id == ^group.group_id and a.room_id in ^room_ids and a.status == "held"
      )
      |> Repo.all()

    credit_apps =
      from(a in CreditApplication,
        where: a.group_id == ^group.group_id and a.room_id in ^room_ids and a.status == "held",
        preload: [:credit_lot]
      )
      |> Repo.all()

    cash = Enum.reduce(cash_allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)

    {refunded, retained, converted, credit_issued} =
      cond do
        refundable? and refund_method == "hotel_credit" ->
          restore_applications(credit_apps, occurred_on)

          issued =
            issue_converted_credit(
              group,
              cash_allocs,
              cash,
              occurred_on,
              operation["operation_id"]
            )

          mark_cash(cash_allocs, "converted")
          {0, 0, cash, issued}

        refundable? ->
          restore_applications(credit_apps, occurred_on)
          mark_cash(cash_allocs, "refunded")
          {cash, 0, 0, 0}

        true ->
          consume_applications(credit_apps)
          mark_cash(cash_allocs, "retained")
          {0, cash, 0, 0}
      end

    selected = MapSet.new(room_ids)

    rooms =
      Enum.map(group.rooms, fn room ->
        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status:
            if(MapSet.member?(selected, room.room_id),
              do: "cancelled",
              else: room_status(room, group)
            ),
          deposit_due_cents: room_deposit_due(room, group)
        }
      end)

    group_status =
      if Enum.any?(rooms, &(&1.status == "active")), do: group.status, else: "cancelled"

    money = active_money(group.group_id, rooms, group)

    {:ok, group} =
      persist_group_change(
        group,
        Map.merge(money, %{
          status: group_status,
          refunded_cents: group.refunded_cents + refunded,
          retained_cents: group.retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
        }),
        rooms
      )

    {group, refunded, retained, converted, credit_issued}
  end

  defp issue_converted_credit(_group, _allocs, cash_cents, _occurred_on, _operation_id)
       when cash_cents <= 0 do
    0
  end

  defp issue_converted_credit(group, cash_allocs, cash_cents, occurred_on, operation_id) do
    issued = credit_value(cash_cents)

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id || "",
        issued_cents: issued,
        remaining_cents: issued,
        unrecovered_clawback_cents: 0,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()

    persist_entitlements!(lot, funding_sources(cash_allocs))
    issued
  end

  defp persist_entitlements!(lot, sources) do
    sources
    |> telescoping_entitlements()
    |> Enum.each(fn {source, cents} ->
      %CreditLotEntitlement{}
      |> CreditLotEntitlement.changeset(%{
        credit_lot_id: lot.id,
        source_operation_id: source,
        entitlement_cents: cents,
        revoked_cents: 0
      })
      |> Repo.insert!()
    end)
  end

  defp telescoping_entitlements(sources) do
    {rows, _} =
      Enum.map_reduce(sources, 0, fn {source, cash}, prev ->
        new_total = prev + cash
        {{source, credit_value(new_total) - credit_value(prev)}, new_total}
      end)

    rows
  end

  defp credit_value(cash_cents), do: cash_cents + round_percent(cash_cents, 10)

  defp funding_sources(cash_allocs) do
    grouped =
      cash_allocs
      |> Enum.group_by(& &1.source_operation_id)
      |> Enum.map(fn {source, allocs} ->
        {source, Enum.reduce(allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)}
      end)

    {legacy, durable} = Enum.split_with(grouped, fn {source, _} -> is_nil(source) end)

    durable_ordered =
      Enum.sort_by(durable, fn {source, _} ->
        case fetch_operation(source) do
          %Operation{id: id} -> id
          _ -> 9_999_999_999
        end
      end)

    legacy ++ durable_ordered
  end

  defp consume_credit(group, amount, occurred_on, source_id) do
    lots =
      from(l in CreditLot,
        where:
          l.guest_id == ^group.guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred_on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

    available = Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end)

    if available < amount do
      {:error, "insufficient_credit"}
    else
      lot_chunks = take_from_lots(lots, amount)
      room_chunks = plan_room_fill(group, amount)
      seq = next_fill_seq(group.group_id)

      merge_lot_room_chunks(lot_chunks, room_chunks)
      |> Enum.reduce(seq, fn {lot, room_id, take}, seq ->
        %CreditApplication{}
        |> CreditApplication.changeset(%{
          group_id: group.group_id,
          room_id: room_id,
          source_operation_id: source_id,
          credit_lot_id: lot.id,
          amount_cents: take,
          status: "held",
          fill_seq: seq
        })
        |> Repo.insert!()

        seq + 1
      end)

      :ok
    end
  end

  defp take_from_lots(lots, amount) do
    {chunks, _} =
      Enum.flat_map_reduce(lots, amount, fn lot, left ->
        cond do
          left <= 0 ->
            {[], 0}

          true ->
            take = min(lot.remaining_cents, left)

            lot
            |> change(%{remaining_cents: lot.remaining_cents - take})
            |> Repo.update!()

            {[{lot, take}], left - take}
        end
      end)

    chunks
  end

  defp plan_room_fill(group, amount) do
    occupied = held_occupancy(group.group_id)

    {chunks, _} =
      Enum.flat_map_reduce(active_rooms(group), amount, fn room, left ->
        cond do
          left <= 0 ->
            {[], 0}

          true ->
            capacity = max(room_deposit_due(room, group) - Map.get(occupied, room.room_id, 0), 0)
            take = min(capacity, left)

            if take > 0 do
              {[{room.room_id, take}], left - take}
            else
              {[], left}
            end
        end
      end)

    chunks
  end

  defp merge_lot_room_chunks(lot_chunks, room_chunks) do
    do_merge_chunks(lot_chunks, room_chunks, [])
  end

  defp do_merge_chunks([], [], acc), do: Enum.reverse(acc)
  defp do_merge_chunks([], _rooms, acc), do: Enum.reverse(acc)
  defp do_merge_chunks(_lots, [], acc), do: Enum.reverse(acc)

  defp do_merge_chunks([{lot, lot_amt} | lot_rest], [{room_id, room_amt} | room_rest], acc) do
    take = min(lot_amt, room_amt)
    acc = [{lot, room_id, take} | acc]

    lot_next =
      if lot_amt > take, do: [{lot, lot_amt - take} | lot_rest], else: lot_rest

    room_next =
      if room_amt > take, do: [{room_id, room_amt - take} | room_rest], else: room_rest

    do_merge_chunks(lot_next, room_next, acc)
  end

  defp restore_applications(applications, occurred_on) do
    Enum.each(applications, fn application ->
      lot = application.credit_lot || Repo.get!(CreditLot, application.credit_lot_id)
      amount = application.amount_cents
      unrecovered = lot.unrecovered_clawback_cents || 0
      absorb = min(amount, unrecovered)
      leftover = amount - absorb

      lot_changes = %{unrecovered_clawback_cents: unrecovered - absorb}

      {lot_changes, app_status} =
        cond do
          leftover <= 0 ->
            {lot_changes, "restored"}

          Date.compare(lot.expires_on, occurred_on) != :lt ->
            {Map.put(lot_changes, :remaining_cents, lot.remaining_cents + leftover), "restored"}

          true ->
            {lot_changes, "expired"}
        end

      lot
      |> change(lot_changes)
      |> Repo.update!()

      application
      |> change(%{status: app_status})
      |> Repo.update!()
    end)
  end

  defp consume_applications(applications) do
    Enum.each(applications, fn application ->
      application
      |> change(%{status: "consumed"})
      |> Repo.update!()
    end)
  end

  defp credit_liability_cents(as_of) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    held =
      Repo.one(
        from a in CreditApplication,
          join: g in Group,
          on: g.group_id == a.group_id,
          where: a.status == "held" and g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + held
  end

  defp credit_shortfall_cents do
    from(l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, acc ->
      held =
        Repo.one(
          from a in CreditApplication,
            join: g in Group,
            on: g.group_id == a.group_id,
            where: a.credit_lot_id == ^lot.id and a.status == "held" and g.status == "active",
            select: coalesce(sum(a.amount_cents), 0)
        )

      acc + min(lot.unrecovered_clawback_cents, held)
    end)
  end

  defp allocate_cash!(group, amount, source_id) do
    occupied = held_occupancy(group.group_id)
    seq = next_fill_seq(group.group_id)

    Enum.reduce(active_rooms(group), {amount, seq}, fn room, {left, seq} ->
      if left <= 0 do
        {0, seq}
      else
        capacity = max(room_deposit_due(room, group) - Map.get(occupied, room.room_id, 0), 0)
        take = min(capacity, left)

        if take > 0 do
          insert_cash_allocation!(%{
            group_id: group.group_id,
            room_id: room.room_id,
            source_operation_id: source_id,
            amount_cents: take,
            status: "held",
            fill_seq: seq
          })

          {left - take, seq + 1}
        else
          {left, seq}
        end
      end
    end)
  end

  defp insert_cash_allocation!(attrs) do
    %CashAllocation{}
    |> CashAllocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp reduce_held_cash!(payment_id, amount) do
    allocs =
      from(a in CashAllocation,
        where: a.source_operation_id == ^payment_id and a.status == "held",
        order_by: [desc: a.fill_seq, desc: a.inserted_at, desc: a.id]
      )
      |> Repo.all()

    {_, affected} =
      Enum.reduce_while(allocs, {amount, MapSet.new()}, fn alloc, {left, affected} ->
        cond do
          left <= 0 ->
            {:halt, {0, affected}}

          alloc.amount_cents <= left ->
            alloc
            |> change(%{status: "reduced"})
            |> Repo.update!()

            {:cont, {left - alloc.amount_cents, MapSet.put(affected, alloc.group_id)}}

          true ->
            alloc
            |> change(%{amount_cents: alloc.amount_cents - left})
            |> Repo.update!()

            insert_cash_allocation!(%{
              group_id: alloc.group_id,
              room_id: alloc.room_id,
              source_operation_id: payment_id,
              amount_cents: left,
              status: "reduced",
              fill_seq: alloc.fill_seq
            })

            {:halt, {0, MapSet.put(affected, alloc.group_id)}}
        end
      end)

    affected
  end

  defp charge_back!(payment_id) do
    allocs =
      from(a in CashAllocation,
        where: a.source_operation_id == ^payment_id and a.status != "reduced",
        order_by: [desc: a.fill_seq, desc: a.inserted_at, desc: a.id]
      )
      |> Repo.all()

    charged = Enum.reduce(allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)
    mark_cash(allocs, "charged_back")
    revoke_credit_entitlement!(payment_id)
    charged
  end

  defp revoke_credit_entitlement!(payment_id) do
    from(e in CreditLotEntitlement,
      where: e.source_operation_id == ^payment_id,
      preload: [:credit_lot]
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      to_revoke = entitlement.entitlement_cents - entitlement.revoked_cents

      if to_revoke > 0 do
        lot = entitlement.credit_lot
        from_remaining = min(lot.remaining_cents, to_revoke)

        lot
        |> change(%{
          remaining_cents: lot.remaining_cents - from_remaining,
          unrecovered_clawback_cents:
            (lot.unrecovered_clawback_cents || 0) + (to_revoke - from_remaining)
        })
        |> Repo.update!()

        entitlement
        |> change(%{revoked_cents: entitlement.entitlement_cents})
        |> Repo.update!()
      end
    end)
  end

  defp apply_settlement_snapshot(group, snapshot) do
    %{
      refunded_cents: max(group.refunded_cents - Map.get(snapshot, "refunded", 0), 0),
      retained_cents: max(group.retained_cents - Map.get(snapshot, "retained", 0), 0),
      cash_converted_to_credit_cents:
        max(group.cash_converted_to_credit_cents - Map.get(snapshot, "converted", 0), 0)
    }
  end

  defp mark_cash(allocs, status) do
    Enum.each(allocs, fn alloc ->
      alloc
      |> change(%{status: status})
      |> Repo.update!()
    end)
  end

  defp already_charged_back?(payment_id) do
    Repo.exists?(
      from a in CashAllocation,
        where: a.source_operation_id == ^payment_id and a.status == "charged_back"
    )
  end

  defp chargeable_cents(payment_id) do
    Repo.one(
      from a in CashAllocation,
        where:
          a.source_operation_id == ^payment_id and
            a.status in ["held", "refunded", "retained", "converted"],
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp held_cash_for_payment(payment_id) do
    Repo.one(
      from a in CashAllocation,
        where: a.source_operation_id == ^payment_id and a.status == "held",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp payment_statement(record) do
    totals =
      from(a in CashAllocation,
        where: a.source_operation_id == ^record.operation_id,
        group_by: a.status,
        select: {a.status, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    statement = %{
      payment_operation_id: record.operation_id,
      original_group_id: result_group_id(record.result),
      recorded_cents: result_amount(record),
      held_cents: Map.get(totals, "held", 0),
      refunded_cents: Map.get(totals, "refunded", 0),
      retained_cents: Map.get(totals, "retained", 0),
      converted_to_credit_cents: Map.get(totals, "converted", 0),
      reduced_cents: Map.get(totals, "reduced", 0),
      charged_back_cents: Map.get(totals, "charged_back", 0)
    }

    if payment_transfer_participated?(record.operation_id) do
      Map.put(statement, :held_by_group, held_by_group(record.operation_id))
    else
      statement
    end
  end

  defp reducible_group(operation, record) do
    if applied_cash_payment?(record) do
      case result_group_id(record.result) do
        group_id when is_binary(group_id) ->
          case fetch_group(operation, group_id) do
            {:ok, group} -> {:ok, ensure_allocations!(group)}
            error -> error
          end

        _ ->
          {:error, rejected(operation, "payment_not_reducible")}
      end
    else
      {:error, rejected(operation, "payment_not_reducible")}
    end
  end

  defp chargeable_group(operation, record) do
    if applied_cash_payment?(record) do
      case result_group_id(record.result) do
        group_id when is_binary(group_id) ->
          case fetch_group(operation, group_id) do
            {:ok, group} -> {:ok, ensure_allocations!(group)}
            error -> error
          end

        _ ->
          {:error, rejected(operation, "payment_not_chargeable")}
      end
    else
      {:error, rejected(operation, "payment_not_chargeable")}
    end
  end

  defp fetch_operation_record(operation, payment_id) do
    case fetch_operation(payment_id) do
      nil -> {:error, rejected(operation, "operation_not_found")}
      record -> {:ok, record}
    end
  end

  defp applied_cash_payment?(%Operation{type: "record_cash_payment", result: result}) do
    applied_result?(result)
  end

  defp applied_cash_payment?(_), do: false

  defp applied_result?(result) when is_map(result) do
    result["status"] == "applied" or result[:status] == "applied"
  end

  defp applied_result?(_), do: false

  defp result_group_id(result) when is_map(result) do
    result["group_id"] || result[:group_id]
  end

  defp result_group_id(_), do: nil

  defp result_amount(%Operation{result: result}), do: result_amount(result)

  defp result_amount(result) when is_map(result) do
    result["amount_cents"] || result[:amount_cents] || 0
  end

  defp result_amount(_), do: 0

  defp ensure_allocations!(%Group{} = group) do
    group = persist_room_metadata!(group)
    if needs_cash_hydrate?(group), do: hydrate_cash!(group)
    if needs_credit_hydrate?(group), do: hydrate_credit!(group)
    Repo.get_by(Group, group_id: group.group_id) || group
  end

  defp recorded_cash(%Group{status: "cancelled"} = group) do
    settled =
      group.refunded_cents + group.retained_cents + group.cash_converted_to_credit_cents

    if settled > 0, do: settled, else: group.cash_paid_cents
  end

  defp recorded_cash(group), do: group.cash_paid_cents

  defp persist_room_metadata!(group) do
    updated =
      Enum.map(group.rooms, fn room ->
        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: room_status(room, group),
          deposit_due_cents: room_deposit_due(room, group)
        }
      end)

    needs? =
      Enum.zip(group.rooms, updated)
      |> Enum.any?(fn {room, upd} ->
        room.status != upd.status or room.deposit_due_cents != upd.deposit_due_cents
      end)

    if needs? do
      {:ok, group} =
        group
        |> change(%{})
        |> put_embed(:rooms, updated)
        |> Repo.update()

      group
    else
      group
    end
  end

  defp needs_cash_hydrate?(group) do
    recorded_cash(group) > 0 and
      not Repo.exists?(from a in CashAllocation, where: a.group_id == ^group.group_id)
  end

  defp needs_credit_hydrate?(group) do
    Repo.exists?(
      from a in CreditApplication,
        where: a.group_id == ^group.group_id and is_nil(a.room_id)
    )
  end

  defp hydrate_cash!(group) do
    durable = durable_funding_ops(group.group_id, "record_cash_payment")
    durable_total = Enum.reduce(durable, 0, fn op, acc -> acc + result_amount(op) end)

    recorded = recorded_cash(group)
    legacy_cash = max(recorded - durable_total, 0)
    rooms = rooms_for_fill(group)
    seq = next_fill_seq(group.group_id)
    {seq, rooms} = insert_cash_fill(group.group_id, rooms, legacy_cash, nil, seq)

    Enum.reduce(durable, {seq, rooms}, fn op, {seq, rooms} ->
      insert_cash_fill(group.group_id, rooms, result_amount(op), op.operation_id, seq)
    end)

    if group.status == "cancelled" do
      reclassify_hydrated_cash!(group)
      maybe_hydrate_entitlements!(group)
    end
  end

  defp rooms_for_fill(group) do
    Enum.map(group.rooms, fn room ->
      {room.room_id, room_deposit_due(room, group), 0}
    end)
  end

  defp insert_cash_fill(_group_id, rooms, amount, _source_id, seq) when amount <= 0 do
    {seq, rooms}
  end

  defp insert_cash_fill(group_id, rooms, amount, source_id, seq) do
    {updated, {left, seq}} =
      Enum.map_reduce(rooms, {amount, seq}, fn {room_id, due, filled}, {left, seq} ->
        take = min(max(due - filled, 0), left)

        if take > 0 do
          insert_cash_allocation!(%{
            group_id: group_id,
            room_id: room_id,
            source_operation_id: source_id,
            amount_cents: take,
            status: "held",
            fill_seq: seq
          })

          {{room_id, due, filled + take}, {left - take, seq + 1}}
        else
          {{room_id, due, filled}, {left, seq}}
        end
      end)

    if left > 0 and updated != [] do
      {room_id, due, filled} = List.last(updated)

      insert_cash_allocation!(%{
        group_id: group_id,
        room_id: room_id,
        source_operation_id: source_id,
        amount_cents: left,
        status: "held",
        fill_seq: seq
      })

      {seq + 1, List.replace_at(updated, -1, {room_id, due, filled + left})}
    else
      {seq, updated}
    end
  end

  defp reclassify_hydrated_cash!(group) do
    status =
      cond do
        group.cash_converted_to_credit_cents > 0 -> "converted"
        group.refunded_cents > 0 -> "refunded"
        group.retained_cents > 0 -> "retained"
        true -> nil
      end

    if status do
      from(a in CashAllocation, where: a.group_id == ^group.group_id and a.status == "held")
      |> Repo.update_all(set: [status: status])
    end
  end

  defp maybe_hydrate_entitlements!(group) do
    if group.cash_converted_to_credit_cents > 0 do
      lot = find_conversion_lot(group)

      if lot && not has_entitlements?(lot) do
        allocs =
          from(a in CashAllocation,
            where: a.group_id == ^group.group_id and a.status == "converted"
          )
          |> Repo.all()

        persist_entitlements!(lot, funding_sources(allocs))
      end
    end
  end

  defp find_conversion_lot(group) do
    cancel_ids =
      durable_ops_for_group(group.group_id, ["cancel_group", "cancel_rooms"])
      |> Enum.map(& &1.operation_id)

    cond do
      cancel_ids != [] ->
        from(l in CreditLot,
          where: l.guest_id == ^group.guest_id and l.source_operation_id in ^cancel_ids,
          order_by: [asc: l.inserted_at]
        )
        |> Repo.one()

      true ->
        from(l in CreditLot,
          where: l.guest_id == ^group.guest_id,
          order_by: [asc: l.inserted_at],
          limit: 1
        )
        |> Repo.one()
    end
  end

  defp has_entitlements?(lot) do
    Repo.exists?(from e in CreditLotEntitlement, where: e.credit_lot_id == ^lot.id)
  end

  defp hydrate_credit!(group) do
    apps =
      from(a in CreditApplication,
        where: a.group_id == ^group.group_id and is_nil(a.room_id),
        order_by: [asc: a.id]
      )
      |> Repo.all()

    if apps != [] do
      durable = durable_funding_ops(group.group_id, "apply_hotel_credit")
      durable_total = Enum.reduce(durable, 0, fn op, acc -> acc + result_amount(op) end)
      total = Enum.reduce(apps, 0, fn app, acc -> acc + app.amount_cents end)
      legacy_amount = max(total - durable_total, 0)
      chunks = split_apps_into_source_chunks(apps, legacy_amount, durable)
      occupied = cash_occupancy_all(group.group_id)
      rooms = rooms_with_occupied(group, occupied)
      seq = next_fill_seq(group.group_id)
      insert_credit_chunks!(group.group_id, rooms, chunks, seq)
      Enum.each(apps, &Repo.delete!/1)
    end
  end

  defp split_apps_into_source_chunks(apps, legacy_amount, durable_ops) do
    queue =
      Enum.map(apps, fn app ->
        {app.credit_lot_id, app.amount_cents, app.status}
      end)

    {legacy_chunks, rest} = take_source_amount(queue, legacy_amount, nil)

    {durable_chunks, leftover} =
      Enum.map_reduce(durable_ops, rest, fn op, rest ->
        take_source_amount(rest, result_amount(op), op.operation_id)
      end)

    leftover_chunks =
      Enum.map(leftover, fn {lot_id, amount, status} ->
        {lot_id, amount, status, nil}
      end)

    List.flatten(legacy_chunks) ++ List.flatten(durable_chunks) ++ leftover_chunks
  end

  defp take_source_amount(queue, 0, _source), do: {[], queue}
  defp take_source_amount([], _amount, _source), do: {[], []}

  defp take_source_amount([{lot_id, amount, status} | rest], needed, source) do
    take = min(amount, needed)
    chunk = {lot_id, take, status, source}

    if take == amount do
      {more, rest} = take_source_amount(rest, needed - take, source)
      {[chunk | more], rest}
    else
      {more, rest} = take_source_amount([{lot_id, amount - take, status} | rest], 0, source)
      {[chunk | more], rest}
    end
  end

  defp insert_credit_chunks!(group_id, rooms, chunks, seq) do
    Enum.reduce(chunks, {rooms, seq}, fn {lot_id, amount, status, source_id}, {rooms, seq} ->
      fill_credit_chunk(group_id, rooms, lot_id, amount, status, source_id, seq)
    end)
  end

  defp fill_credit_chunk(_group_id, rooms, _lot_id, amount, _status, _source_id, seq)
       when amount <= 0 do
    {rooms, seq}
  end

  defp fill_credit_chunk(group_id, rooms, lot_id, amount, status, source_id, seq) do
    {updated, {left, seq}} =
      Enum.map_reduce(rooms, {amount, seq}, fn {room_id, due, filled}, {left, seq} ->
        take = min(max(due - filled, 0), left)

        if take > 0 do
          %CreditApplication{}
          |> CreditApplication.changeset(%{
            group_id: group_id,
            room_id: room_id,
            source_operation_id: source_id,
            credit_lot_id: lot_id,
            amount_cents: take,
            status: status,
            fill_seq: seq
          })
          |> Repo.insert!()

          {{room_id, due, filled + take}, {left - take, seq + 1}}
        else
          {{room_id, due, filled}, {left, seq}}
        end
      end)

    if left > 0 and updated != [] do
      {room_id, due, filled} = List.last(updated)

      %CreditApplication{}
      |> CreditApplication.changeset(%{
        group_id: group_id,
        room_id: room_id,
        source_operation_id: source_id,
        credit_lot_id: lot_id,
        amount_cents: left,
        status: status,
        fill_seq: seq
      })
      |> Repo.insert!()

      {List.replace_at(updated, -1, {room_id, due, filled + left}), seq + 1}
    else
      {updated, seq}
    end
  end

  defp rooms_with_occupied(group, occupied) do
    Enum.map(group.rooms, fn room ->
      {room.room_id, room_deposit_due(room, group), Map.get(occupied, room.room_id, 0)}
    end)
  end

  defp cash_occupancy_all(group_id) do
    from(a in CashAllocation,
      where: a.group_id == ^group_id and a.status != "reduced" and a.status != "charged_back",
      group_by: a.room_id,
      select: {a.room_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp durable_funding_ops(group_id, type) do
    durable_ops_for_group(group_id, [type])
  end

  defp durable_ops_for_group(group_id, types) do
    from(o in Operation,
      where: o.type in ^types,
      order_by: [asc: o.id]
    )
    |> Repo.all()
    |> Enum.filter(fn op ->
      applied_result?(op.result) and result_group_id(op.result) == group_id
    end)
  end

  defp next_fill_seq(_group_id) do
    cash = Repo.one(from a in CashAllocation, select: max(a.fill_seq)) || 0

    credit = Repo.one(from a in CreditApplication, select: max(a.fill_seq)) || 0

    max(cash, credit) + 1
  end

  defp held_occupancy(group_id) do
    Map.merge(held_cash_by_room(group_id), held_credit_by_room(group_id), fn _k, c, d ->
      c + d
    end)
  end

  defp held_cash_by_room(group_id) do
    from(a in CashAllocation,
      where: a.group_id == ^group_id and a.status == "held",
      group_by: a.room_id,
      select: {a.room_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp held_credit_by_room(group_id) do
    from(a in CreditApplication,
      where: a.group_id == ^group_id and a.status == "held",
      group_by: a.room_id,
      select: {a.room_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp held_totals(group_id, room_ids) do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.group_id == ^group_id and a.room_id in ^room_ids and a.status == "held",
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditApplication,
          where: a.group_id == ^group_id and a.room_id in ^room_ids and a.status == "held",
          select: coalesce(sum(a.amount_cents), 0)
      )

    {cash, credit}
  end

  defp active_money_from_group(group) do
    rooms =
      Enum.map(group.rooms, fn room ->
        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: room_status(room, group),
          deposit_due_cents: room_deposit_due(room, group)
        }
      end)

    active_money(group.group_id, rooms, group)
  end

  defp active_money(group_id, rooms, group) do
    active = Enum.filter(rooms, &(&1.status == "active"))
    active_ids = Enum.map(active, & &1.room_id)
    {cash, credit} = held_totals(group_id, active_ids)

    due =
      Enum.reduce(active, 0, fn room, acc ->
        acc + (room.deposit_due_cents || 0)
      end)

    %{
      lodging_total_cents: active_lodging_from(group, rooms),
      deposit_due_cents: due,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }
  end

  defp active_lodging(group) do
    active_lodging_from(group, group.rooms)
  end

  defp active_lodging_from(group, rooms) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    rooms
    |> Enum.filter(&(room_status_value(&1, group) == "active"))
    |> Enum.reduce(0, fn room, acc -> acc + nights * room.nightly_rate_cents end)
  end

  defp room_status_value(%{status: status}, group), do: room_status(%{status: status}, group)
  defp room_status_value(room, group) when is_map(room), do: room_status(room, group)

  defp active_rooms(group) do
    Enum.filter(group.rooms, &(room_status(&1, group) == "active"))
  end

  defp room_status(%{status: status}, _group) when status in ["active", "cancelled"], do: status
  defp room_status(_room, %Group{status: "cancelled"}), do: "cancelled"
  defp room_status(_room, _), do: "active"

  defp room_deposit_due(%{deposit_due_cents: cents}, _group) when is_integer(cents), do: cents

  defp room_deposit_due(room, group) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    room_deposit(nights * room.nightly_rate_cents, group.rate_plan)
  end

  defp rooms_in_original_order(group, room_ids) do
    selected = MapSet.new(room_ids)

    group.rooms
    |> Enum.filter(&MapSet.member?(selected, &1.room_id))
    |> Enum.map(& &1.room_id)
  end

  defp persist_group_change(group, attrs, rooms \\ nil) do
    changeset =
      group
      |> change(attrs)
      |> force_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> optimistic_lock(:revision)

    changeset = if rooms, do: put_embed(changeset, :rooms, rooms), else: changeset
    Repo.update(changeset)
  end

  defp fetch_group(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, rejected(operation, "group_not_found")}
    end
  end

  defp fetch_group_named(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{} = group ->
        {:ok, group}

      nil ->
        {:error, Map.put(rejected(operation, "group_not_found"), :group_id, group_id)}
    end
  end

  defp validate_transfer_pair(operation, source, dest) do
    if source.group_id == dest.group_id or source.guest_id != dest.guest_id do
      {:error, rejected(operation, "invalid_transfer")}
    else
      :ok
    end
  end

  defp require_active_named(_operation, %Group{status: "active"}), do: :ok

  defp require_active_named(operation, group) do
    {:error, Map.put(rejected(operation, "group_not_active"), :group_id, group.group_id)}
  end

  defp held_funding_total(group) do
    room_ids = Enum.map(active_rooms(group), & &1.room_id)
    {cash, credit} = held_totals(group.group_id, room_ids)
    cash + credit
  end

  defp transfer_funding!(source, dest, amount) do
    pieces = extract_held_units!(source, amount)
    slots = plan_room_fill(dest, amount)

    merge_drawn_rooms(pieces, slots)
    |> Enum.each(fn {kind, rec, room_id, take} ->
      place_funding!(kind, rec, dest.group_id, room_id, take)
    end)
  end

  defp extract_held_units!(source, amount) do
    {pieces, _} =
      Enum.flat_map_reduce(held_funding_units(source), amount, fn {kind, rec}, left ->
        cond do
          left <= 0 ->
            {[], 0}

          true ->
            take = min(rec.amount_cents, left)
            extract_unit!(rec, take)
            {[{kind, rec, take}], left - take}
        end
      end)

    pieces
  end

  defp held_funding_units(group) do
    room_ids = Enum.map(active_rooms(group), & &1.room_id)

    cash =
      from(a in CashAllocation,
        where: a.group_id == ^group.group_id and a.room_id in ^room_ids and a.status == "held"
      )
      |> Repo.all()
      |> Enum.map(&{:cash, &1})

    credit =
      from(a in CreditApplication,
        where: a.group_id == ^group.group_id and a.room_id in ^room_ids and a.status == "held"
      )
      |> Repo.all()
      |> Enum.map(&{:credit, &1})

    (cash ++ credit)
    |> Enum.sort_by(
      fn {_kind, rec} ->
        {rec.fill_seq || 0, rec.inserted_at || ~U[1970-01-01 00:00:00Z], rec.id || ""}
      end,
      :desc
    )
  end

  defp extract_unit!(rec, take) do
    if take >= rec.amount_cents do
      Repo.delete!(rec)
    else
      rec
      |> change(%{amount_cents: rec.amount_cents - take})
      |> Repo.update!()
    end
  end

  defp merge_drawn_rooms(drawn, rooms) do
    do_merge_drawn(drawn, rooms, [])
  end

  defp do_merge_drawn([], _rooms, acc), do: Enum.reverse(acc)
  defp do_merge_drawn(_drawn, [], acc), do: Enum.reverse(acc)

  defp do_merge_drawn([{kind, rec, amt} | drawn_rest], [{room_id, room_amt} | room_rest], acc) do
    take = min(amt, room_amt)
    acc = [{kind, rec, room_id, take} | acc]

    drawn_next =
      if amt > take, do: [{kind, rec, amt - take} | drawn_rest], else: drawn_rest

    room_next =
      if room_amt > take, do: [{room_id, room_amt - take} | room_rest], else: room_rest

    do_merge_drawn(drawn_next, room_next, acc)
  end

  defp place_funding!(:cash, rec, dest_group_id, room_id, take) do
    insert_cash_allocation!(%{
      group_id: dest_group_id,
      room_id: room_id,
      source_operation_id: rec.source_operation_id,
      amount_cents: take,
      status: "held",
      fill_seq: rec.fill_seq || 0
    })

    mark_payment_transferred(rec.source_operation_id)
  end

  defp place_funding!(:credit, rec, dest_group_id, room_id, take) do
    %CreditApplication{}
    |> CreditApplication.changeset(%{
      group_id: dest_group_id,
      room_id: room_id,
      source_operation_id: rec.source_operation_id,
      credit_lot_id: rec.credit_lot_id,
      amount_cents: take,
      status: "held",
      fill_seq: rec.fill_seq || 0
    })
    |> Repo.insert!()
  end

  defp mark_payment_transferred(nil), do: :ok

  defp mark_payment_transferred(payment_id) do
    %PaymentTransferFlag{}
    |> PaymentTransferFlag.changeset(%{payment_operation_id: payment_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :payment_operation_id)
  end

  defp payment_transfer_participated?(payment_id) do
    Repo.exists?(from f in PaymentTransferFlag, where: f.payment_operation_id == ^payment_id)
  end

  defp held_by_group(payment_id) do
    from(a in CashAllocation,
      where: a.source_operation_id == ^payment_id and a.status == "held",
      group_by: a.group_id,
      select: {a.group_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Enum.reject(fn {_group_id, amount} -> amount == 0 end)
    |> Enum.sort_by(fn {group_id, _amount} -> group_id end)
    |> Enum.map(fn {group_id, amount} ->
      %{group_id: group_id, amount_cents: amount}
    end)
  end

  defp persist_groups_after_correction!(primary, affected_ids, extras \\ %{}) do
    ids =
      affected_ids
      |> MapSet.new()
      |> MapSet.put(primary.group_id)

    Enum.reduce(ids, primary, fn gid, acc ->
      group = if gid == primary.group_id, do: acc, else: Repo.get_by!(Group, group_id: gid)
      extra = Map.get(extras, gid, %{})

      {:ok, updated} =
        persist_group_change(group, Map.merge(active_money_from_group(group), extra))

      if gid == primary.group_id, do: updated, else: acc
    end)
  end

  defp settlement_extras_by_group(payment_id) do
    from(a in CashAllocation,
      where: a.source_operation_id == ^payment_id and a.status != "reduced",
      distinct: true,
      select: a.group_id
    )
    |> Repo.all()
    |> Map.new(fn group_id ->
      group = Repo.get_by!(Group, group_id: group_id)
      {group_id, apply_settlement_snapshot(group, settlement_snapshot_for(payment_id, group_id))}
    end)
  end

  defp settlement_snapshot_for(payment_id, group_id) do
    from(a in CashAllocation,
      where: a.source_operation_id == ^payment_id and a.group_id == ^group_id,
      group_by: a.status,
      select: {a.status, coalesce(sum(a.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp match_revision(operation, group),
    do: match_revision_key(operation, group, "expected_revision")

  defp match_revision_key(operation, group, key) do
    case Map.fetch(operation, key) do
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

  defp req_refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, nil} -> {:ok, "cash"}
      {:ok, method} when method in @refund_methods -> {:ok, method}
      {:ok, _} -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp req_room_ids(operation) do
    case operation["room_ids"] do
      ids when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
          {:ok, ids}
        else
          {:error, "invalid_rooms"}
        end

      ids when is_list(ids) ->
        {:error, "invalid_rooms"}

      _ ->
        {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp validate_cancellable_rooms(group, room_ids) do
    if room_ids != Enum.uniq(room_ids) do
      {:error, "invalid_rooms"}
    else
      active_ids =
        group
        |> active_rooms()
        |> MapSet.new(& &1.room_id)

      if Enum.all?(room_ids, &MapSet.member?(active_ids, &1)) do
        :ok
      else
        {:error, "invalid_rooms"}
      end
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

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, opts}} -> opts[:constraint] == :unique
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
