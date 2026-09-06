defmodule GroupStay.OperationalCore do
  import Ecto.Query

  alias GroupStay.OperationalCore.{
    CashAllocation,
    CreditAllocation,
    CreditClawback,
    CreditEntitlement,
    CreditLot,
    CreditLotAccount,
    DepositAllocationSequence,
    Group,
    PartnerOperation,
    PaymentAccount,
    PaymentDisposition,
    Room
  }

  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @max_sqlite_integer 9_223_372_036_854_775_807
  @policy_cutoff ~D[2027-01-01]

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_operation(_operation_id), do: nil

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
          nil -> :not_found
          _operation -> payment_statement(payment_operation_id)
        end
      end)

    result
  end

  def get_payment(_payment_operation_id), do: :not_found

  defp payment_statement(payment_operation_id) do
    case Repo.get(PaymentAccount, payment_operation_id) do
      nil ->
        :not_reconcilable

      account ->
        statement = %{
          payment_operation_id: account.payment_operation_id,
          original_group_id: account.group_id,
          recorded_cents: account.recorded_cents,
          held_cents: account.held_cents,
          refunded_cents: account.refunded_cents,
          retained_cents: account.retained_cents,
          converted_to_credit_cents: account.converted_to_credit_cents,
          reduced_cents: account.reduced_cents,
          charged_back_cents: account.charged_back_cents
        }

        statement =
          if account.participated_in_transfer do
            held_by_group =
              from(allocation in CashAllocation,
                where: allocation.payment_operation_id == ^payment_operation_id,
                select: {allocation.group_id, allocation.amount_cents}
              )
              |> Repo.all()
              |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
              |> Enum.map(fn {group_id, amounts} ->
                %{group_id: group_id, amount_cents: Enum.sum(amounts)}
              end)
              |> Enum.sort_by(& &1.group_id)

            Map.put(statement, :held_by_group, held_by_group)
          else
            statement
          end

        {:ok, statement}
    end
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> render_group(group)
    end
  end

  def get_group(_group_id), do: nil

  def report_date(nil), do: {:ok, Date.utc_today()}

  def report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> parse_expanded_date(value)
    end
  end

  def report_date(_value), do: :error

  def ledger(on \\ Date.utc_today()) do
    {:ok, ledger} = Repo.transaction(fn -> ledger_snapshot(on) end)
    ledger
  end

  defp ledger_snapshot(on) do
    held =
      from(allocation in CashAllocation, select: allocation.amount_cents)
      |> Repo.all()
      |> Enum.sum()

    {refunded, retained, converted} =
      from(group in Group,
        select: {
          group.cash_refunded_cents,
          group.cash_retained_cents,
          group.cash_converted_to_credit_cents
        }
      )
      |> Repo.all()
      |> Enum.reduce({0, 0, 0}, fn
        {group_refunded, group_retained, group_converted}, {refunded, retained, converted} ->
          {
            refunded + group_refunded,
            retained + group_retained,
            converted + group_converted
          }
      end)

    {reduced, charged_back} =
      from(account in PaymentAccount,
        select: {account.reduced_cents, account.charged_back_cents}
      )
      |> Repo.all()
      |> Enum.reduce({0, 0}, fn {account_reduced, account_charged_back},
                                {reduced, charged_back} ->
        {reduced + account_reduced, charged_back + account_charged_back}
      end)

    %{
      cash_held_cents: held,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      cash_reduced_cents: reduced,
      cash_charged_back_cents: charged_back,
      credit_liability_cents: credit_liability(on),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  def guest_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: render_credit_lots(lots)
    }
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: update_group(operation, :record_cash_payment)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: update_group(operation, :apply_hotel_credit)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: update_group(operation, :reschedule_group)

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: update_group(operation, :cancel_group)

  defp apply_operation(%{"type" => "cancel_rooms"} = operation),
    do: update_group(operation, :cancel_rooms)

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation),
    do: update_payment(operation, :reduce)

  defp apply_operation(%{"type" => "charge_back_payment"} = operation),
    do: update_payment(operation, :charge_back)

  defp apply_operation(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp apply_operation(operation) when is_map(operation),
    do: reject(operation, "invalid_operation")

  defp apply_operation(_operation), do: reject(%{}, "invalid_operation")

  defp open_group(operation) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with :ok <- validate_structure(operation, required),
         :ok <- validate_identifiers(operation, ~w(group_id guest_id property_id)),
         {:ok, booked_on} <- parse_stay_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_stay_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_stay_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         {:ok, {lodging_total, deposit_due}} <-
           calculate_totals(rooms, arrival_on, departure_on, operation["rate_plan"]),
         :ok <- ensure_group_is_new(operation["group_id"]),
         {:ok, group} <-
           insert_group(
             operation,
             booked_on,
             arrival_on,
             departure_on,
             rooms,
             lodging_total,
             deposit_due
           ) do
      %{
        operation_id: operation["operation_id"],
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:error, code} -> reject(operation, code, group_id(operation))
    end
  end

  defp update_group(operation, kind) do
    required = update_required_fields(kind)

    with :ok <- validate_structure(operation, required),
         :ok <- validate_identifiers(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- validate_expected_revision(operation),
         :ok <- compare_revision(operation, group),
         :ok <- ensure_update_allowed(group, kind) do
      apply_group_update(operation, group, kind)
    else
      {:error, "stale_revision", group} ->
        reject(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation["expected_revision"],
          actual_revision: group.revision
        })

      {:error, code} ->
        reject(operation, code, group_id(operation))
    end
  end

  defp update_payment(operation, kind) do
    required =
      if kind == :reduce,
        do: ~w(operation_id occurred_on payment_operation_id amount_cents),
        else: ~w(operation_id occurred_on payment_operation_id)

    with :ok <- validate_structure(operation, required),
         :ok <- validate_identifiers(operation, ["payment_operation_id"]),
         {:ok, account} <- fetch_payment_account(operation["payment_operation_id"], kind),
         {:ok, group} <- fetch_group(account.group_id),
         :ok <- validate_expected_revision(operation),
         :ok <- compare_revision(operation, group),
         {:ok, _occurred_on} <- parse_operation_date(operation["occurred_on"]) do
      apply_payment_update(operation, group, account, kind)
    else
      {:error, "stale_revision", group} ->
        reject(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation["expected_revision"],
          actual_revision: group.revision
        })

      {:error, code} ->
        reject(operation, code)
    end
  end

  defp transfer_deposit(operation) do
    required =
      ~w(operation_id occurred_on source_group_id destination_group_id amount_cents)

    with :ok <- validate_structure(operation, required),
         :ok <- validate_identifiers(operation, ~w(source_group_id destination_group_id)),
         {:ok, source} <- fetch_group(operation["source_group_id"]),
         {:ok, destination} <- fetch_group(operation["destination_group_id"]),
         :ok <- validate_revision_field(operation, "expected_revision"),
         :ok <- compare_revision_field(operation, "expected_revision", source),
         :ok <- validate_revision_field(operation, "destination_expected_revision"),
         :ok <-
           compare_revision_field(
             operation,
             "destination_expected_revision",
             destination
           ),
         {:ok, _occurred_on} <- parse_operation_date(operation["occurred_on"]),
         :ok <- validate_transfer_groups(source, destination),
         :ok <- ensure_transfer_group_active(source),
         :ok <- ensure_transfer_group_active(destination),
         :ok <- validate_transfer_amount(operation["amount_cents"]),
         :ok <- validate_transfer_funding(source, operation["amount_cents"]),
         :ok <- validate_transfer_outstanding(destination, operation["amount_cents"]) do
      move_deposit(operation, source, destination)
    else
      {:error, "group_not_found"} ->
        missing_group_id =
          if Repo.get(Group, operation["source_group_id"]),
            do: operation["destination_group_id"],
            else: operation["source_group_id"]

        reject(operation, "group_not_found", %{group_id: missing_group_id})

      {:error, "stale_revision", group, field} ->
        reject(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation[field],
          actual_revision: group.revision
        })

      {:error, "group_not_active", group} ->
        reject(operation, "group_not_active", %{group_id: group.group_id})

      {:error, code} ->
        reject(operation, code)
    end
  end

  defp validate_transfer_groups(source, destination) do
    if source.group_id != destination.group_id and source.guest_id == destination.guest_id,
      do: :ok,
      else: {:error, "invalid_transfer"}
  end

  defp ensure_transfer_group_active(%Group{status: "active"}), do: :ok
  defp ensure_transfer_group_active(group), do: {:error, "group_not_active", group}

  defp validate_transfer_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_transfer_amount(_amount), do: {:error, "invalid_amount"}

  defp validate_transfer_funding(source, amount) do
    if held_funding(source.group_id) >= amount,
      do: :ok,
      else: {:error, "transfer_exceeds_held_funding"}
  end

  defp validate_transfer_outstanding(destination, amount) do
    if outstanding_deposit(destination) >= amount,
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp move_deposit(operation, source, destination) do
    amount = operation["amount_cents"]
    portions = draw_transfer_portions(source.group_id, amount)

    Enum.each(portions, &allocate_transferred_portion(destination.group_id, &1))

    portions
    |> Enum.flat_map(fn
      {:cash, %CashAllocation{payment_operation_id: nil}, _amount} -> []
      {:cash, allocation, _amount} -> [allocation.payment_operation_id]
      {:credit, _allocation, _amount} -> []
    end)
    |> Enum.uniq()
    |> Enum.each(fn payment_operation_id ->
      PaymentAccount
      |> Repo.get!(payment_operation_id)
      |> update!(%{participated_in_transfer: true})
    end)

    revisions = increment_group_revisions([source.group_id, destination.group_id])
    source = Map.fetch!(revisions, source.group_id)
    destination = Map.fetch!(revisions, destination.group_id)

    %{
      operation_id: operation["operation_id"],
      status: "applied",
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding_deposit(source),
      destination_outstanding_deposit_cents: outstanding_deposit(destination),
      source_revision: source.revision,
      destination_revision: destination.revision
    }
  end

  defp fetch_payment_account(payment_operation_id, kind) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      _operation ->
        case Repo.get(PaymentAccount, payment_operation_id) do
          nil -> {:error, payment_error(kind)}
          account -> {:ok, account}
        end
    end
  end

  defp payment_error(:reduce), do: "payment_not_reducible"
  defp payment_error(:charge_back), do: "payment_not_chargeable"

  defp apply_payment_update(operation, group, account, :reduce) do
    amount = operation["amount_cents"]

    cond do
      account.held_cents == 0 ->
        reject(operation, "payment_not_reducible")

      not (is_integer(amount) and amount > 0) ->
        reject(operation, "invalid_amount")

      amount > account.held_cents ->
        reject(operation, "reduction_exceeds_held_cash")

      true ->
        changed_groups = remove_held_allocations(account.payment_operation_id, amount)

        update!(account, %{
          held_cents: account.held_cents - amount,
          reduced_cents: account.reduced_cents + amount
        })

        revisions =
          changed_groups
          |> MapSet.put(group.group_id)
          |> increment_group_revisions()

        group = Map.fetch!(revisions, group.group_id)

        %{
          operation_id: operation["operation_id"],
          status: "applied",
          payment_operation_id: account.payment_operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        }
    end
  end

  defp apply_payment_update(operation, group, account, :charge_back) do
    chargeable = account.recorded_cents - account.reduced_cents

    if chargeable == 0 or account.charged_back_cents > 0 do
      reject(operation, "payment_not_chargeable")
    else
      held_groups = remove_held_allocations(account.payment_operation_id, account.held_cents)
      revoke_credit_entitlements(account.payment_operation_id)
      disposition_groups = reverse_payment_dispositions(account.payment_operation_id)

      update!(account, %{
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: chargeable
      })

      revisions =
        held_groups
        |> MapSet.union(disposition_groups)
        |> MapSet.put(group.group_id)
        |> increment_group_revisions()

      group = Map.fetch!(revisions, group.group_id)

      %{
        operation_id: operation["operation_id"],
        status: "applied",
        payment_operation_id: account.payment_operation_id,
        group_id: group.group_id,
        charged_back_cents: chargeable,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    end
  end

  defp apply_group_update(operation, group, :record_cash_payment) do
    amount = operation["amount_cents"]
    outstanding = outstanding_deposit(group)

    cond do
      match?({:error, _reason}, parse_date(operation["occurred_on"])) ->
        reject(operation, "invalid_operation", %{group_id: group.group_id})

      not (is_integer(amount) and amount > 0) ->
        reject(operation, "invalid_amount", %{group_id: group.group_id})

      amount > outstanding ->
        reject(operation, "payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        allocate_cash(group, operation["operation_id"], amount)

        Repo.insert!(%PaymentAccount{
          payment_operation_id: operation["operation_id"],
          group_id: group.group_id,
          recorded_cents: amount,
          held_cents: amount
        })

        group =
          update!(group, %{
            revision: group.revision + 1
          })

        %{
          operation_id: operation["operation_id"],
          status: "applied",
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        }
    end
  end

  defp apply_group_update(operation, group, :apply_hotel_credit) do
    amount = operation["amount_cents"]
    outstanding = outstanding_deposit(group)

    with {:ok, occurred_on} <- parse_operation_date(operation["occurred_on"]),
         :ok <- validate_payment_amount(amount),
         :ok <- validate_payment_outstanding(amount, outstanding),
         {:ok, lots} <- ensure_sufficient_credit(group.guest_id, occurred_on, amount) do
      allocate_credit(group, lots, amount, operation["operation_id"])

      group =
        update!(group, %{
          revision: group.revision + 1
        })

      %{
        operation_id: operation["operation_id"],
        status: "applied",
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    else
      {:error, code} ->
        reject(operation, code, %{group_id: group.group_id})
    end
  end

  defp apply_group_update(operation, group, :reschedule_group) do
    with {:ok, occurred_on} <- parse_operation_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)

      if new_departure_on.year <= 9999 do
        group =
          update!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          })

        %{
          operation_id: operation["operation_id"],
          status: "applied",
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(group.arrival_on),
          new_departure_on: Date.to_iso8601(group.departure_on),
          policy_version: group.policy_version,
          refundable_until: refundable_until(group),
          revision: group.revision
        }
      else
        reject(operation, "invalid_stay", %{group_id: group.group_id})
      end
    else
      {:error, _reason} -> reject(operation, "invalid_stay", %{group_id: group.group_id})
    end
  end

  defp apply_group_update(operation, group, :cancel_group) do
    rooms = active_rooms(group.group_id)
    settle_rooms(operation, group, rooms, :group)
  end

  defp apply_group_update(operation, group, :cancel_rooms) do
    with {:ok, rooms} <- selected_active_rooms(group.group_id, operation["room_ids"]) do
      settle_rooms(operation, group, rooms, :rooms)
    else
      {:error, code} -> reject(operation, code, %{group_id: group.group_id})
    end
  end

  defp settle_rooms(operation, group, rooms, result_kind) do
    with {:ok, occurred_on} <- parse_operation_date(operation["occurred_on"]),
         {:ok, refund_method} <- validate_refund_method(operation),
         refundable = refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refund_method, refundable) do
      room_ids = Enum.map(rooms, & &1.id)
      cash_allocations = cash_allocations_for_rooms(room_ids)
      cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
      settle_payment_accounts(cash_allocations, group.group_id, refundable, refund_method)
      settle_allocated_credit(room_ids, occurred_on, refundable)

      refunded = if refundable and refund_method == "cash", do: cash, else: 0
      retained = if refundable, do: 0, else: cash
      remaining_rooms = active_room_count(group.group_id) - length(rooms)

      converted =
        if refundable and refund_method == "hotel_credit", do: cash, else: 0

      credit_issued =
        if converted > 0 do
          issued = converted + round_percentage(converted, 10)

          create_credit_lot(
            group.guest_id,
            operation["operation_id"],
            issued,
            Date.add(occurred_on, 365)
          )

          create_credit_entitlements(operation["operation_id"], cash_allocations)

          issued
        else
          0
        end

      Enum.each(rooms, fn room ->
        update!(room, %{
          status: "cancelled",
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      end)

      group =
        update!(group, %{
          status: if(remaining_rooms == 0, do: "cancelled", else: "active"),
          cash_refunded_cents: group.cash_refunded_cents + refunded,
          cash_retained_cents: group.cash_retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
          revision: group.revision + 1
        })

      base = %{
        operation_id: operation["operation_id"],
        status: "applied",
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: credit_issued,
        revision: group.revision
      }

      if result_kind == :rooms do
        Map.put(base, :cancelled_room_ids, Enum.map(rooms, & &1.room_id))
      else
        base
      end
    else
      {:error, code} ->
        reject(operation, code, %{group_id: group.group_id})
    end
  end

  defp validate_structure(operation, required) do
    valid_operation_id =
      is_binary(operation["operation_id"]) and operation["operation_id"] != ""

    all_fields_present = Enum.all?(required, &Map.has_key?(operation, &1))

    if valid_operation_id and all_fields_present,
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp validate_identifiers(operation, fields) do
    if Enum.all?(fields, fn field ->
         is_binary(operation[field]) and operation[field] != ""
       end) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, revision} when is_integer(revision) and revision > 0 -> :ok
      {:ok, _revision} -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_format}

  defp parse_operation_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_operation"}
    end
  end

  defp parse_stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate}
        when is_binary(room_id) and room_id != "" and is_integer(nightly_rate) and
               nightly_rate > 0 and nightly_rate <= @max_sqlite_integer ->
          true

        _room ->
          false
      end)

    if valid do
      room_ids = Enum.map(rooms, & &1["room_id"])

      if length(room_ids) == length(Enum.uniq(room_ids)),
        do: {:ok, rooms},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp ensure_group_is_new(group_id) do
    if Repo.exists?(from group in Group, where: group.group_id == ^group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp calculate_totals(rooms, arrival_on, departure_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    room_amounts =
      Enum.map(rooms, fn room ->
        lodging = nights * room["nightly_rate_cents"]
        deposit = room_deposit(lodging, rate_plan)
        {lodging, deposit}
      end)

    lodging_total = Enum.sum(Enum.map(room_amounts, &elem(&1, 0)))
    deposit_due = Enum.sum(Enum.map(room_amounts, &elem(&1, 1)))

    representable =
      Enum.all?(room_amounts, fn {lodging, deposit} ->
        lodging <= @max_sqlite_integer and deposit <= @max_sqlite_integer
      end) and lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer

    if representable,
      do: {:ok, {lodging_total, deposit_due}},
      else: {:error, "invalid_rooms"}
  end

  defp insert_group(
         operation,
         booked_on,
         arrival_on,
         departure_on,
         rooms,
         lodging_total,
         deposit_due
       ) do
    group = %Group{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      policy_version: policy_version(operation["rate_plan"], booked_on),
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    }

    with {:ok, group} <- Repo.insert(group) do
      room_rows =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          lodging = Date.diff(departure_on, arrival_on) * room["nightly_rate_cents"]

          %{
            group_id: group.group_id,
            position: position,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            lodging_total_cents: lodging,
            deposit_due_cents: room_deposit(lodging, operation["rate_plan"]),
            status: "active",
            cash_paid_cents: 0,
            credit_paid_cents: 0
          }
        end)

      {_count, nil} = Repo.insert_all(Room, room_rows)
      {:ok, group}
    else
      {:error, _changeset} -> {:error, "group_already_exists"}
    end
  end

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp fetch_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp compare_revision(%{"expected_revision" => expected}, group)
       when expected != group.revision,
       do: {:error, "stale_revision", group}

  defp compare_revision(_operation, _group), do: :ok

  defp validate_revision_field(operation, field) do
    case Map.fetch(operation, field) do
      :error -> :ok
      {:ok, revision} when is_integer(revision) and revision > 0 -> :ok
      {:ok, _revision} -> {:error, "invalid_operation"}
    end
  end

  defp compare_revision_field(operation, field, group) do
    case Map.fetch(operation, field) do
      {:ok, expected} when expected != group.revision ->
        {:error, "stale_revision", group, field}

      _revision ->
        :ok
    end
  end

  defp increment_group_revisions(group_ids) do
    group_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(fn group_id ->
      group = Repo.get!(Group, group_id)
      updated = update!(group, %{revision: group.revision + 1})
      {group_id, updated}
    end)
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, "group_not_active"}

  defp ensure_update_allowed(_group, :cancel_rooms), do: :ok
  defp ensure_update_allowed(group, _kind), do: ensure_active(group)

  defp active_rooms(group_id) do
    from(room in Room,
      where: room.group_id == ^group_id and room.status == "active",
      order_by: room.position
    )
    |> Repo.all()
  end

  defp active_room_count(group_id) do
    Repo.aggregate(
      from(room in Room, where: room.group_id == ^group_id and room.status == "active"),
      :count
    )
  end

  defp held_funding(group_id) do
    active_rooms(group_id)
    |> Enum.reduce(0, fn room, total ->
      total + room.cash_paid_cents + room.credit_paid_cents
    end)
  end

  defp selected_active_rooms(group_id, room_ids)
       when is_list(room_ids) and room_ids != [] do
    valid_ids =
      Enum.all?(room_ids, &(is_binary(&1) and &1 != "")) and
        length(room_ids) == length(Enum.uniq(room_ids))

    if valid_ids do
      rooms =
        from(room in Room,
          where:
            room.group_id == ^group_id and room.room_id in ^room_ids and
              room.status == "active",
          order_by: room.position
        )
        |> Repo.all()

      if length(rooms) == length(room_ids),
        do: {:ok, rooms},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp selected_active_rooms(_group_id, _room_ids), do: {:error, "invalid_rooms"}

  defp update!(group, changes) do
    group
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp update_required_fields(:record_cash_payment),
    do: ~w(operation_id occurred_on group_id amount_cents)

  defp update_required_fields(:apply_hotel_credit),
    do: ~w(operation_id occurred_on group_id amount_cents)

  defp update_required_fields(:reschedule_group),
    do: ~w(operation_id occurred_on group_id new_arrival_on)

  defp update_required_fields(:cancel_group), do: ~w(operation_id occurred_on group_id)

  defp update_required_fields(:cancel_rooms),
    do: ~w(operation_id occurred_on group_id room_ids)

  defp outstanding_deposit(%Group{status: "active"} = group) do
    active_rooms(group.group_id)
    |> Enum.reduce(0, fn room, total ->
      total + room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    end)
  end

  defp outstanding_deposit(_group), do: 0

  defp render_group(group) do
    rooms =
      from(room in Room,
        where: room.group_id == ^group.group_id,
        order_by: room.position
      )
      |> Repo.all()

    active = Enum.filter(rooms, &(&1.status == "active"))
    lodging_total = Enum.sum(Enum.map(active, & &1.lodging_total_cents))
    deposit_due = Enum.sum(Enum.map(active, & &1.deposit_due_cents))
    cash_paid = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit_paid = Enum.sum(Enum.map(active, & &1.credit_paid_cents))
    deposit_paid = cash_paid + credit_paid

    rendered_rooms =
      Enum.map(rooms, fn room ->
        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          lodging_total_cents: room.lodging_total_cents,
          status: room.status,
          deposit_due_cents: room.deposit_due_cents,
          cash_paid_cents: room.cash_paid_cents,
          credit_paid_cents: room.credit_paid_cents
        }
      end)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: rendered_rooms,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: deposit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid,
      outstanding_deposit_cents: deposit_due - deposit_paid
    }
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: arrival_on |> Date.add(-14) |> Date.to_iso8601()

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: arrival_on |> Date.add(-30) |> Date.to_iso8601()

  defp refundable_until(_group), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, Date.from_iso8601!(deadline)) != :gt
    end
  end

  defp validate_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _method -> {:error, "invalid_operation"}
    end
  end

  defp ensure_refund_method_available("hotel_credit", false),
    do: {:error, "refund_method_not_available"}

  defp ensure_refund_method_available(_method, _refundable), do: :ok

  defp validate_payment_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_payment_amount(_amount), do: {:error, "invalid_amount"}

  defp validate_payment_outstanding(amount, outstanding) when amount <= outstanding, do: :ok

  defp validate_payment_outstanding(_amount, _outstanding),
    do: {:error, "payment_exceeds_outstanding"}

  defp ensure_sufficient_credit(guest_id, on, amount) do
    lots = available_lots(guest_id, on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount,
      do: {:ok, lots},
      else: {:error, "insufficient_credit"}
  end

  defp available_lots(guest_id, on) do
    on_day = Date.to_gregorian_days(on)

    from(lot in CreditLot,
      where:
        lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
          lot.expires_on_day >= ^on_day,
      order_by: [asc: lot.expires_on_day, asc: lot.source_operation_id, asc: lot.id]
    )
    |> Repo.all()
  end

  defp allocate_cash(group, payment_operation_id, amount) do
    allocate_to_rooms(group.group_id, amount, fn room, used ->
      Repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room.id,
        payment_operation_id: payment_operation_id,
        amount_cents: used,
        allocation_order: next_allocation_order()
      })

      update!(room, %{cash_paid_cents: room.cash_paid_cents + used})
    end)
  end

  defp allocate_credit(group, lots, amount, funding_operation_id) do
    portions =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, portions} ->
        used = min(lot.remaining_cents, remaining)
        update!(lot, %{remaining_cents: lot.remaining_cents - used})
        portions = [{lot, used} | portions]

        case remaining - used do
          0 -> {:halt, {0, Enum.reverse(portions)}}
          rest -> {:cont, {rest, portions}}
        end
      end)
      |> elem(1)

    Enum.each(portions, fn {lot, portion} ->
      allocate_to_rooms(group.group_id, portion, fn room, used ->
        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          room_id: room.id,
          funding_operation_id: funding_operation_id,
          amount_cents: used,
          allocation_order: next_allocation_order()
        })

        update!(room, %{credit_paid_cents: room.credit_paid_cents + used})
      end)
    end)
  end

  defp allocate_to_rooms(group_id, amount, allocate) do
    active_rooms(group_id)
    |> Enum.reduce_while(amount, fn room, remaining ->
      capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      used = min(capacity, remaining)
      if used > 0, do: allocate.(room, used)

      case remaining - used do
        0 -> {:halt, 0}
        rest -> {:cont, rest}
      end
    end)
  end

  defp next_allocation_order do
    Repo.insert!(%DepositAllocationSequence{}).id
  end

  defp draw_transfer_portions(group_id, amount) do
    cash =
      from(allocation in CashAllocation, where: allocation.group_id == ^group_id)
      |> Repo.all()
      |> Enum.map(&{:cash, &1})

    credit =
      from(allocation in CreditAllocation, where: allocation.group_id == ^group_id)
      |> Repo.all()
      |> Enum.map(&{:credit, &1})

    (cash ++ credit)
    |> Enum.sort_by(fn {_kind, allocation} -> allocation.allocation_order end, :desc)
    |> Enum.reduce_while({amount, []}, fn {kind, allocation}, {remaining, portions} ->
      used = min(allocation.amount_cents, remaining)
      remove_transfer_portion(kind, allocation, used)
      portions = [{kind, allocation, used} | portions]

      case remaining - used do
        0 -> {:halt, {0, Enum.reverse(portions)}}
        rest -> {:cont, {rest, portions}}
      end
    end)
    |> elem(1)
  end

  defp remove_transfer_portion(:cash, allocation, amount) do
    room = Repo.get!(Room, allocation.room_id)
    update!(room, %{cash_paid_cents: room.cash_paid_cents - amount})
    shrink_or_delete_allocation(allocation, amount)
  end

  defp remove_transfer_portion(:credit, allocation, amount) do
    room = Repo.get!(Room, allocation.room_id)
    update!(room, %{credit_paid_cents: room.credit_paid_cents - amount})
    shrink_or_delete_allocation(allocation, amount)
  end

  defp shrink_or_delete_allocation(allocation, amount) do
    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      update!(allocation, %{amount_cents: allocation.amount_cents - amount})
    end
  end

  defp allocate_transferred_portion(group_id, {:cash, allocation, amount}) do
    allocate_to_rooms(group_id, amount, fn room, used ->
      Repo.insert!(%CashAllocation{
        group_id: group_id,
        room_id: room.id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: used,
        allocation_order: next_allocation_order()
      })

      update!(room, %{cash_paid_cents: room.cash_paid_cents + used})
    end)
  end

  defp allocate_transferred_portion(group_id, {:credit, allocation, amount}) do
    allocate_to_rooms(group_id, amount, fn room, used ->
      Repo.insert!(%CreditAllocation{
        group_id: group_id,
        credit_lot_id: allocation.credit_lot_id,
        room_id: room.id,
        funding_operation_id: allocation.funding_operation_id,
        amount_cents: used,
        allocation_order: next_allocation_order()
      })

      update!(room, %{credit_paid_cents: room.credit_paid_cents + used})
    end)
  end

  defp settle_allocated_credit(room_ids, occurred_on, refundable) do
    from(allocation in CreditAllocation, where: allocation.room_id in ^room_ids)
    |> Repo.all()
    |> Enum.each(fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable do
        absorbed = absorb_clawback(lot.source_operation_id, allocation.amount_cents)

        restored = allocation.amount_cents - absorbed

        if restored > 0 and lot.expires_on_day >= Date.to_gregorian_days(occurred_on) do
          update!(lot, %{remaining_cents: lot.remaining_cents + restored})
        end
      end

      Repo.delete!(allocation)
    end)
  end

  defp cash_allocations_for_rooms(room_ids) do
    from(allocation in CashAllocation,
      where: allocation.room_id in ^room_ids,
      order_by: allocation.allocation_order
    )
    |> Repo.all()
  end

  defp settle_payment_accounts(allocations, group_id, refundable, refund_method) do
    disposition =
      cond do
        not refundable -> :retained_cents
        refund_method == "hotel_credit" -> :converted_to_credit_cents
        true -> :refunded_cents
      end

    allocations
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id, & &1.amount_cents)
    |> Enum.each(fn {payment_operation_id, amounts} ->
      account = Repo.get!(PaymentAccount, payment_operation_id)
      amount = Enum.sum(amounts)

      changes =
        %{held_cents: account.held_cents - amount}
        |> Map.put(disposition, Map.fetch!(account, disposition) + amount)

      update!(account, changes)
      record_payment_disposition(payment_operation_id, group_id, disposition, amount)
    end)

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp record_payment_disposition(payment_operation_id, group_id, disposition, amount) do
    case Repo.get_by(PaymentDisposition,
           payment_operation_id: payment_operation_id,
           group_id: group_id
         ) do
      nil ->
        fields =
          %{
            payment_operation_id: payment_operation_id,
            group_id: group_id
          }
          |> Map.put(disposition, amount)

        struct(PaymentDisposition, fields) |> Repo.insert!()

      record ->
        update!(record, %{disposition => Map.fetch!(record, disposition) + amount})
    end
  end

  defp reverse_payment_dispositions(payment_operation_id) do
    from(disposition in PaymentDisposition,
      where: disposition.payment_operation_id == ^payment_operation_id
    )
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn disposition, group_ids ->
      group = Repo.get!(Group, disposition.group_id)

      update!(group, %{
        cash_refunded_cents: group.cash_refunded_cents - disposition.refunded_cents,
        cash_retained_cents: group.cash_retained_cents - disposition.retained_cents,
        cash_converted_to_credit_cents:
          group.cash_converted_to_credit_cents - disposition.converted_to_credit_cents
      })

      Repo.delete!(disposition)
      MapSet.put(group_ids, disposition.group_id)
    end)
  end

  defp create_credit_entitlements(source_operation_id, cash_allocations) do
    contributions =
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {payment_operation_id, allocations} ->
        {
          if(is_nil(payment_operation_id), do: 0, else: 1),
          Enum.min(Enum.map(allocations, & &1.allocation_order)),
          payment_operation_id,
          Enum.sum(Enum.map(allocations, & &1.amount_cents))
        }
      end)
      |> Enum.sort_by(fn {seniority, first_order, _payment_operation_id, _amount} ->
        {seniority, first_order}
      end)

    Enum.reduce(contributions, 0, fn {_seniority, _first_order, payment_operation_id, principal},
                                     running ->
      next = running + principal

      if payment_operation_id do
        bonus_value(next)
        |> Kernel.-(bonus_value(running))
        |> split_sqlite_integers()
        |> Enum.each(fn chunk ->
          Repo.insert!(%CreditEntitlement{
            source_operation_id: source_operation_id,
            payment_operation_id: payment_operation_id,
            amount_cents: chunk
          })
        end)
      end

      next
    end)
  end

  defp remove_held_allocations(_payment_operation_id, 0), do: MapSet.new()

  defp remove_held_allocations(payment_operation_id, amount) do
    from(allocation in CashAllocation,
      where: allocation.payment_operation_id == ^payment_operation_id,
      order_by: [desc: allocation.allocation_order]
    )
    |> Repo.all()
    |> Enum.reduce_while({amount, MapSet.new()}, fn allocation, {remaining, group_ids} ->
      used = min(allocation.amount_cents, remaining)
      room = Repo.get!(Room, allocation.room_id)
      update!(room, %{cash_paid_cents: room.cash_paid_cents - used})

      if used == allocation.amount_cents do
        Repo.delete!(allocation)
      else
        update!(allocation, %{amount_cents: allocation.amount_cents - used})
      end

      group_ids = MapSet.put(group_ids, allocation.group_id)

      case remaining - used do
        0 -> {:halt, {0, group_ids}}
        rest -> {:cont, {rest, group_ids}}
      end
    end)
    |> elem(1)
  end

  defp revoke_credit_entitlements(payment_operation_id) do
    from(entitlement in CreditEntitlement,
      where: entitlement.payment_operation_id == ^payment_operation_id
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      removed =
        remove_available_credit(entitlement.source_operation_id, entitlement.amount_cents)

      unrecovered = entitlement.amount_cents - removed

      if unrecovered > 0 do
        Repo.insert!(%CreditClawback{
          source_operation_id: entitlement.source_operation_id,
          amount_cents: unrecovered
        })
      end

      Repo.delete!(entitlement)
    end)
  end

  defp remove_available_credit(source_operation_id, amount) do
    from(lot in CreditLot,
      where: lot.source_operation_id == ^source_operation_id and lot.remaining_cents > 0,
      order_by: lot.id
    )
    |> Repo.all()
    |> Enum.reduce_while({amount, 0}, fn lot, {remaining, removed} ->
      used = min(lot.remaining_cents, remaining)
      update!(lot, %{remaining_cents: lot.remaining_cents - used})

      case remaining - used do
        0 -> {:halt, {0, removed + used}}
        rest -> {:cont, {rest, removed + used}}
      end
    end)
    |> elem(1)
  end

  defp absorb_clawback(source_operation_id, amount) do
    from(clawback in CreditClawback,
      where: clawback.source_operation_id == ^source_operation_id,
      order_by: clawback.id
    )
    |> Repo.all()
    |> Enum.reduce_while({amount, 0}, fn clawback, {remaining, absorbed} ->
      used = min(clawback.amount_cents, remaining)

      if used == clawback.amount_cents do
        Repo.delete!(clawback)
      else
        update!(clawback, %{amount_cents: clawback.amount_cents - used})
      end

      case remaining - used do
        0 -> {:halt, {0, absorbed + used}}
        rest -> {:cont, {rest, absorbed + used}}
      end
    end)
    |> elem(1)
  end

  defp create_credit_lot(guest_id, source_operation_id, amount, expires_on) do
    Repo.insert!(%CreditLotAccount{source_operation_id: source_operation_id})

    amount
    |> split_sqlite_integers()
    |> Enum.each(fn chunk ->
      Repo.insert!(%CreditLot{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: chunk,
        expires_on_day: Date.to_gregorian_days(expires_on)
      })
    end)
  end

  defp split_sqlite_integers(amount) when amount <= @max_sqlite_integer, do: [amount]

  defp split_sqlite_integers(amount),
    do: [@max_sqlite_integer | split_sqlite_integers(amount - @max_sqlite_integer)]

  defp round_percentage(amount, percentage), do: div(amount * percentage + 50, 100)
  defp bonus_value(amount), do: amount + round_percentage(amount, 10)

  defp credit_liability(on) do
    on_day = Date.to_gregorian_days(on)

    available =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on_day >= ^on_day,
        select: lot.remaining_cents
      )
      |> Repo.all()
      |> Enum.sum()

    allocated =
      from(allocation in CreditAllocation, select: allocation.amount_cents)
      |> Repo.all()
      |> Enum.sum()

    available + allocated
  end

  defp credit_shortfall do
    from(clawback in CreditClawback,
      select: {clawback.source_operation_id, clawback.amount_cents}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(0, fn {source_operation_id, chunks}, total ->
      unrecovered = Enum.sum(chunks)

      allocated =
        from(allocation in CreditAllocation,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where: lot.source_operation_id == ^source_operation_id,
          select: allocation.amount_cents
        )
        |> Repo.all()
        |> Enum.sum()

      total + min(unrecovered, allocated)
    end)
  end

  defp render_credit_lots(lots) do
    lots
    |> Enum.chunk_by(&{&1.expires_on_day, &1.source_operation_id})
    |> Enum.map(fn chunks ->
      lot = hd(chunks)

      %{
        source_operation_id: lot.source_operation_id,
        remaining_cents: Enum.sum(Enum.map(chunks, & &1.remaining_cents)),
        expires_on: lot.expires_on_day |> Date.from_gregorian_days() |> Date.to_iso8601()
      }
    end)
  end

  defp parse_expanded_date(value) do
    case Regex.run(~r/^(\d{5,})-(\d{2})-(\d{2})$/, value) do
      [_, year, month, day] ->
        case Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :error
        end

      _match ->
        :error
    end
  end

  defp group_id(operation) do
    case operation["group_id"] do
      group_id when is_binary(group_id) -> %{group_id: group_id}
      _group_id -> %{}
    end
  end

  defp process_operation(operation) do
    case Repo.transaction(fn -> process_operation_in_transaction(operation) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, reason} -> raise "operation transaction failed: #{inspect(reason)}"
    end
  end

  defp process_operation_in_transaction(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        result = operation |> apply_operation() |> normalize_json()

        Repo.insert!(%PartnerOperation{
          operation_id: operation_id,
          operation_type: operation_type(operation),
          submission: operation,
          result: result
        })

        result

      stored_operation ->
        if stored_operation.submission === operation do
          stored_operation.result
        else
          reject(operation, "operation_id_conflict")
        end
    end
  end

  defp process_operation_in_transaction(operation), do: apply_operation(operation)

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp normalize_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp reject(operation, code, extra \\ %{}) do
    %{operation_id: Map.get(operation, "operation_id"), status: "rejected", code: code}
    |> Map.merge(extra)
  end
end
