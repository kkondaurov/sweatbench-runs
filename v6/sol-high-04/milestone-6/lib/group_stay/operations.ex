defmodule GroupStay.Operations do
  @moduledoc "Applies durable partner operations and exposes accounting views."

  import Ecto.Query

  alias GroupStay.Credits.{CreditEntitlement, CreditLot}
  alias GroupStay.Finance
  alias GroupStay.Groups.{Group, Room, RoomFunding}
  alias GroupStay.PartnerOperations.PartnerOperation
  alias GroupStay.Payments.{CashSettlement, PaymentAccounting}
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group cancel_rooms apply_hotel_credit reduce_cash_payment charge_back_payment transfer_deposit start_finance_reporting)
  @group_types ~w(record_cash_payment reschedule_group cancel_group cancel_rooms apply_hotel_credit)
  @payment_types ~w(reduce_cash_payment charge_back_payment)
  @rate_plans ~w(flexible advance_purchase)
  @new_flexible_policy_on ~D[2027-01-01]

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, operation.result}
    end
  end

  def get_operation_result(_), do: {:error, :operation_not_found}

  def get_payment_view(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      _ ->
        case Repo.get(PaymentAccounting, payment_operation_id) do
          nil -> {:error, :payment_not_reconcilable}
          payment -> {:ok, payment_view(payment)}
        end
    end
  end

  def get_payment_view(_), do: {:error, :operation_not_found}

  defp payment_view(payment) do
    view = %{
      payment_operation_id: payment.payment_operation_id,
      original_group_id: payment.original_group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.has_transferred do
      held_by_group =
        Repo.all(
          from f in RoomFunding,
            join: r in Room,
            on: r.id == f.room_id,
            where:
              f.payment_operation_id == ^payment.payment_operation_id and f.kind == "cash" and
                r.status == "active",
            group_by: f.group_id,
            order_by: f.group_id,
            select: %{group_id: f.group_id, amount_cents: sum(f.amount_cents)}
        )

      Map.put(view, :held_by_group, held_by_group)
    else
      view
    end
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  def group_view(%Group{} = group) do
    group = if Ecto.assoc_loaded?(group.rooms), do: group, else: Repo.preload(group, :rooms)
    active = Enum.filter(group.rooms, &(&1.status == "active"))
    lodging = sum(active, & &1.lodging_total_cents)
    due = sum(active, & &1.deposit_due_cents)
    cash = sum(active, & &1.cash_paid_cents)
    credit = sum(active, & &1.credit_paid_cents)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: iso(group.booked_on),
      arrival_on: iso(group.arrival_on),
      departure_on: iso(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: refundable_until_view(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &room_view/1),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: max(due - cash - credit, 0)
    }
  end

  defp room_view(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_total_cents: room.lodging_total_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end

  def ledger_view(on \\ Date.utc_today()) do
    cash =
      Repo.one(
        from g in Group,
          select: %{
            cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0),
            cash_reduced_cents: coalesce(sum(g.cash_reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(g.cash_charged_back_cents), 0)
          }
      )

    held =
      Repo.one(
        from r in Room, where: r.status == "active", select: coalesce(sum(r.cash_paid_cents), 0)
      ) || 0

    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      ) || 0

    applied_credit =
      Repo.one(
        from f in RoomFunding,
          join: r in Room,
          on: r.id == f.room_id,
          where: f.kind == "credit" and r.status == "active",
          select: coalesce(sum(f.amount_cents), 0)
      ) || 0

    cash
    |> Map.new(fn {key, value} -> {key, value || 0} end)
    |> Map.put(:cash_held_cents, held)
    |> Map.put(:credit_liability_cents, available + applied_credit)
    |> Map.put(:credit_shortfall_cents, credit_shortfall())
  end

  def guest_credit_view(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      guest_id: guest_id,
      available_cents: sum(lots, & &1.remaining_cents),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: iso(lot.expires_on)
          }
        end)
    }
  end

  defp process(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    submitted = json_value!(operation)

    Repo.transaction(
      fn ->
        case Repo.get_by(PartnerOperation, operation_id: operation_id) do
          nil -> execute_and_remember(operation, submitted)
          remembered -> replay_or_conflict(remembered, submitted)
        end
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp process(operation), do: execute(operation)
  defp execute(operation) when not is_map(operation), do: rejected(nil, "invalid_operation")

  defp execute(operation) do
    with :ok <- valid_common(operation),
         type when type in @operation_types <- operation["type"] do
      apply_operation(type, operation)
    else
      _ -> rejected(operation["operation_id"], "invalid_operation")
    end
  end

  defp execute_and_remember(operation, submitted) do
    reporting = Finance.get_reporting()
    finance_before = if reporting, do: Finance.snapshot()
    result = operation |> execute() |> json_value!()

    if reporting && result["status"] == "applied" do
      Finance.record_operation(reporting, operation, result, finance_before)
    end

    %PartnerOperation{}
    |> Ecto.Changeset.change(
      operation_id: operation["operation_id"],
      operation_type: submitted_operation_type(operation),
      submitted_content: submitted,
      result: result
    )
    |> Repo.insert!()

    result
  end

  defp replay_or_conflict(remembered, submitted) do
    if remembered.submitted_content == submitted,
      do: remembered.result,
      else: rejected(remembered.operation_id, "operation_id_conflict") |> json_value!()
  end

  defp apply_operation("open_group", operation), do: open_group(operation)
  defp apply_operation("transfer_deposit", operation), do: transfer_deposit(operation)

  defp apply_operation("start_finance_reporting", operation),
    do: start_finance_reporting(operation)

  defp apply_operation(type, operation) when type in @group_types,
    do: apply_to_group(type, operation)

  defp apply_operation(type, operation) when type in @payment_types,
    do: apply_to_payment(type, operation)

  defp start_finance_reporting(operation) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} ->
        case parse_date(operation["occurred_on"]) do
          {:ok, _occurred_on} ->
            case Finance.start_reporting(operation["operation_id"], starts_on) do
              {:ok, _reporting} ->
                applied(operation["operation_id"], %{starts_on: iso(starts_on)})

              {:error, :reporting_already_started} ->
                rejected(operation["operation_id"], "reporting_already_started")
            end

          :error ->
            rejected(operation["operation_id"], "invalid_operation")
        end

      :error ->
        rejected(operation["operation_id"], "invalid_reporting_date")
    end
  end

  defp apply_to_group(type, operation) do
    if valid_identifier?(operation["group_id"]) do
      case Repo.get(Group, operation["group_id"]) do
        nil ->
          rejected(operation["operation_id"], "group_not_found")

        group ->
          with_revision(group, operation, fn -> apply_group_domain(type, operation, group) end)
      end
    else
      rejected(operation["operation_id"], "invalid_operation")
    end
  end

  defp transfer_deposit(operation) do
    source_id = operation["source_group_id"]
    destination_id = operation["destination_group_id"]

    if valid_identifier?(source_id) and valid_identifier?(destination_id) do
      case Repo.get(Group, source_id) do
        nil ->
          rejected(operation["operation_id"], "group_not_found", %{group_id: source_id})

        source ->
          case Repo.get(Group, destination_id) do
            nil ->
              rejected(operation["operation_id"], "group_not_found", %{
                group_id: destination_id
              })

            destination ->
              with_transfer_revisions(source, destination, operation)
          end
      end
    else
      rejected(operation["operation_id"], "invalid_operation")
    end
  end

  defp with_transfer_revisions(source, destination, operation) do
    cond do
      Map.has_key?(operation, "expected_revision") and
          operation["expected_revision"] != source.revision ->
        stale_revision(operation, source, "expected_revision")

      Map.has_key?(operation, "destination_expected_revision") and
          operation["destination_expected_revision"] != destination.revision ->
        stale_revision(operation, destination, "destination_expected_revision")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, _} -> apply_transfer_domain(operation, source, destination)
          :error -> rejected(operation["operation_id"], "invalid_operation")
        end
    end
  end

  defp stale_revision(operation, group, expected_key) do
    rejected(operation["operation_id"], "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation[expected_key],
      actual_revision: group.revision
    })
  end

  defp apply_transfer_domain(operation, source, destination) do
    amount = operation["amount_cents"]

    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        rejected(operation["operation_id"], "invalid_transfer")

      source.status != "active" ->
        rejected(operation["operation_id"], "group_not_active", %{group_id: source.group_id})

      destination.status != "active" ->
        rejected(operation["operation_id"], "group_not_active", %{
          group_id: destination.group_id
        })

      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation["operation_id"], "invalid_operation")

      not positive_integer?(amount) ->
        rejected(operation["operation_id"], "invalid_amount")

      amount > held_funding(source.group_id) ->
        rejected(operation["operation_id"], "transfer_exceeds_held_funding")

      amount > group_outstanding(destination.group_id) ->
        rejected(operation["operation_id"], "transfer_exceeds_outstanding")

      true ->
        move_deposit(operation, source, destination)
    end
  end

  defp move_deposit(operation, source, destination) do
    amount = operation["amount_cents"]
    chunks = draw_funding!(source.group_id, amount)
    order = next_funding_order(destination.group_id)

    Enum.each(chunks, &allocate_transferred_chunk!(destination.group_id, &1, order))

    chunks
    |> Enum.filter(&(&1.kind == "cash" and not is_nil(&1.payment_operation_id)))
    |> Enum.map(& &1.payment_operation_id)
    |> Enum.uniq()
    |> Enum.each(fn payment_id ->
      payment = Repo.get!(PaymentAccounting, payment_id)
      payment |> Ecto.Changeset.change(has_transferred: true) |> Repo.update!()
    end)

    source = sync_group!(source)
    destination = sync_group!(destination)

    applied(operation["operation_id"], %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding(source),
      destination_outstanding_deposit_cents: outstanding(destination),
      source_revision: source.revision,
      destination_revision: destination.revision
    })
  end

  defp open_group(operation) do
    id = operation["operation_id"]

    with :ok <- require_open_fields(operation),
         {:ok, booked} <- parse_date(operation["occurred_on"]),
         {:ok, arrival} <- parse_stay_date(operation["arrival_on"]),
         {:ok, departure} <- parse_stay_date(operation["departure_on"]),
         :ok <- validate_stay(arrival, departure),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         :ok <- ensure_group_absent(operation["group_id"]) do
      nights = Date.diff(departure, arrival)

      rooms =
        Enum.map(rooms, fn room ->
          lodging = room["nightly_rate_cents"] * nights

          Map.merge(room, %{
            "lodging" => lodging,
            "due" => room_deposit(lodging, operation["rate_plan"])
          })
        end)

      lodging = sum(rooms, & &1["lodging"])
      due = sum(rooms, & &1["due"])

      group =
        %Group{}
        |> Ecto.Changeset.change(%{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: operation["rate_plan"],
          policy_version: policy_version(operation["rate_plan"], booked),
          status: "active",
          lodging_total_cents: lodging,
          deposit_due_cents: due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0,
          revision: 1
        })
        |> Repo.insert!()

      timestamp = now()

      rows =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          %{
            group_id: group.group_id,
            position: position,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            status: "active",
            lodging_total_cents: room["lodging"],
            deposit_due_cents: room["due"],
            cash_paid_cents: 0,
            credit_paid_cents: 0,
            inserted_at: timestamp,
            updated_at: timestamp
          }
        end)

      Repo.insert_all(Room, rows)
      applied(id, %{group_id: group.group_id, deposit_due_cents: due, revision: 1})
    else
      {:error, code} -> rejected(id, code)
      :error -> rejected(id, "invalid_operation")
    end
  end

  defp with_revision(group, operation, callback) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      rejected(operation["operation_id"], "stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      case parse_date(operation["occurred_on"]) do
        {:ok, _} -> callback.()
        :error -> rejected(operation["operation_id"], "invalid_operation")
      end
    end
  end

  defp apply_group_domain("record_cash_payment", operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      not positive_integer?(operation["amount_cents"]) ->
        rejected(operation["operation_id"], "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation["operation_id"], "payment_exceeds_outstanding")

      true ->
        record_cash(operation, group)
    end
  end

  defp apply_group_domain("apply_hotel_credit", operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      not positive_integer?(operation["amount_cents"]) ->
        rejected(operation["operation_id"], "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation["operation_id"], "payment_exceeds_outstanding")

      true ->
        apply_credit(operation, group)
    end
  end

  defp apply_group_domain("reschedule_group", operation, group) do
    cond do
      not Map.has_key?(operation, "new_arrival_on") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      true ->
        reschedule(operation, group)
    end
  end

  defp apply_group_domain("cancel_group", operation, group) do
    if group.status != "active",
      do: rejected(operation["operation_id"], "group_not_active"),
      else: settle_rooms(operation, group, active_rooms(group.group_id), false)
  end

  defp apply_group_domain("cancel_rooms", operation, group) do
    room_ids = operation["room_ids"]

    cond do
      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      not is_list(room_ids) or room_ids == [] ->
        rejected(operation["operation_id"], "invalid_rooms")

      Enum.uniq(room_ids) != room_ids ->
        rejected(operation["operation_id"], "invalid_rooms")

      not Enum.all?(room_ids, &valid_identifier?/1) ->
        rejected(operation["operation_id"], "invalid_rooms")

      true ->
        cancel_selected(operation, group)
    end
  end

  defp record_cash(operation, group) do
    amount = operation["amount_cents"]
    allocate_cash!(group.group_id, operation["operation_id"], amount)

    %PaymentAccounting{}
    |> Ecto.Changeset.change(
      payment_operation_id: operation["operation_id"],
      original_group_id: group.group_id,
      recorded_cents: amount,
      funding_order: next_funding_order(group.group_id) - 1,
      held_cents: amount,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    )
    |> Repo.insert!()

    updated = sync_group!(group)

    applied(operation["operation_id"], %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    })
  end

  defp apply_credit(operation, group) do
    amount = operation["amount_cents"]
    {:ok, occurred_on} = parse_date(operation["occurred_on"])

    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
              l.expires_on >= ^occurred_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    if sum(lots, & &1.remaining_cents) < amount do
      rejected(operation["operation_id"], "insufficient_credit")
    else
      lots |> consume_lots!(amount) |> allocate_credit!(group.group_id)
      updated = sync_group!(group)

      applied(operation["operation_id"], %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      })
    end
  end

  defp reschedule(operation, group) do
    with {:ok, occurred} <- parse_date(operation["occurred_on"]),
         {:ok, arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(arrival, occurred) == :gt do
      shift = Date.diff(arrival, group.arrival_on)
      departure = Date.add(group.departure_on, shift)
      updated = update_group!(group, arrival_on: arrival, departure_on: departure)

      applied(operation["operation_id"], %{
        group_id: group.group_id,
        new_arrival_on: iso(arrival),
        new_departure_on: iso(departure),
        policy_version: group.policy_version,
        refundable_until: refundable_until_view(updated),
        revision: updated.revision
      })
    else
      _ -> rejected(operation["operation_id"], "invalid_stay")
    end
  end

  defp cancel_selected(operation, group) do
    requested = MapSet.new(operation["room_ids"])
    rooms = Repo.all(from r in Room, where: r.group_id == ^group.group_id, order_by: r.position)
    selected = Enum.filter(rooms, &MapSet.member?(requested, &1.room_id))

    if length(selected) != MapSet.size(requested) or Enum.any?(selected, &(&1.status != "active")),
      do: rejected(operation["operation_id"], "invalid_rooms"),
      else: settle_rooms(operation, group, selected, true)
  end

  defp settle_rooms(operation, group, rooms, include_ids) do
    {:ok, occurred} = parse_date(operation["occurred_on"])
    method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred)

    cond do
      method not in ["cash", "hotel_credit"] ->
        rejected(operation["operation_id"], "invalid_operation")

      method == "hotel_credit" and not refundable ->
        rejected(operation["operation_id"], "refund_method_not_available")

      true ->
        do_settle_rooms(operation, group, rooms, occurred, method, refundable, include_ids)
    end
  end

  defp do_settle_rooms(operation, group, rooms, occurred, method, refundable, include_ids) do
    room_pks = Enum.map(rooms, & &1.id)

    fundings =
      Repo.all(
        from f in RoomFunding,
          where: f.room_id in ^room_pks,
          order_by: [asc: f.funding_order, asc: f.id]
      )

    cash_fundings = Enum.filter(fundings, &(&1.kind == "cash"))
    credit_fundings = Enum.filter(fundings, &(&1.kind == "credit"))
    cash = sum(cash_fundings, & &1.amount_cents)
    refunded = if refundable and method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash
    converted = if refundable and method == "hotel_credit", do: cash, else: 0

    update_payment_settlements!(
      cash_fundings,
      group.group_id,
      refunded,
      retained,
      converted
    )

    restore_credit_fundings!(credit_fundings, occurred, refundable)

    issued =
      if converted > 0,
        do: issue_credit!(group, operation["operation_id"], occurred, cash_fundings),
        else: 0

    Repo.delete_all(from f in RoomFunding, where: f.room_id in ^room_pks)

    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0)
      |> Repo.update!()
    end)

    remaining? =
      Repo.exists?(from r in Room, where: r.group_id == ^group.group_id and r.status == "active")

    updated =
      sync_group!(group,
        status: if(remaining?, do: "active", else: "cancelled"),
        cash_refunded_cents: group.cash_refunded_cents + refunded,
        cash_retained_cents: group.cash_retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      )

    fields = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: updated.revision
    }

    fields =
      if include_ids,
        do: Map.put(fields, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
        else: fields

    applied(operation["operation_id"], fields)
  end

  defp update_payment_settlements!(fundings, group_id, refunded, retained, converted) do
    field =
      cond do
        refunded > 0 -> :refunded_cents
        retained > 0 -> :retained_cents
        converted > 0 -> :converted_to_credit_cents
        true -> nil
      end

    fundings
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id, & &1.amount_cents)
    |> Enum.each(fn {payment_id, amounts} ->
      amount = Enum.sum(amounts)
      payment = Repo.get!(PaymentAccounting, payment_id)
      attrs = %{held_cents: payment.held_cents - amount}

      attrs =
        if field, do: Map.put(attrs, field, Map.fetch!(payment, field) + amount), else: attrs

      payment |> Ecto.Changeset.change(attrs) |> Repo.update!()

      if field do
        %CashSettlement{}
        |> Ecto.Changeset.change(
          payment_operation_id: payment_id,
          group_id: group_id,
          kind: settlement_kind(field),
          amount_cents: amount
        )
        |> Repo.insert!()
      end
    end)
  end

  defp settlement_kind(:refunded_cents), do: "refunded"
  defp settlement_kind(:retained_cents), do: "retained"
  defp settlement_kind(:converted_to_credit_cents), do: "converted"

  defp issue_credit!(group, source_id, occurred, fundings) do
    principal = sum(fundings, & &1.amount_cents)
    amount = bonus_value(principal)

    lot =
      %CreditLot{}
      |> Ecto.Changeset.change(
        guest_id: group.guest_id,
        source_operation_id: source_id,
        issued_on: occurred,
        remaining_cents: amount,
        expires_on: Date.add(occurred, 365),
        unrecovered_clawback_cents: 0
      )
      |> Repo.insert!()

    contributors = funding_contributors(fundings)

    Enum.reduce(Enum.with_index(contributors), 0, fn {{payment_id, cash, order}, index},
                                                     running ->
      next = running + cash

      %CreditEntitlement{}
      |> Ecto.Changeset.change(
        credit_lot_id: lot.id,
        payment_operation_id: payment_id,
        principal_cents: cash,
        entitlement_cents: bonus_value(next) - bonus_value(running),
        revoked_cents: 0,
        funding_order: order * 1_000_000 + index
      )
      |> Repo.insert!()

      next
    end)

    amount
  end

  defp funding_contributors(fundings) do
    Enum.reduce(fundings, [], fn funding, acc ->
      key = funding.payment_operation_id

      case List.last(acc) do
        {^key, amount, order} ->
          List.replace_at(acc, -1, {key, amount + funding.amount_cents, order})

        _ ->
          acc ++ [{key, funding.amount_cents, funding.funding_order}]
      end
    end)
  end

  defp restore_credit_fundings!(fundings, occurred, true) do
    fundings
    |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
    |> Enum.each(fn {lot_id, amounts} ->
      restore_credit!(Repo.get!(CreditLot, lot_id), Enum.sum(amounts), occurred)
    end)
  end

  defp restore_credit_fundings!(_fundings, _occurred, false), do: :ok

  defp restore_credit!(lot, amount, occurred) do
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    excess = amount - absorbed
    restorable = if Date.compare(lot.expires_on, occurred) == :lt, do: 0, else: excess

    lot
    |> Ecto.Changeset.change(
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + restorable
    )
    |> Repo.update!()
  end

  defp apply_to_payment(type, operation) do
    target_id = operation["payment_operation_id"]

    if not valid_identifier?(target_id) do
      rejected(operation["operation_id"], "invalid_operation")
    else
      case Repo.get_by(PartnerOperation, operation_id: target_id) do
        nil -> rejected(operation["operation_id"], "operation_not_found")
        _ -> apply_to_reconcilable(type, operation, Repo.get(PaymentAccounting, target_id))
      end
    end
  end

  defp apply_to_reconcilable("reduce_cash_payment", operation, nil),
    do: rejected(operation["operation_id"], "payment_not_reducible")

  defp apply_to_reconcilable("charge_back_payment", operation, nil),
    do: rejected(operation["operation_id"], "payment_not_chargeable")

  defp apply_to_reconcilable(type, operation, payment) do
    group = Repo.get!(Group, payment.original_group_id)

    with_revision(group, operation, fn ->
      apply_payment_domain(type, operation, payment, group)
    end)
  end

  defp apply_payment_domain("reduce_cash_payment", operation, payment, group) do
    cond do
      payment.held_cents <= 0 ->
        rejected(operation["operation_id"], "payment_not_reducible")

      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation["operation_id"], "invalid_operation")

      not positive_integer?(operation["amount_cents"]) ->
        rejected(operation["operation_id"], "invalid_amount")

      operation["amount_cents"] > payment.held_cents ->
        rejected(operation["operation_id"], "reduction_exceeds_held_cash")

      true ->
        reduce_cash(operation, payment, group)
    end
  end

  defp apply_payment_domain("charge_back_payment", operation, payment, group) do
    if payment.reduced_cents == payment.recorded_cents or payment.charged_back_cents > 0,
      do: rejected(operation["operation_id"], "payment_not_chargeable"),
      else: charge_back(operation, payment, group)
  end

  defp reduce_cash(operation, payment, group) do
    amount = operation["amount_cents"]
    changed_group_ids = remove_held_cash!(payment.payment_operation_id, amount)

    payment
    |> Ecto.Changeset.change(
      held_cents: payment.held_cents - amount,
      reduced_cents: payment.reduced_cents + amount
    )
    |> Repo.update!()

    updated_groups =
      sync_affected_groups!(
        MapSet.put(changed_group_ids, group.group_id),
        %{group.group_id => [cash_reduced_cents: group.cash_reduced_cents + amount]}
      )

    updated = Map.fetch!(updated_groups, group.group_id)

    applied(operation["operation_id"], %{
      payment_operation_id: payment.payment_operation_id,
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    })
  end

  defp charge_back(operation, payment, group) do
    charged = payment.recorded_cents - payment.reduced_cents
    changed_group_ids = remove_held_cash!(payment.payment_operation_id, payment.held_cents)

    settlements =
      Repo.all(
        from s in CashSettlement,
          where: s.payment_operation_id == ^payment.payment_operation_id
      )

    revoke_entitlements!(payment.payment_operation_id)

    payment
    |> Ecto.Changeset.change(
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: charged
    )
    |> Repo.update!()

    settlement_group_ids = MapSet.new(settlements, & &1.group_id)
    extras = chargeback_group_extras(settlements, group.group_id, charged)

    Repo.delete_all(
      from s in CashSettlement, where: s.payment_operation_id == ^payment.payment_operation_id
    )

    updated_groups =
      changed_group_ids
      |> MapSet.union(settlement_group_ids)
      |> MapSet.put(group.group_id)
      |> sync_affected_groups!(extras)

    updated = Map.fetch!(updated_groups, group.group_id)

    applied(operation["operation_id"], %{
      payment_operation_id: payment.payment_operation_id,
      group_id: group.group_id,
      charged_back_cents: charged,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    })
  end

  defp remove_held_cash!(_payment_id, 0), do: MapSet.new()

  defp remove_held_cash!(payment_id, amount) do
    allocations =
      Repo.all(
        from f in RoomFunding,
          where: f.payment_operation_id == ^payment_id and f.kind == "cash",
          order_by: [desc: f.id]
      )

    {_remaining, changed_group_ids} =
      Enum.reduce_while(allocations, {amount, MapSet.new()}, fn funding, {remaining, group_ids} ->
        removed = min(funding.amount_cents, remaining)

        if removed == funding.amount_cents,
          do: Repo.delete!(funding),
          else:
            funding
            |> Ecto.Changeset.change(amount_cents: funding.amount_cents - removed)
            |> Repo.update!()

        room = Repo.get!(Room, funding.room_id)

        room
        |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents - removed)
        |> Repo.update!()

        state = {remaining - removed, MapSet.put(group_ids, funding.group_id)}
        if removed == remaining, do: {:halt, state}, else: {:cont, state}
      end)

    changed_group_ids
  end

  defp revoke_entitlements!(payment_id) do
    Repo.all(
      from e in CreditEntitlement,
        where: e.payment_operation_id == ^payment_id and e.revoked_cents < e.entitlement_cents,
        order_by: e.id
    )
    |> Enum.each(fn entitlement ->
      amount = entitlement.entitlement_cents - entitlement.revoked_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, amount)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - removed
      )
      |> Repo.update!()

      entitlement
      |> Ecto.Changeset.change(revoked_cents: entitlement.entitlement_cents)
      |> Repo.update!()
    end)
  end

  defp chargeback_group_extras(settlements, original_group_id, charged) do
    settlement_totals =
      Enum.reduce(settlements, %{}, fn settlement, totals ->
        group_totals =
          Map.get(totals, settlement.group_id, %{refunded: 0, retained: 0, converted: 0})

        key = settlement_total_key(settlement.kind)

        Map.put(
          totals,
          settlement.group_id,
          Map.update!(group_totals, key, &(&1 + settlement.amount_cents))
        )
      end)

    group_ids = MapSet.put(MapSet.new(Map.keys(settlement_totals)), original_group_id)

    Map.new(group_ids, fn group_id ->
      current = Repo.get!(Group, group_id)
      totals = Map.get(settlement_totals, group_id, %{refunded: 0, retained: 0, converted: 0})

      attrs = [
        cash_refunded_cents: current.cash_refunded_cents - totals.refunded,
        cash_retained_cents: current.cash_retained_cents - totals.retained,
        cash_converted_to_credit_cents: current.cash_converted_to_credit_cents - totals.converted
      ]

      attrs =
        if group_id == original_group_id,
          do:
            Keyword.put(
              attrs,
              :cash_charged_back_cents,
              current.cash_charged_back_cents + charged
            ),
          else: attrs

      {group_id, attrs}
    end)
  end

  defp settlement_total_key("refunded"), do: :refunded
  defp settlement_total_key("retained"), do: :retained
  defp settlement_total_key("converted"), do: :converted

  defp draw_funding!(group_id, amount) do
    allocations =
      Repo.all(
        from f in RoomFunding,
          join: r in Room,
          on: r.id == f.room_id,
          where: f.group_id == ^group_id and r.status == "active",
          order_by: [desc: f.id]
      )

    {chunks, remaining} =
      Enum.reduce_while(allocations, {[], amount}, fn funding, {chunks, remaining} ->
        moved = min(funding.amount_cents, remaining)

        if moved == funding.amount_cents,
          do: Repo.delete!(funding),
          else:
            funding
            |> Ecto.Changeset.change(amount_cents: funding.amount_cents - moved)
            |> Repo.update!()

        room = Repo.get!(Room, funding.room_id)

        room_attrs =
          if funding.kind == "cash",
            do: [cash_paid_cents: room.cash_paid_cents - moved],
            else: [credit_paid_cents: room.credit_paid_cents - moved]

        room |> Ecto.Changeset.change(room_attrs) |> Repo.update!()

        chunk = %{
          kind: funding.kind,
          amount_cents: moved,
          payment_operation_id: funding.payment_operation_id,
          credit_lot_id: funding.credit_lot_id
        }

        state = {chunks ++ [chunk], remaining - moved}
        if moved == remaining, do: {:halt, state}, else: {:cont, state}
      end)

    if remaining != 0, do: raise("held funding changed during transfer")
    chunks
  end

  defp allocate_transferred_chunk!(group_id, chunk, order) do
    allocate_to_rooms!(group_id, chunk.amount_cents, fn room, used ->
      insert_funding!(
        room,
        chunk.kind,
        used,
        order,
        chunk.payment_operation_id,
        chunk.credit_lot_id
      )

      attrs =
        if chunk.kind == "cash",
          do: [cash_paid_cents: room.cash_paid_cents + used],
          else: [credit_paid_cents: room.credit_paid_cents + used]

      room |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end)
  end

  defp allocate_cash!(group_id, payment_id, amount) do
    order = next_funding_order(group_id)

    allocate_to_rooms!(group_id, amount, fn room, used ->
      insert_funding!(room, "cash", used, order, payment_id, nil)

      room
      |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + used)
      |> Repo.update!()
    end)
  end

  defp consume_lots!(lots, amount) do
    {chunks, _} =
      Enum.reduce_while(lots, {[], amount}, fn lot, {chunks, remaining} ->
        used = min(lot.remaining_cents, remaining)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
        |> Repo.update!()

        state = {chunks ++ [{lot.id, used}], remaining - used}
        if used == remaining, do: {:halt, state}, else: {:cont, state}
      end)

    chunks
  end

  defp allocate_credit!(chunks, group_id) when is_list(chunks) and is_binary(group_id),
    do:
      allocate_credit_chunks!(
        active_rooms(group_id),
        chunks,
        group_id,
        next_funding_order(group_id)
      )

  defp allocate_credit_chunks!(_rooms, [], _group_id, _order), do: :ok
  defp allocate_credit_chunks!([], _chunks, _group_id, _order), do: :ok

  defp allocate_credit_chunks!(
         [room | rest],
         [{lot_id, amount} | chunks],
         group_id,
         order
       ) do
    capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

    if capacity == 0 do
      allocate_credit_chunks!(rest, [{lot_id, amount} | chunks], group_id, order)
    else
      used = min(capacity, amount)
      insert_funding!(room, "credit", used, order, nil, lot_id)

      room
      |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + used)
      |> Repo.update!()

      updated_room = %{room | credit_paid_cents: room.credit_paid_cents + used}

      cond do
        used == capacity and used == amount ->
          allocate_credit_chunks!(rest, chunks, group_id, order)

        used == capacity ->
          allocate_credit_chunks!(rest, [{lot_id, amount - used} | chunks], group_id, order)

        true ->
          allocate_credit_chunks!([updated_room | rest], chunks, group_id, order)
      end
    end
  end

  defp allocate_to_rooms!(group_id, amount, callback) do
    Enum.reduce_while(active_rooms(group_id), amount, fn room, remaining ->
      capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
      used = min(capacity, remaining)
      if used > 0, do: callback.(room, used)
      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp insert_funding!(room, kind, amount, order, payment_id, lot_id) do
    %RoomFunding{}
    |> Ecto.Changeset.change(
      room_id: room.id,
      group_id: room.group_id,
      kind: kind,
      amount_cents: amount,
      funding_order: order,
      payment_operation_id: payment_id,
      credit_lot_id: lot_id
    )
    |> Repo.insert!()
  end

  defp next_funding_order(group_id) do
    (Repo.one(from f in RoomFunding, where: f.group_id == ^group_id, select: max(f.funding_order)) ||
       0) + 1
  end

  defp held_funding(group_id) do
    Repo.one(
      from f in RoomFunding,
        join: r in Room,
        on: r.id == f.room_id,
        where: f.group_id == ^group_id and r.status == "active",
        select: coalesce(sum(f.amount_cents), 0)
    ) || 0
  end

  defp group_outstanding(group_id) do
    totals =
      Repo.one(
        from r in Room,
          where: r.group_id == ^group_id and r.status == "active",
          select: %{
            due: coalesce(sum(r.deposit_due_cents), 0),
            cash: coalesce(sum(r.cash_paid_cents), 0),
            credit: coalesce(sum(r.credit_paid_cents), 0)
          }
      )

    max((totals.due || 0) - (totals.cash || 0) - (totals.credit || 0), 0)
  end

  defp sync_affected_groups!(group_ids, extras) do
    group_ids
    |> Enum.sort()
    |> Map.new(fn group_id ->
      group = Repo.get!(Group, group_id)
      {group_id, sync_group!(group, Map.get(extras, group_id, []))}
    end)
  end

  defp sync_group!(group, extra \\ []) do
    totals =
      Repo.one(
        from r in Room,
          where: r.group_id == ^group.group_id and r.status == "active",
          select: %{
            lodging: coalesce(sum(r.lodging_total_cents), 0),
            due: coalesce(sum(r.deposit_due_cents), 0),
            cash: coalesce(sum(r.cash_paid_cents), 0),
            credit: coalesce(sum(r.credit_paid_cents), 0)
          }
      )

    attrs = [
      lodging_total_cents: totals.lodging || 0,
      deposit_due_cents: totals.due || 0,
      cash_paid_cents: totals.cash || 0,
      credit_paid_cents: totals.credit || 0,
      deposit_paid_cents: (totals.cash || 0) + (totals.credit || 0)
    ]

    update_group!(group, Keyword.merge(attrs, extra))
  end

  defp active_rooms(group_id),
    do:
      Repo.all(
        from r in Room,
          where: r.group_id == ^group_id and r.status == "active",
          order_by: r.position
      )

  defp credit_shortfall do
    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, total ->
      applied =
        Repo.one(
          from f in RoomFunding,
            join: r in Room,
            on: r.id == f.room_id,
            where: f.credit_lot_id == ^lot.id and f.kind == "credit" and r.status == "active",
            select: coalesce(sum(f.amount_cents), 0)
        ) || 0

      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp refundable?(%Group{policy_version: "advance-nonrefundable"}, _), do: false
  defp refundable?(group, occurred), do: Date.compare(occurred, refundable_until(group)) != :gt

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: date}),
    do: Date.add(date, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: date}),
    do: Date.add(date, -30)

  defp refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until_view(group) do
    case refundable_until(group) do
      nil -> nil
      date -> iso(date)
    end
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked),
    do: if(Date.compare(booked, @new_flexible_policy_on) == :lt, do: "flex-14", else: "flex-30")

  defp update_group!(group, attrs),
    do:
      group
      |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
      |> Repo.update!()

  defp outstanding(%Group{status: "cancelled"}), do: 0
  defp outstanding(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp require_open_fields(operation) do
    identifiers = Enum.all?(~w(group_id guest_id property_id), &valid_identifier?(operation[&1]))
    fields = Enum.all?(~w(arrival_on departure_on rate_plan rooms), &Map.has_key?(operation, &1))
    if identifiers and fields, do: :ok, else: :error
  end

  defp validate_stay(arrival, departure),
    do: if(Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, "invalid_stay"})

  defp validate_rate_plan(plan) when plan in @rate_plans, do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate}
        when is_binary(id) and id != "" and is_integer(rate) and rate >= 0 ->
          true

        _ ->
          false
      end)

    ids = Enum.map(rooms, & &1["room_id"])
    if valid and Enum.uniq(ids) == ids, do: {:ok, rooms}, else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp room_deposit(lodging, "advance_purchase"), do: lodging
  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp parse_stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_stay"}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp ensure_group_absent(group_id),
    do:
      if(Repo.exists?(from g in Group, where: g.group_id == ^group_id),
        do: {:error, "group_already_exists"},
        else: :ok
      )

  defp valid_common(%{"operation_id" => id, "type" => type, "occurred_on" => occurred})
       when is_binary(id) and id != "" and is_binary(type) and is_binary(occurred), do: :ok

  defp valid_common(_), do: :error
  defp submitted_operation_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_operation_type(_), do: nil
  defp json_value!(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, _}), do: raise("operation transaction failed")
  defp applied(id, fields), do: Map.merge(%{operation_id: id, status: "applied"}, fields)

  defp rejected(id, code, fields \\ %{}),
    do: Map.merge(%{operation_id: id, status: "rejected", code: code}, fields)

  defp sum(items, fun), do: Enum.reduce(items, 0, fn item, total -> total + (fun.(item) || 0) end)
  defp iso(date), do: Date.to_iso8601(date)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
