defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{
    CreditApplication,
    CreditEntitlement,
    CreditLot,
    FundingAllocation,
    Group,
    OperationRecord,
    PaymentDisposition,
    PaymentGroupDisposition,
    Repo,
    Room
  }

  @rate_plans ~w(flexible advance_purchase)
  @operation_types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit)
  @new_policy_date ~D[2027-01-01]

  def process_batch(operations) do
    Enum.map(operations, fn operation ->
      operation
      |> process_operation()
      |> Map.put_new("operation_id", operation_id(operation))
    end)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, Repo.preload(group, rooms: :funding_allocations)}
    end
  end

  def get_group(_), do: {:error, :not_found}

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record.result}
    end
  end

  def get_operation(_), do: {:error, :not_found}

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :not_found}

      %OperationRecord{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
        disposition = Repo.get_by!(PaymentDisposition, payment_operation_id: payment_operation_id)
        held = held_for_payment(payment_operation_id)

        statement = %{
          "payment_operation_id" => payment_operation_id,
          "original_group_id" => Repo.get!(Group, disposition.group_id).group_id,
          "recorded_cents" => disposition.recorded_cents,
          "held_cents" => held,
          "refunded_cents" => disposition.refunded_cents,
          "retained_cents" => disposition.retained_cents,
          "converted_to_credit_cents" => disposition.converted_cents,
          "reduced_cents" => disposition.reduced_cents,
          "charged_back_cents" => disposition.charged_back_cents
        }

        statement =
          if disposition.participated_in_transfer do
            Map.put(statement, "held_by_group", held_by_group(payment_operation_id))
          else
            statement
          end

        {:ok, statement}

      _ ->
        {:error, :not_reconcilable}
    end
  end

  def get_payment(_), do: {:error, :not_found}

  def ledger(on \\ Date.utc_today()) do
    totals =
      Repo.one(
        from g in Group,
          select: {
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.cash_paid_cents
                )
              ),
              0
            ),
            coalesce(sum(g.refunded_cents), 0),
            coalesce(sum(g.retained_cents), 0),
            coalesce(sum(g.cash_converted_to_credit_cents), 0),
            coalesce(sum(g.cash_reduced_cents), 0),
            coalesce(sum(g.cash_charged_back_cents), 0)
          }
      )

    {held, refunded, retained, converted, reduced, charged_back} = totals

    available_credit =
      Repo.one(
        from lot in CreditLot,
          where: lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied_credit =
      Repo.one(
        from application in CreditApplication,
          join: g in assoc(application, :group),
          where: g.status == "active",
          select: coalesce(sum(application.amount_cents), 0)
      )

    credit_shortfall =
      Repo.all(
        from lot in CreditLot,
          where: lot.unrecovered_clawback_cents > 0,
          select: {lot.id, lot.unrecovered_clawback_cents}
      )
      |> Enum.map(fn {lot_id, clawback} ->
        applied =
          Repo.one(
            from allocation in FundingAllocation,
              join: room in Room,
              on: room.id == allocation.room_id,
              where:
                allocation.credit_lot_id == ^lot_id and allocation.kind == "credit" and
                  room.status == "active",
              select: coalesce(sum(allocation.amount_cents), 0)
          )

        min(clawback, applied)
      end)
      |> Enum.sum()

    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "cash_reduced_cents" => reduced,
      "cash_charged_back_cents" => charged_back,
      "credit_liability_cents" => available_credit + applied_credit,
      "credit_shortfall_cents" => credit_shortfall
    }
  end

  def guest_credit(guest_id, on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.expires_on >= ^on and lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def as_of_date(nil), do: {:ok, Date.utc_today()}

  def as_of_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def serialize_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => format_date(refundable_until(group)),
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          cash = allocation_total(room, "cash")
          credit = allocation_total(room, "credit")

          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents,
            "status" => room.status,
            "lodging_total_cents" => room.lodging_total_cents,
            "deposit_due_cents" => room.deposit_due_cents,
            "cash_paid_cents" => cash,
            "credit_paid_cents" => credit
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    if nonempty_string?(operation["operation_id"]) do
      transact(operation)
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp process_operation(_), do: rejected(%{}, "invalid_operation")

  defp transact(operation) do
    case Repo.transaction(fn -> process_durable_operation(operation) end) do
      {:ok, response} -> response
      {:error, :retry} -> transact(operation)
    end
  end

  defp process_durable_operation(operation) do
    case Repo.get_by(OperationRecord, operation_id: operation["operation_id"]) do
      %OperationRecord{} = record ->
        if record.submission === operation do
          record.result
        else
          rejected(operation, "operation_id_conflict")
        end

      nil ->
        result = process_new_operation(operation)

        attrs = %{
          operation_id: operation["operation_id"],
          operation_type: submitted_type(operation),
          submission: operation,
          result: result
        }

        case %OperationRecord{} |> OperationRecord.changeset(attrs) |> Repo.insert() do
          {:ok, _record} -> result
          {:error, changeset} -> handle_record_insert_error(changeset)
        end
    end
  end

  defp process_new_operation(operation) do
    type = operation["type"]

    try do
      if common_fields?(operation) and type in @operation_types do
        apply_operation(type, operation)
      else
        rejected(operation, "invalid_operation")
      end
    catch
      {:handled_rejection, response} -> response
    end
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  defp handle_record_insert_error(changeset) do
    if Keyword.has_key?(changeset.errors, :operation_id) do
      Repo.rollback(:retry)
    else
      raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp apply_operation("open_group", operation), do: open_group(operation)

  defp apply_operation("transfer_deposit", operation) do
    if required?(operation, operation_required("transfer_deposit")) and
         nonempty_string?(operation["source_group_id"]) and
         nonempty_string?(operation["destination_group_id"]) do
      source_id = operation["source_group_id"]
      destination_id = operation["destination_group_id"]

      case Repo.get_by(Group, group_id: source_id) do
        nil ->
          rollback(operation, "group_not_found", %{"group_id" => source_id})

        source ->
          case Repo.get_by(Group, group_id: destination_id) do
            nil ->
              rollback(operation, "group_not_found", %{"group_id" => destination_id})

            destination ->
              with :ok <- revision_matches(source, operation),
                   :ok <-
                     revision_matches(destination, operation, "destination_expected_revision") do
                transfer_deposit(source, destination, operation)
              else
                {:stale, group, expected} ->
                  rollback(operation, "stale_revision", %{
                    "group_id" => group.group_id,
                    "expected_revision" => expected,
                    "actual_revision" => group.revision
                  })
              end
          end
      end
    else
      rollback(operation, "invalid_operation")
    end
  end

  defp apply_operation(type, operation)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    if required?(operation, operation_required(type)) and
         nonempty_string?(operation["payment_operation_id"]) do
      payment_id = operation["payment_operation_id"]

      case Repo.get_by(OperationRecord, operation_id: payment_id) do
        nil ->
          rollback(operation, "operation_not_found")

        record ->
          case Repo.get_by(PaymentDisposition, payment_operation_id: payment_id) do
            nil ->
              code =
                if type == "reduce_cash_payment",
                  do: "payment_not_reducible",
                  else: "payment_not_chargeable"

              rollback(operation, code)

            disposition ->
              group = Repo.get!(Group, disposition.group_id)

              case revision_matches(group, operation) do
                :ok ->
                  apply_payment_correction(type, record, disposition, group, operation)

                {:stale, group, expected} ->
                  rollback(operation, "stale_revision", %{
                    "group_id" => group.group_id,
                    "expected_revision" => expected,
                    "actual_revision" => group.revision
                  })
              end
          end
      end
    else
      rollback(operation, "invalid_operation")
    end
  end

  defp apply_operation(type, operation) do
    with true <- required?(operation, operation_required(type)) and valid_group_id?(operation),
         %Group{} = group <- Repo.get_by(Group, group_id: operation["group_id"]),
         :ok <- revision_matches(group, operation) do
      apply_to_group(type, group, operation)
    else
      false ->
        rollback(operation, "invalid_operation")

      nil ->
        rollback(operation, "group_not_found", %{"group_id" => operation["group_id"]})

      {:stale, group, expected} ->
        rollback(operation, "stale_revision", %{
          "group_id" => group.group_id,
          "expected_revision" => expected,
          "actual_revision" => group.revision
        })
    end
  end

  defp open_group(operation) do
    if required?(
         operation,
         ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)
       ) do
      if valid_identifiers?(operation) do
        if Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) do
          rollback(operation, "group_already_exists", %{"group_id" => operation["group_id"]})
        else
          create_group(operation)
        end
      else
        rollback(operation, "invalid_operation")
      end
    else
      rollback(operation, "invalid_operation")
    end
  end

  defp create_group(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt do
      cond do
        operation["rate_plan"] not in @rate_plans ->
          rollback(operation, "invalid_rate_plan")

        not valid_rooms?(operation["rooms"]) ->
          rollback(operation, "invalid_rooms")

        true ->
          nights = Date.diff(departure_on, arrival_on)

          {lodging_total, deposit_due} =
            totals(operation["rooms"], nights, operation["rate_plan"])

          group_changeset =
            Ecto.Changeset.change(%Group{
              group_id: operation["group_id"],
              guest_id: operation["guest_id"],
              property_id: operation["property_id"],
              booked_on: booked_on,
              arrival_on: arrival_on,
              departure_on: departure_on,
              rate_plan: operation["rate_plan"],
              status: "active",
              revision: 1,
              lodging_total_cents: lodging_total,
              deposit_due_cents: deposit_due,
              deposit_paid_cents: 0,
              cash_paid_cents: 0,
              credit_paid_cents: 0,
              refunded_cents: 0,
              retained_cents: 0,
              cash_converted_to_credit_cents: 0,
              cash_reduced_cents: 0,
              cash_charged_back_cents: 0,
              policy_version: policy_version(operation["rate_plan"], booked_on)
            })
            |> Ecto.Changeset.unique_constraint(:group_id)

          group =
            case Repo.insert(group_changeset) do
              {:ok, group} ->
                group

              {:error, _changeset} ->
                rollback(operation, "group_already_exists", %{
                  "group_id" => operation["group_id"]
                })
            end

          operation["rooms"]
          |> Enum.with_index()
          |> Enum.each(fn {room, position} ->
            lodging = nights * room["nightly_rate_cents"]
            deposit = room_deposit(lodging, operation["rate_plan"])

            Repo.insert!(%Room{
              group_id: group.id,
              room_id: room["room_id"],
              nightly_rate_cents: room["nightly_rate_cents"],
              position: position,
              status: "active",
              lodging_total_cents: lodging,
              deposit_due_cents: deposit
            })
          end)

          applied(operation, %{
            "group_id" => group.group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })
      end
    else
      _ -> rollback(operation, "invalid_stay")
    end
  end

  defp apply_to_group("record_cash_payment", group, operation) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        rollback(operation, "group_not_active", %{"group_id" => group.group_id})

      not (is_integer(amount) and amount > 0) ->
        rollback(operation, "invalid_amount", %{"group_id" => group.group_id})

      amount > outstanding(group) ->
        rollback(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})

      true ->
        allocate_funding(group, "cash", amount, operation["operation_id"])

        Repo.insert!(%PaymentDisposition{
          payment_operation_id: operation["operation_id"],
          group_id: group.id,
          recorded_cents: amount
        })

        group =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })

        applied(operation, %{
          "group_id" => group.group_id,
          "amount_cents" => amount,
          "outstanding_deposit_cents" => outstanding(group),
          "revision" => group.revision
        })
    end
  end

  defp apply_to_group("apply_hotel_credit", group, operation) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        rollback(operation, "group_not_active", %{"group_id" => group.group_id})

      not (is_integer(amount) and amount > 0) ->
        rollback(operation, "invalid_amount", %{"group_id" => group.group_id})

      amount > outstanding(group) ->
        rollback(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} -> apply_credit(group, operation, amount, occurred_on)
          _ -> rollback(operation, "invalid_operation", %{"group_id" => group.group_id})
        end
    end
  end

  defp apply_to_group("reschedule_group", group, operation) do
    with true <- group.status == "active",
         {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      new_departure = Date.add(new_arrival, Date.diff(group.departure_on, group.arrival_on))
      group = update_group!(group, %{arrival_on: new_arrival, departure_on: new_departure})

      applied(operation, %{
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival),
        "new_departure_on" => Date.to_iso8601(new_departure),
        "policy_version" => policy_version(group),
        "refundable_until" => format_date(refundable_until(group)),
        "revision" => group.revision
      })
    else
      false when group.status != "active" ->
        rollback(operation, "group_not_active", %{"group_id" => group.group_id})

      _ ->
        rollback(operation, "invalid_stay", %{"group_id" => group.group_id})
    end
  end

  defp apply_to_group("cancel_group", group, operation) do
    with true <- group.status == "active",
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, refund_method} <- refund_method(operation) do
      refundable = refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable do
        rollback(operation, "refund_method_not_available", %{"group_id" => group.group_id})
      else
        rooms =
          Repo.all(
            from r in Room,
              where: r.group_id == ^group.id and r.status == "active",
              order_by: r.position
          )

        settle_rooms(group, rooms, operation, occurred_on, refundable, refund_method, false)
      end
    else
      false -> rollback(operation, "group_not_active", %{"group_id" => group.group_id})
      _ -> rollback(operation, "invalid_operation", %{"group_id" => group.group_id})
    end
  end

  defp apply_to_group("cancel_rooms", group, operation) do
    room_ids = operation["room_ids"]

    with true <- group.status == "active",
         true <- is_list(room_ids) and room_ids != [] and Enum.uniq(room_ids) == room_ids,
         rooms <- Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: r.position),
         selected when length(selected) == length(room_ids) <-
           Enum.filter(rooms, &(&1.room_id in room_ids and &1.status == "active")),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, refund_method} <- refund_method(operation) do
      refundable = refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable do
        rollback(operation, "refund_method_not_available", %{"group_id" => group.group_id})
      else
        settle_rooms(group, selected, operation, occurred_on, refundable, refund_method, true)
      end
    else
      false when group.status != "active" ->
        rollback(operation, "group_not_active", %{"group_id" => group.group_id})

      false ->
        rollback(operation, "invalid_rooms", %{"group_id" => group.group_id})

      selected when is_list(selected) ->
        rollback(operation, "invalid_rooms", %{"group_id" => group.group_id})

      _ ->
        rollback(operation, "invalid_operation", %{"group_id" => group.group_id})
    end
  end

  defp transfer_deposit(source, destination, operation) do
    amount = operation["amount_cents"]

    source_allocations =
      Repo.all(
        from allocation in FundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^source.id and room.status == "active",
          order_by: [desc: allocation.id]
      )

    held = Enum.sum(Enum.map(source_allocations, & &1.amount_cents))

    cond do
      source.id == destination.id or source.guest_id != destination.guest_id ->
        rollback(operation, "invalid_transfer")

      source.status != "active" ->
        rollback(operation, "group_not_active", %{"group_id" => source.group_id})

      destination.status != "active" ->
        rollback(operation, "group_not_active", %{"group_id" => destination.group_id})

      not (is_integer(amount) and amount > 0) ->
        rollback(operation, "invalid_amount")

      amount > held ->
        rollback(operation, "transfer_exceeds_held_funding")

      amount > outstanding(destination) ->
        rollback(operation, "transfer_exceeds_outstanding")

      true ->
        slices = draw_allocations(source_allocations, amount)
        move_credit_applications(source, destination, slices)
        mark_transferred_payments(slices)

        Enum.each(slices, fn slice ->
          allocate_funding(
            destination,
            slice.kind,
            slice.amount_cents,
            slice.funding_operation_id,
            slice.credit_lot_id
          )
        end)

        source = refresh_group!(source, %{})
        destination = refresh_group!(destination, %{})

        applied(operation, %{
          "source_group_id" => source.group_id,
          "destination_group_id" => destination.group_id,
          "amount_cents" => amount,
          "source_outstanding_deposit_cents" => outstanding(source),
          "destination_outstanding_deposit_cents" => outstanding(destination),
          "source_revision" => source.revision,
          "destination_revision" => destination.revision
        })
    end
  end

  defp draw_allocations(allocations, amount) do
    {slices, 0} =
      Enum.reduce_while(allocations, {[], amount}, fn allocation, {slices, remaining} ->
        drawn = min(allocation.amount_cents, remaining)

        if drawn == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update_all(
            from(candidate in FundingAllocation, where: candidate.id == ^allocation.id),
            inc: [amount_cents: -drawn]
          )
        end

        slice = %{
          kind: allocation.kind,
          amount_cents: drawn,
          funding_operation_id: allocation.funding_operation_id,
          credit_lot_id: allocation.credit_lot_id
        }

        if remaining == drawn do
          {:halt, {[slice | slices], 0}}
        else
          {:cont, {[slice | slices], remaining - drawn}}
        end
      end)

    Enum.reverse(slices)
  end

  defp move_credit_applications(source, destination, slices) do
    slices
    |> Enum.filter(&(&1.kind == "credit"))
    |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
    |> Enum.each(fn {lot_id, amounts} ->
      amount = Enum.sum(amounts)
      decrement_credit_application(source.id, lot_id, amount)

      Repo.insert!(
        %CreditApplication{
          group_id: destination.id,
          credit_lot_id: lot_id,
          amount_cents: amount
        },
        on_conflict: [inc: [amount_cents: amount]],
        conflict_target: [:group_id, :credit_lot_id]
      )
    end)
  end

  defp mark_transferred_payments(slices) do
    payment_ids =
      slices
      |> Enum.filter(&(&1.kind == "cash" and not is_nil(&1.funding_operation_id)))
      |> Enum.map(& &1.funding_operation_id)
      |> Enum.uniq()

    if payment_ids != [] do
      Repo.update_all(
        from(disposition in PaymentDisposition,
          where: disposition.payment_operation_id in ^payment_ids
        ),
        set: [participated_in_transfer: true]
      )
    end
  end

  defp apply_credit(group, operation, amount, occurred_on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.expires_on >= ^occurred_on and
              lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      rollback(operation, "insufficient_credit", %{"group_id" => group.group_id})
    else
      slices = consume_credit_lots(lots, group, amount)

      Enum.each(slices, fn {lot_id, slice_amount} ->
        allocate_funding(
          group,
          "credit",
          slice_amount,
          operation["operation_id"],
          lot_id
        )
      end)

      group =
        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount
        })

      applied(operation, %{
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding(group),
        "revision" => group.revision
      })
    end
  end

  defp consume_credit_lots(_lots, _group, 0), do: []

  defp consume_credit_lots([lot | lots], group, remaining) do
    amount = min(lot.remaining_cents, remaining)

    query =
      from candidate in CreditLot,
        where: candidate.id == ^lot.id and candidate.remaining_cents >= ^amount

    case Repo.update_all(query, inc: [remaining_cents: -amount]) do
      {1, nil} ->
        Repo.insert!(
          %CreditApplication{group_id: group.id, credit_lot_id: lot.id, amount_cents: amount},
          on_conflict: [inc: [amount_cents: amount]],
          conflict_target: [:group_id, :credit_lot_id]
        )

        [{lot.id, amount} | consume_credit_lots(lots, group, remaining - amount)]

      {0, nil} ->
        Repo.rollback(:retry)
    end
  end

  defp settle_rooms(group, rooms, operation, occurred_on, refundable, refund_method, partial?) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from allocation in FundingAllocation,
          where: allocation.room_id in ^room_ids,
          order_by: [asc: allocation.id]
      )

    cash_allocations = Enum.filter(allocations, &(&1.kind == "cash"))
    credit_allocations = Enum.filter(allocations, &(&1.kind == "credit"))
    cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    if refundable, do: restore_credit_allocations(group, credit_allocations, occurred_on)
    if not refundable, do: consume_credit_applications(group, credit_allocations)

    refunded = if refundable and refund_method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash
    converted = if refundable and refund_method == "hotel_credit", do: cash, else: 0
    credit_issued = if converted > 0, do: converted + round_percentage(converted, 10), else: 0

    classify_payment_allocations(group, cash_allocations, refunded, retained, converted)

    if credit_issued > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          remaining_cents: credit_issued,
          expires_on: Date.add(occurred_on, 365),
          unrecovered_clawback_cents: 0
        })

      create_entitlements(lot, cash_allocations)
    end

    Repo.delete_all(from allocation in FundingAllocation, where: allocation.room_id in ^room_ids)
    Repo.update_all(from(room in Room, where: room.id in ^room_ids), set: [status: "cancelled"])

    remaining_rooms =
      Repo.all(from room in Room, where: room.group_id == ^group.id and room.status == "active")

    totals = active_room_totals(remaining_rooms)

    group =
      update_group!(group, %{
        status: if(remaining_rooms == [], do: "cancelled", else: "active"),
        lodging_total_cents: totals.lodging,
        deposit_due_cents: totals.due,
        deposit_paid_cents: totals.cash + totals.credit,
        cash_paid_cents: totals.cash,
        credit_paid_cents: totals.credit,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      })

    fields = %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "credit_issued_cents" => credit_issued,
      "revision" => group.revision
    }

    fields =
      if partial? do
        Map.put(fields, "cancelled_room_ids", Enum.map(rooms, & &1.room_id))
      else
        fields
      end

    applied(operation, fields)
  end

  defp restore_credit_allocations(group, allocations, occurred_on) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, lot_allocations} ->
      amount = Enum.sum(Enum.map(lot_allocations, & &1.amount_cents))
      lot = Repo.get!(CreditLot, lot_id)
      absorbed = min(amount, lot.unrecovered_clawback_cents)
      available = amount - absorbed

      changes = %{unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed}

      changes =
        if Date.compare(lot.expires_on, occurred_on) in [:gt, :eq] do
          Map.put(changes, :remaining_cents, lot.remaining_cents + available)
        else
          changes
        end

      Repo.update_all(from(candidate in CreditLot, where: candidate.id == ^lot.id),
        set: Map.to_list(changes)
      )

      decrement_credit_application(group.id, lot_id, amount)
    end)
  end

  defp consume_credit_applications(group, allocations) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, lot_allocations} ->
      decrement_credit_application(
        group.id,
        lot_id,
        Enum.sum(Enum.map(lot_allocations, & &1.amount_cents))
      )
    end)
  end

  defp decrement_credit_application(group_id, lot_id, amount) do
    application = Repo.get_by!(CreditApplication, group_id: group_id, credit_lot_id: lot_id)

    if application.amount_cents == amount do
      Repo.delete!(application)
    else
      Repo.update_all(from(a in CreditApplication, where: a.id == ^application.id),
        inc: [amount_cents: -amount]
      )
    end
  end

  defp classify_payment_allocations(group, allocations, refunded, retained, converted) do
    field =
      cond do
        refunded > 0 -> :refunded_cents
        retained > 0 -> :retained_cents
        converted > 0 -> :converted_cents
        true -> nil
      end

    if field do
      allocations
      |> Enum.reject(&is_nil(&1.funding_operation_id))
      |> Enum.group_by(& &1.funding_operation_id)
      |> Enum.each(fn {payment_id, payment_allocations} ->
        amount = Enum.sum(Enum.map(payment_allocations, & &1.amount_cents))
        disposition = Repo.get_by!(PaymentDisposition, payment_operation_id: payment_id)

        Repo.update_all(
          from(candidate in PaymentDisposition, where: candidate.id == ^disposition.id),
          inc: [{field, amount}]
        )

        Repo.insert!(
          struct(PaymentGroupDisposition, %{
            field => amount,
            payment_disposition_id: disposition.id,
            group_id: group.id
          }),
          on_conflict: [inc: [{field, amount}]],
          conflict_target: [:payment_disposition_id, :group_id]
        )
      end)
    end
  end

  defp create_entitlements(lot, cash_allocations) do
    cash_allocations
    |> Enum.reduce({0, MapSet.new()}, fn allocation, {running, seen} ->
      payment_id = allocation.funding_operation_id

      if payment_id && not MapSet.member?(seen, payment_id) do
        payment_total =
          cash_allocations
          |> Enum.filter(&(&1.funding_operation_id == payment_id))
          |> Enum.map(& &1.amount_cents)
          |> Enum.sum()

        entitlement =
          payment_total + round_percentage(running + payment_total, 10) -
            round_percentage(running, 10)

        Repo.insert!(%CreditEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: payment_id,
          amount_cents: entitlement,
          clawed_back_cents: 0
        })

        {running + payment_total, MapSet.put(seen, payment_id)}
      else
        {running + if(payment_id, do: 0, else: allocation.amount_cents), seen}
      end
    end)
  end

  defp apply_payment_correction("reduce_cash_payment", _record, disposition, group, operation) do
    amount = operation["amount_cents"]
    held = held_for_payment(disposition.payment_operation_id)

    cond do
      not (is_integer(amount) and amount > 0) ->
        rollback(operation, "invalid_amount", %{"group_id" => group.group_id})

      held == 0 ->
        rollback(operation, "payment_not_reducible", %{"group_id" => group.group_id})

      amount > held ->
        rollback(operation, "reduction_exceeds_held_cash", %{"group_id" => group.group_id})

      true ->
        removed_by_group = remove_held_allocations(disposition.payment_operation_id, amount)

        Repo.update_all(from(d in PaymentDisposition, where: d.id == ^disposition.id),
          inc: [reduced_cents: amount]
        )

        deltas =
          Enum.reduce(removed_by_group, %{}, fn {group_id, removed}, deltas ->
            add_group_delta(deltas, group_id, :cash_reduced_cents, removed)
          end)

        groups =
          refresh_changed_groups!(
            group,
            removed_by_group |> Map.keys() |> MapSet.new() |> MapSet.put(group.id),
            deltas
          )

        group = Map.fetch!(groups, group.id)

        applied(operation, %{
          "payment_operation_id" => disposition.payment_operation_id,
          "group_id" => group.group_id,
          "amount_cents" => amount,
          "outstanding_deposit_cents" => outstanding(group),
          "revision" => group.revision
        })
    end
  end

  defp apply_payment_correction("charge_back_payment", _record, disposition, group, operation) do
    remaining =
      disposition.recorded_cents - disposition.reduced_cents - disposition.charged_back_cents

    if remaining <= 0 do
      rollback(operation, "payment_not_chargeable", %{"group_id" => group.group_id})
    else
      held = held_for_payment(disposition.payment_operation_id)
      removed_by_group = remove_held_allocations(disposition.payment_operation_id, held)

      group_dispositions =
        Repo.all(
          from item in PaymentGroupDisposition,
            where: item.payment_disposition_id == ^disposition.id
        )

      claw_back_entitlements(disposition.payment_operation_id)

      Repo.update_all(from(d in PaymentDisposition, where: d.id == ^disposition.id),
        set: [
          refunded_cents: 0,
          retained_cents: 0,
          converted_cents: 0,
          charged_back_cents: disposition.charged_back_cents + remaining
        ]
      )

      Repo.delete_all(
        from item in PaymentGroupDisposition,
          where: item.payment_disposition_id == ^disposition.id
      )

      deltas =
        Enum.reduce(removed_by_group, %{}, fn {group_id, removed}, deltas ->
          add_group_delta(deltas, group_id, :cash_charged_back_cents, removed)
        end)

      deltas =
        Enum.reduce(group_dispositions, deltas, fn item, deltas ->
          deltas
          |> add_group_delta(item.group_id, :refunded_cents, -item.refunded_cents)
          |> add_group_delta(item.group_id, :retained_cents, -item.retained_cents)
          |> add_group_delta(
            item.group_id,
            :cash_converted_to_credit_cents,
            -item.converted_cents
          )
          |> add_group_delta(
            item.group_id,
            :cash_charged_back_cents,
            item.refunded_cents + item.retained_cents + item.converted_cents
          )
        end)

      changed_group_ids =
        group_dispositions
        |> Enum.reduce(removed_by_group |> Map.keys() |> MapSet.new(), fn item, ids ->
          MapSet.put(ids, item.group_id)
        end)
        |> MapSet.put(group.id)

      groups = refresh_changed_groups!(group, changed_group_ids, deltas)
      group = Map.fetch!(groups, group.id)

      applied(operation, %{
        "payment_operation_id" => disposition.payment_operation_id,
        "group_id" => group.group_id,
        "charged_back_cents" => remaining,
        "outstanding_deposit_cents" => outstanding(group),
        "revision" => group.revision
      })
    end
  end

  defp claw_back_entitlements(payment_id) do
    Repo.all(
      from entitlement in CreditEntitlement,
        where: entitlement.payment_operation_id == ^payment_id
    )
    |> Enum.each(fn entitlement ->
      amount = entitlement.amount_cents - entitlement.clawed_back_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      revoked = min(amount, lot.remaining_cents)
      unrecovered = amount - revoked

      Repo.update_all(from(candidate in CreditLot, where: candidate.id == ^lot.id),
        set: [
          remaining_cents: lot.remaining_cents - revoked,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
        ]
      )

      Repo.update_all(
        from(candidate in CreditEntitlement, where: candidate.id == ^entitlement.id),
        set: [clawed_back_cents: entitlement.amount_cents]
      )
    end)
  end

  defp remove_held_allocations(_payment_id, 0), do: %{}

  defp remove_held_allocations(payment_id, amount) do
    allocations =
      Repo.all(
        from allocation in FundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.funding_operation_id == ^payment_id and allocation.kind == "cash",
          order_by: [desc: allocation.id],
          select: {allocation, room.group_id}
      )

    {removed_by_group, 0} =
      Enum.reduce_while(allocations, {%{}, amount}, fn {allocation, group_id},
                                                       {removed_by_group, remaining} ->
        removed = min(allocation.amount_cents, remaining)

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update_all(
            from(candidate in FundingAllocation, where: candidate.id == ^allocation.id),
            inc: [amount_cents: -removed]
          )
        end

        removed_by_group = Map.update(removed_by_group, group_id, removed, &(&1 + removed))

        if remaining == removed do
          {:halt, {removed_by_group, 0}}
        else
          {:cont, {removed_by_group, remaining - removed}}
        end
      end)

    removed_by_group
  end

  defp held_for_payment(payment_id) do
    Repo.one(
      from allocation in FundingAllocation,
        where: allocation.funding_operation_id == ^payment_id and allocation.kind == "cash",
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp held_by_group(payment_id) do
    Repo.all(
      from allocation in FundingAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.group_id,
        where: allocation.funding_operation_id == ^payment_id and allocation.kind == "cash",
        group_by: group.group_id,
        order_by: group.group_id,
        select: %{"group_id" => group.group_id, "amount_cents" => sum(allocation.amount_cents)}
    )
  end

  defp refresh_changed_groups!(original_group, group_ids, deltas) do
    group_ids
    |> Enum.sort()
    |> Enum.reduce(%{}, fn group_id, groups ->
      group =
        if group_id == original_group.id, do: original_group, else: Repo.get!(Group, group_id)

      changes =
        deltas
        |> Map.get(group_id, %{})
        |> Map.new(fn {field, delta} -> {field, Map.fetch!(group, field) + delta} end)

      Map.put(groups, group_id, refresh_group!(group, changes))
    end)
  end

  defp add_group_delta(deltas, _group_id, _field, 0), do: deltas

  defp add_group_delta(deltas, group_id, field, amount) do
    Map.update(deltas, group_id, %{field => amount}, fn group_deltas ->
      Map.update(group_deltas, field, amount, &(&1 + amount))
    end)
  end

  defp allocate_funding(group, kind, amount, operation_id, credit_lot_id \\ nil) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.id and room.status == "active",
          order_by: [asc: room.position],
          preload: [:funding_allocations]
      )

    Enum.reduce_while(rooms, amount, fn room, remaining ->
      occupied = Enum.sum(Enum.map(room.funding_allocations, & &1.amount_cents))
      allocated = min(remaining, room.deposit_due_cents - occupied)

      if allocated > 0 do
        Repo.insert!(%FundingAllocation{
          room_id: room.id,
          kind: kind,
          amount_cents: allocated,
          funding_operation_id: operation_id,
          credit_lot_id: credit_lot_id
        })
      end

      if remaining == allocated, do: {:halt, 0}, else: {:cont, remaining - allocated}
    end)
  end

  defp active_room_totals(rooms) do
    Enum.reduce(rooms, %{lodging: 0, due: 0, cash: 0, credit: 0}, fn room, totals ->
      allocations =
        Repo.all(from allocation in FundingAllocation, where: allocation.room_id == ^room.id)

      %{
        lodging: totals.lodging + room.lodging_total_cents,
        due: totals.due + room.deposit_due_cents,
        cash:
          totals.cash +
            (allocations
             |> Enum.filter(&(&1.kind == "cash"))
             |> Enum.map(& &1.amount_cents)
             |> Enum.sum()),
        credit:
          totals.credit +
            (allocations
             |> Enum.filter(&(&1.kind == "credit"))
             |> Enum.map(& &1.amount_cents)
             |> Enum.sum())
      }
    end)
  end

  defp refresh_group!(group, extra_changes) do
    rooms =
      Repo.all(from room in Room, where: room.group_id == ^group.id and room.status == "active")

    totals = active_room_totals(rooms)

    update_group!(
      group,
      Map.merge(
        %{
          lodging_total_cents: totals.lodging,
          deposit_due_cents: totals.due,
          deposit_paid_cents: totals.cash + totals.credit,
          cash_paid_cents: totals.cash,
          credit_paid_cents: totals.credit
        },
        extra_changes
      )
    )
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _ -> :error
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) in [:lt, :eq]
    end
  end

  defp policy_version(%Group{} = group),
    do: group.policy_version || policy_version(group.rate_plan, group.booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @new_policy_date) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{rate_plan: "advance_purchase"}), do: nil

  defp refundable_until(group) do
    days = if policy_version(group) == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -days)
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp round_percentage(amount, percentage), do: div(amount * percentage + 50, 100)

  defp update_group!(group, changes) do
    changes =
      changes
      |> Map.put(:revision, group.revision + 1)
      |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

    query = from g in Group, where: g.id == ^group.id and g.revision == ^group.revision

    case Repo.update_all(query, set: Map.to_list(changes)) do
      {1, nil} -> struct(group, changes)
      {0, nil} -> Repo.rollback(:retry)
    end
  end

  defp revision_matches(group, operation, field \\ "expected_revision") do
    case Map.fetch(operation, field) do
      :error -> :ok
      {:ok, expected} when expected == group.revision -> :ok
      {:ok, expected} -> {:stale, group, expected}
    end
  end

  defp totals(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_sum, deposit_sum} ->
      lodging = nights * room["nightly_rate_cents"]
      deposit = room_deposit(lodging, rate_plan)
      {lodging_sum + lodging, deposit_sum + deposit}
    end)
  end

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp allocation_total(room, kind) do
    room.funding_allocations
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      is_map(room) and nonempty_string?(room["room_id"]) and
        is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0
    end) and Enum.uniq_by(rooms, & &1["room_id"]) == rooms
  end

  defp valid_rooms?(_), do: false

  defp valid_identifiers?(operation) do
    Enum.all?(~w(group_id guest_id property_id), &nonempty_string?(operation[&1]))
  end

  defp valid_group_id?(operation), do: nonempty_string?(operation["group_id"])

  defp common_fields?(operation) do
    required?(operation, ~w(operation_id type occurred_on)) and
      nonempty_string?(operation["operation_id"])
  end

  defp operation_required("record_cash_payment"), do: ~w(group_id amount_cents)
  defp operation_required("apply_hotel_credit"), do: ~w(group_id amount_cents)
  defp operation_required("reschedule_group"), do: ~w(group_id new_arrival_on)
  defp operation_required("cancel_group"), do: ~w(group_id)
  defp operation_required("cancel_rooms"), do: ~w(group_id room_ids)
  defp operation_required("reduce_cash_payment"), do: ~w(payment_operation_id amount_cents)
  defp operation_required("charge_back_payment"), do: ~w(payment_operation_id)

  defp operation_required("transfer_deposit"),
    do: ~w(source_group_id destination_group_id amount_cents)

  defp required?(map, keys), do: Enum.all?(keys, &Map.has_key?(map, &1))
  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: {:error, :invalid_date}

  defp outstanding(%Group{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_), do: nil

  defp applied(operation, fields),
    do: Map.merge(%{"operation_id" => operation_id(operation), "status" => "applied"}, fields)

  defp rejected(operation, code, fields \\ %{}) do
    Map.merge(
      %{"operation_id" => operation_id(operation), "status" => "rejected", "code" => code},
      fields
    )
  end

  defp rollback(operation, code, fields \\ %{}),
    do: throw({:handled_rejection, rejected(operation, code, fields)})
end
