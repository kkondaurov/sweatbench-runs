defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations (open, fund, move, cancel, reduce, charge back)
  against groups.

  Operations validate before they write, so a rejected operation never changes
  the database. Every applied operation addressed to a group increments its
  revision exactly once; rejections never do.

  Every operation carrying an `operation_id` is durably remembered: a retry
  with an equivalent payload returns the exact original result without
  touching current state, and reusing the identifier with a different payload
  is rejected with `operation_id_conflict`. The idempotency record and the
  domain changes commit in the same transaction.
  """

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Funding
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Money
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @credit_lifetime_days 365

  @doc """
  Handles a single submitted operation and returns its result map.

  The first operation received for an `operation_id` is processed normally and
  remembered together with its domain changes. A later retry with an
  equivalent payload returns the stored result verbatim; a different payload
  under the same identifier is rejected with `operation_id_conflict`.
  Operations without an identifier cannot be remembered and are processed
  directly.
  """
  def submit(op) when is_map(op) do
    case op["operation_id"] do
      operation_id when is_binary(operation_id) ->
        case get_record(operation_id) do
          nil -> apply_and_remember(op, operation_id)
          %OperationRecord{} = record -> replay(record, op)
        end

      _ ->
        apply_operation(op)
    end
  end

  def submit(op), do: apply_operation(op)

  @doc """
  Returns the remembered result for an operation identifier, or `nil`.
  """
  def get_result(operation_id) when is_binary(operation_id) do
    case get_record(operation_id) do
      nil -> nil
      %OperationRecord{} = record -> Jason.decode!(record.result)
    end
  end

  @doc """
  Returns the durable record for an operation identifier, or `nil`.
  """
  def get_record(operation_id) when is_binary(operation_id) do
    Repo.get_by(OperationRecord, operation_id: operation_id)
  end

  def get_record(_), do: nil

  @doc """
  The reconciliation statement of one durably recorded cash payment: the
  current disposition of every recorded cent. Once any of the payment's
  funding has participated in a transfer, the statement also reports where
  its held cash sits. Reading it never changes state.
  """
  def payment_statement(operation_id) when is_binary(operation_id) do
    case get_record(operation_id) do
      nil ->
        nil

      %OperationRecord{} = record ->
        if record.type == "record_cash_payment" and record.status == "applied" do
          payload = Jason.decode!(record.payload)
          result = Jason.decode!(record.result)
          dispositions = Funding.dispositions(operation_id)

          %{
            "payment_operation_id" => operation_id,
            "original_group_id" => payload["group_id"],
            "recorded_cents" => result["amount_cents"],
            "held_cents" => Map.get(dispositions, "held", 0),
            "refunded_cents" => Map.get(dispositions, "refunded", 0),
            "retained_cents" => Map.get(dispositions, "retained", 0),
            "converted_to_credit_cents" => Map.get(dispositions, "converted", 0),
            "reduced_cents" => Map.get(dispositions, "reduced", 0),
            "charged_back_cents" => Map.get(dispositions, "charged_back", 0)
          }
          |> add_held_by_group(operation_id, payload["group_id"])
        else
          :not_reconcilable
        end
    end
  end

  # Once any of the payment's allocations moved to another group, the
  # statement reports the held cash by group, ordered by group identifier.
  # Payments that never moved keep the older statement shape.
  defp add_held_by_group(statement, operation_id, original_group_id) do
    case Groups.get_group(original_group_id) do
      nil ->
        statement

      %Group{id: original_id} ->
        allocations = Funding.allocations(operation_id)

        if Enum.any?(allocations, &(&1.group_id != original_id)) do
          held_by_group =
            allocations
            |> Enum.filter(&(&1.status == "held"))
            |> Enum.group_by(& &1.group_id)
            |> Enum.map(fn {group_id, rows} ->
              {group_id, Enum.sum(Enum.map(rows, & &1.amount_cents))}
            end)
            |> Enum.map(fn {group_id, amount} ->
              %{"group_id" => Repo.get!(Group, group_id).group_id, "amount_cents" => amount}
            end)
            |> Enum.sort_by(& &1["group_id"])

          Map.put(statement, "held_by_group", held_by_group)
        else
          statement
        end
    end
  end

  # Processes the operation and commits its durable record in the same
  # transaction as the domain changes. A handled rejection commits its record
  # too; an unexpected exception rolls everything back and propagates.
  defp apply_and_remember(op, operation_id) do
    case Repo.transaction(fn ->
           result = apply_operation(op)

           %{
             operation_id: operation_id,
             type: op["type"],
             payload: Jason.encode!(op),
             result: Jason.encode!(result),
             status: result["status"]
           }
           |> OperationRecord.changeset()
           |> Repo.insert()
           |> case do
             {:ok, _record} -> result
             {:error, changeset} -> Repo.rollback({:conflict, changeset})
           end
         end) do
      {:ok, result} ->
        result

      {:error, {:conflict, _changeset}} ->
        # A concurrent retry committed first: replay the winner's record. The
        # rolled-back transaction guarantees at-most-once domain effects.
        case get_record(operation_id) do
          nil -> raise "operation record insert conflicted but no record exists"
          %OperationRecord{} = record -> replay(record, op)
        end
    end
  end

  # An equivalent payload replays the stored result without reading or
  # changing current domain state; anything else conflicts with the original
  # record, which is never replaced.
  defp replay(%OperationRecord{} = record, op) do
    if Jason.decode!(record.payload) == op do
      Jason.decode!(record.result)
    else
      reject(op, "operation_id_conflict")
    end
  end

  @doc """
  Applies a single operation and returns its result map.
  """
  def apply_operation(op) when is_map(op) do
    case op["type"] do
      "open_group" -> open_group(op)
      "record_cash_payment" -> record_cash_payment(op)
      "reschedule_group" -> reschedule_group(op)
      "cancel_group" -> cancel_group(op)
      "cancel_rooms" -> cancel_rooms(op)
      "apply_hotel_credit" -> apply_hotel_credit(op)
      "reduce_cash_payment" -> reduce_cash_payment(op)
      "charge_back_payment" -> charge_back_payment(op)
      "transfer_deposit" -> transfer_deposit(op)
      _ -> reject(op, "invalid_operation")
    end
  end

  def apply_operation(op) when not is_map(op) do
    %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
  end

  ## open_group

  defp open_group(op) do
    with :ok <- validate_common(op, ["group_id", "guest_id", "property_id"]),
         :ok <- ensure_group_absent(op["group_id"]),
         {:ok, arrival, departure} <- parse_stay(op["arrival_on"], op["departure_on"]),
         {:ok, rooms} <- validate_rooms(op["rooms"]),
         :ok <- validate_rate_plan(op["rate_plan"]) do
      {:ok, booked_on} = parse_date(op["occurred_on"])
      nights = Date.diff(departure, arrival)
      positioned_rooms = with_positions(rooms, nights, op["rate_plan"])
      lodging_total = Enum.sum(Enum.map(positioned_rooms, & &1["lodging_total_cents"]))
      deposit_due = Enum.sum(Enum.map(positioned_rooms, & &1["deposit_due_cents"]))

      attrs = %{
        "group_id" => op["group_id"],
        "guest_id" => op["guest_id"],
        "property_id" => op["property_id"],
        "rate_plan" => op["rate_plan"],
        "status" => "active",
        "booked_on" => op["occurred_on"],
        "arrival_on" => arrival,
        "departure_on" => departure,
        "policy_version" => Groups.policy_version(op["rate_plan"], booked_on),
        "lodging_total_cents" => lodging_total,
        "deposit_due_cents" => deposit_due
      }

      group =
        Group.open_changeset(attrs, positioned_rooms)
        |> Repo.insert!()

      applied(op, %{
        "group_id" => group.group_id,
        "deposit_due_cents" => deposit_due,
        "revision" => group.revision
      })
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:group_already_exists} -> reject(op, "group_already_exists")
      {:invalid_stay} -> reject(op, "invalid_stay")
      {:invalid_rooms} -> reject(op, "invalid_rooms")
      {:invalid_rate_plan} -> reject(op, "invalid_rate_plan")
    end
  end

  defp ensure_group_absent(group_id) do
    if Groups.get_group(group_id), do: {:group_already_exists}, else: :ok
  end

  # A stay must have at least one night.
  defp parse_stay(arrival, departure) do
    with {:ok, arrival_date} <- parse_date(arrival),
         {:ok, departure_date} <- parse_date(departure),
         true <- Date.compare(departure_date, arrival_date) == :gt do
      {:ok, arrival_date, departure_date}
    else
      _ -> {:invalid_stay}
    end
  end

  # A stay must have at least one room, and each room must be identified and
  # priced. Room identifiers are unique within the group.
  defp validate_rooms(rooms) when is_list(rooms) do
    if rooms != [] and Enum.all?(rooms, &valid_room?/1) and not duplicate_ids?(rooms) do
      {:ok, rooms}
    else
      {:invalid_rooms}
    end
  end

  defp validate_rooms(_), do: {:invalid_rooms}

  defp valid_room?(room) when is_map(room) do
    is_binary(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] >= 0
  end

  defp valid_room?(_), do: false

  defp duplicate_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) != length(Enum.uniq(ids))
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:invalid_rate_plan}
  end

  # Computes each room's lodging and deposit: the nightly rate times the
  # nights, and for flexible rate plans the deposit percentage rounded per
  # room. Advance purchase rooms owe their full lodging amount.
  defp with_positions(rooms, nights, rate_plan) do
    rooms
    |> Enum.with_index()
    |> Enum.map(fn {room, index} ->
      lodging = nights * room["nightly_rate_cents"]

      room
      |> Map.put("position", index)
      |> Map.put("lodging_total_cents", lodging)
      |> Map.put("deposit_due_cents", room_deposit(lodging, rate_plan))
    end)
  end

  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp room_deposit(lodging, "flexible") do
    Money.rounded_percentage(lodging, @flexible_deposit_percent)
  end

  ## record_cash_payment

  defp record_cash_payment(op) do
    with :ok <- validate_common(op, ["group_id"]),
         {:ok, group} <- fetch_group(op),
         :ok <- match_revision(group, op["expected_revision"]),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount) do
      {:ok, updated} =
        Repo.transaction(fn ->
          Funding.fill(group, Groups.active_rooms(group), amount, op["operation_id"])

          group
          |> Group.payment_changeset(amount)
          |> Repo.update!()
        end)

      applied(op, %{
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => Groups.outstanding_deposit(updated),
        "revision" => updated.revision
      })
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found, group_id} -> reject_group(op, "group_not_found", group_id)
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active, group_id} -> reject_group(op, "group_not_active", group_id)
      {:invalid_amount} -> reject(op, "invalid_amount")
      {:payment_exceeds_outstanding} -> reject(op, "payment_exceeds_outstanding")
    end
  end

  defp validate_amount(amount) do
    if is_integer(amount) and amount > 0, do: {:ok, amount}, else: {:invalid_amount}
  end

  defp ensure_within_outstanding(group, amount) do
    if amount <= Groups.outstanding_deposit(group) do
      :ok
    else
      {:payment_exceeds_outstanding}
    end
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(op) do
    with :ok <- validate_common(op, ["group_id"]),
         {:ok, group} <- fetch_group(op),
         :ok <- match_revision(group, op["expected_revision"]),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount),
         :ok <- ensure_sufficient_credit(group, amount, occurred_on!(op)) do
      {:ok, updated} =
        Repo.transaction(fn ->
          Credits.consume(
            group.guest_id,
            amount,
            occurred_on!(op),
            group,
            Groups.active_rooms(group)
          )

          group
          |> Group.credit_changeset(amount)
          |> Repo.update!()
        end)

      applied(op, %{
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => Groups.outstanding_deposit(updated),
        "revision" => updated.revision
      })
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found, group_id} -> reject_group(op, "group_not_found", group_id)
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active, group_id} -> reject_group(op, "group_not_active", group_id)
      {:invalid_amount} -> reject(op, "invalid_amount")
      {:payment_exceeds_outstanding} -> reject(op, "payment_exceeds_outstanding")
      {:insufficient_credit} -> reject(op, "insufficient_credit")
    end
  end

  # Credit application always evaluates expiry using the operation date.
  defp ensure_sufficient_credit(group, amount, occurred_on) do
    if Credits.available_cents(group.guest_id, occurred_on) >= amount do
      :ok
    else
      {:insufficient_credit}
    end
  end

  ## reschedule_group

  defp reschedule_group(op) do
    with :ok <- validate_common(op, ["group_id"]),
         {:ok, group} <- fetch_group(op),
         :ok <- match_revision(group, op["expected_revision"]),
         :ok <- ensure_active(group),
         {:ok, new_arrival} <- parse_new_arrival(op["new_arrival_on"], op["occurred_on"]) do
      shift = Date.diff(new_arrival, group.arrival_on)
      new_departure = Date.add(group.departure_on, shift)

      updated =
        group
        |> Group.reschedule_changeset(new_arrival, new_departure)
        |> Repo.update!()

      applied(op, %{
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_string(updated.arrival_on),
        "new_departure_on" => Date.to_string(updated.departure_on),
        "policy_version" => updated.policy_version,
        "refundable_until" => serialize_date(Groups.refundable_until(updated)),
        "revision" => updated.revision
      })
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found, group_id} -> reject_group(op, "group_not_found", group_id)
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active, group_id} -> reject_group(op, "group_not_active", group_id)
      {:invalid_stay} -> reject(op, "invalid_stay")
    end
  end

  # The new arrival must be after the operation date.
  defp parse_new_arrival(new_arrival, occurred_on) do
    with {:ok, new_arrival_date} <- parse_date(new_arrival),
         {:ok, occurred_date} <- parse_date(occurred_on),
         true <- Date.compare(new_arrival_date, occurred_date) == :gt do
      {:ok, new_arrival_date}
    else
      _ -> {:invalid_stay}
    end
  end

  ## cancel_group

  defp cancel_group(op) do
    with :ok <- validate_common(op, ["group_id"]),
         {:ok, group} <- fetch_group(op),
         :ok <- match_revision(group, op["expected_revision"]),
         :ok <- ensure_active(group),
         {:ok, method} <- refund_method(op["refund_method"]) do
      occurred_on = occurred_on!(op)
      refundable = Groups.refundable?(group, occurred_on)

      if method == :hotel_credit and not refundable do
        # Hotel credit is not a way around a non-refundable policy.
        reject(op, "refund_method_not_available")
      else
        {updated, settlement} =
          settle_rooms(op, group, Groups.active_rooms(group), occurred_on, method, refundable)

        applied(op, %{
          "group_id" => group.group_id,
          "refunded_cents" => settlement.refunded,
          "retained_cents" => settlement.retained,
          "credit_issued_cents" => settlement.credit_issued,
          "revision" => updated.revision
        })
      end
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found, group_id} -> reject_group(op, "group_not_found", group_id)
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active, group_id} -> reject_group(op, "group_not_active", group_id)
    end
  end

  ## cancel_rooms

  defp cancel_rooms(op) do
    with :ok <- validate_common(op, ["group_id"]),
         {:ok, group} <- fetch_group(op),
         :ok <- match_revision(group, op["expected_revision"]),
         :ok <- ensure_active(group),
         {:ok, method} <- refund_method(op["refund_method"]),
         {:ok, rooms} <- select_rooms(group, op["room_ids"]) do
      occurred_on = occurred_on!(op)
      refundable = Groups.refundable?(group, occurred_on)

      if method == :hotel_credit and not refundable do
        reject(op, "refund_method_not_available")
      else
        {updated, settlement} = settle_rooms(op, group, rooms, occurred_on, method, refundable)

        applied(op, %{
          "group_id" => group.group_id,
          "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
          "refunded_cents" => settlement.refunded,
          "retained_cents" => settlement.retained,
          "credit_issued_cents" => settlement.credit_issued,
          "revision" => updated.revision
        })
      end
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found, group_id} -> reject_group(op, "group_not_found", group_id)
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active, group_id} -> reject_group(op, "group_not_active", group_id)
      {:invalid_rooms} -> reject(op, "invalid_rooms")
    end
  end

  # The supplied identifiers must name distinct, active rooms of the group;
  # the rooms are returned in the group's original order.
  defp select_rooms(group, room_ids) when is_list(room_ids) do
    active = Groups.active_rooms(group)

    if room_ids != [] and Enum.all?(room_ids, &is_binary/1) and
         length(room_ids) == length(Enum.uniq(room_ids)) do
      selected = Enum.filter(active, &(&1.room_id in room_ids))

      if length(selected) == length(room_ids) do
        {:ok, selected}
      else
        {:invalid_rooms}
      end
    else
      {:invalid_rooms}
    end
  end

  defp select_rooms(_group, _room_ids), do: {:invalid_rooms}

  # Omitting the refund method means cash, preserving existing callers.
  defp refund_method(nil), do: {:ok, :cash}
  defp refund_method("cash"), do: {:ok, :cash}
  defp refund_method("hotel_credit"), do: {:ok, :hotel_credit}
  defp refund_method(_), do: {:invalid_operation}

  # Settles the given rooms' allocated cash and credit under the group's
  # policy: refundable cash settlements refund, refundable credit settlements
  # convert the cash into one bonus credit lot, and non-refundable settlements
  # retain the cash. Applied credit returns to its lots on a refundable
  # cancellation and is consumed on a non-refundable one. The group is
  # cancelled when no active rooms remain.
  defp settle_rooms(op, group, rooms, occurred_on, method, refundable) do
    {:ok, {updated, settlement}} =
      Repo.transaction(fn ->
        cash = held_cash(rooms)
        settlement = settlement_amounts(cash, refundable, method)

        settled = Funding.settle(rooms, settlement.cash_status)
        settle_credit(rooms, refundable)
        Enum.each(rooms, &cancel_room!/1)

        if settlement.credit_issued > 0 do
          Credits.create_lot(
            %{
              guest_id: group.guest_id,
              source_operation_id: op["operation_id"],
              amount_cents: settlement.credit_issued,
              expires_on: Date.add(occurred_on, @credit_lifetime_days)
            },
            contributions(settled)
          )
        end

        cancelled? = Groups.active_rooms(group) == []
        credit = settled_credit(rooms)

        updated =
          group
          |> Group.settle_changeset(%{
            paid_cents: cash + credit,
            cash_cents: cash,
            credit_cents: credit,
            refunded_cents: settlement.refunded,
            retained_cents: settlement.retained,
            converted_cents: settlement.converted,
            cancelled?: cancelled?
          })
          |> Repo.update!()

        {updated, settlement}
      end)

    {updated, settlement}
  end

  defp held_cash(rooms) do
    rooms
    |> Enum.map(& &1.cash_paid_cents)
    |> Enum.sum()
  end

  defp settled_credit(rooms) do
    rooms
    |> Enum.map(& &1.credit_paid_cents)
    |> Enum.sum()
  end

  defp settlement_amounts(cash, refundable, method) do
    case {refundable, method} do
      {true, :cash} ->
        %{
          refunded: cash,
          retained: 0,
          converted: 0,
          credit_issued: 0,
          cash_status: "refunded"
        }

      {true, :hotel_credit} ->
        %{
          refunded: 0,
          retained: 0,
          converted: cash,
          credit_issued: Money.credit_value(cash),
          cash_status: "converted"
        }

      {false, :cash} ->
        %{
          refunded: 0,
          retained: cash,
          converted: 0,
          credit_issued: 0,
          cash_status: "retained"
        }
    end
  end

  defp settle_credit(rooms, refundable) do
    applications = Credits.applications_on_rooms(rooms)

    if refundable do
      Credits.restore_applications(applications)
    else
      Credits.consume_applications(applications)
    end
  end

  defp cancel_room!(room) do
    room
    |> Ecto.Changeset.change(status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0)
    |> Repo.update!()
  end

  # The payments whose cash is being converted into a credit lot, in the
  # funding order used by room accounting: the unattributed senior block
  # first, then durable records in commit order.
  defp contributions(settled_allocations) do
    by_payment =
      settled_allocations
      |> Enum.filter(&(&1.status == "converted"))
      |> Enum.group_by(& &1.payment_operation_id)

    operation_ids =
      by_payment |> Map.keys() |> Enum.reject(&is_nil/1)

    commit_order =
      from(r in OperationRecord,
        where: r.operation_id in ^operation_ids,
        select: {r.operation_id, r.id}
      )
      |> Repo.all()
      |> Map.new()

    by_payment
    |> Enum.map(fn {payment_operation_id, allocations} ->
      {payment_operation_id, Enum.sum(Enum.map(allocations, & &1.amount_cents))}
    end)
    |> Enum.sort_by(fn {payment_operation_id, _cash} ->
      case payment_operation_id do
        nil -> {0, 0}
        operation_id -> {1, Map.fetch!(commit_order, operation_id)}
      end
    end)
  end

  ## transfer_deposit

  # Source existence resolves first, then destination, then both revision
  # guards, then the transfer rules. Every rejection names the group it
  # concerns; an applied transfer increments both groups' revisions.
  defp transfer_deposit(op) do
    with :ok <- validate_common(op, ["source_group_id", "destination_group_id"]),
         {:ok, source} <- fetch_group(op, "source_group_id"),
         {:ok, destination} <- fetch_group(op, "destination_group_id"),
         :ok <- match_revision(source, op["expected_revision"]),
         :ok <- match_revision(destination, op["destination_expected_revision"]),
         :ok <- ensure_transferable(source, destination),
         :ok <- ensure_active(source),
         :ok <- ensure_active(destination),
         {:ok, amount} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_held(source, amount),
         :ok <- ensure_transfer_outstanding(destination, amount) do
      {:ok, {updated_source, updated_destination}} =
        Repo.transaction(fn ->
          {cash, credit} =
            Funding.transfer(
              source,
              destination,
              Groups.active_rooms(destination),
              amount
            )

          updated_source =
            source
            |> Group.transfer_changeset(-cash, -credit)
            |> Repo.update!()

          updated_destination =
            destination
            |> Group.transfer_changeset(cash, credit)
            |> Repo.update!()

          {updated_source, updated_destination}
        end)

      applied(op, %{
        "source_group_id" => source.group_id,
        "destination_group_id" => destination.group_id,
        "amount_cents" => amount,
        "source_outstanding_deposit_cents" => Groups.outstanding_deposit(updated_source),
        "destination_outstanding_deposit_cents" =>
          Groups.outstanding_deposit(updated_destination),
        "source_revision" => updated_source.revision,
        "destination_revision" => updated_destination.revision
      })
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found, group_id} -> reject_group(op, "group_not_found", group_id)
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:invalid_transfer} -> reject(op, "invalid_transfer")
      {:group_not_active, group_id} -> reject_group(op, "group_not_active", group_id)
      {:invalid_amount} -> reject(op, "invalid_amount")
      {:transfer_exceeds_held_funding} -> reject(op, "transfer_exceeds_held_funding")
      {:transfer_exceeds_outstanding} -> reject(op, "transfer_exceeds_outstanding")
    end
  end

  # A transfer requires two distinct active groups belonging to one guest.
  defp ensure_transferable(source, destination) do
    if source.group_id != destination.group_id and source.guest_id == destination.guest_id do
      :ok
    else
      {:invalid_transfer}
    end
  end

  # Held funding is what the group's active rooms currently carry.
  defp ensure_within_held(source, amount) do
    if amount <= Groups.totals(source).deposit_paid_cents do
      :ok
    else
      {:transfer_exceeds_held_funding}
    end
  end

  defp ensure_transfer_outstanding(destination, amount) do
    if amount <= Groups.outstanding_deposit(destination) do
      :ok
    else
      {:transfer_exceeds_outstanding}
    end
  end

  ## reduce_cash_payment

  defp reduce_cash_payment(op) do
    with :ok <- validate_common(op, ["payment_operation_id"]),
         {:ok, record} <- fetch_record(op["payment_operation_id"]),
         {:ok, group} <- fetch_payment_group(record),
         :ok <- match_revision(group, op["expected_revision"]),
         {:ok, held} <- ensure_reducible(record, group),
         {:ok, amount} <- validate_amount(op["amount_cents"], group),
         :ok <- ensure_within_held(held, amount, group) do
      {:ok, updated} =
        Repo.transaction(fn ->
          removed_by_group = Funding.reduce(record.operation_id, amount)
          bump_other_groups!(removed_by_group, group)

          group
          |> Group.reopen_changeset(Map.get(removed_by_group, group.id, 0))
          |> Repo.update!()
        end)

      applied(op, %{
        "payment_operation_id" => record.operation_id,
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => Groups.outstanding_deposit(updated),
        "revision" => updated.revision
      })
    else
      {:invalid_operation} ->
        reject(op, "invalid_operation")

      {:operation_not_found} ->
        reject(op, "operation_not_found")

      {:stale, group, expected} ->
        reject_stale(op, group, expected)

      {:payment_not_reducible, group} ->
        reject_derived(op, "payment_not_reducible", group)

      {:invalid_amount, group} ->
        reject_derived(op, "invalid_amount", group)

      {:reduction_exceeds_held_cash, group} ->
        reject_derived(op, "reduction_exceeds_held_cash", group)
    end
  end

  # The target can never accept a positive reduction when it is not an
  # applied cash payment or has no held cash remaining.
  defp ensure_reducible(record, group) do
    case ensure_payment_record(record) do
      :ok ->
        case Map.get(Funding.dispositions(record.operation_id), "held", 0) do
          0 -> {:payment_not_reducible, group}
          held -> {:ok, held}
        end

      {:not_a_payment} ->
        {:payment_not_reducible, group}
    end
  end

  defp validate_amount(amount, group) do
    case validate_amount(amount) do
      {:ok, amount} -> {:ok, amount}
      {:invalid_amount} -> {:invalid_amount, group}
    end
  end

  defp ensure_within_held(held, amount, group) do
    if amount <= held, do: :ok, else: {:reduction_exceeds_held_cash, group}
  end

  ## charge_back_payment

  defp charge_back_payment(op) do
    with :ok <- validate_common(op, ["payment_operation_id"]),
         {:ok, record} <- fetch_record(op["payment_operation_id"]),
         {:ok, group} <- fetch_payment_group(record),
         :ok <- match_revision(group, op["expected_revision"]),
         :ok <- ensure_chargeable(record, group) do
      {:ok, {updated, charged_back}} =
        Repo.transaction(fn ->
          {charged_back, held_by_group} = Funding.charge_back(record.operation_id)
          Credits.clawback_entitlements(record.operation_id)
          bump_other_groups!(held_by_group, group)

          updated =
            group
            |> Group.reopen_changeset(Map.get(held_by_group, group.id, 0))
            |> Repo.update!()

          {updated, charged_back}
        end)

      applied(op, %{
        "payment_operation_id" => record.operation_id,
        "group_id" => group.group_id,
        "charged_back_cents" => charged_back,
        "outstanding_deposit_cents" => Groups.outstanding_deposit(updated),
        "revision" => updated.revision
      })
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:operation_not_found} -> reject(op, "operation_not_found")
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:payment_not_chargeable, group} -> reject_derived(op, "payment_not_chargeable", group)
    end
  end

  # Chargeable means an applied cash payment with cash still outside the
  # reduced and charged-back dispositions: a fully reduced payment and an
  # already charged-back one have nothing left to move.
  defp ensure_chargeable(record, group) do
    case ensure_payment_record(record) do
      :ok ->
        movable =
          record.operation_id
          |> Funding.dispositions()
          |> Map.take(~w(held refunded retained converted))
          |> Enum.reduce(0, fn {_status, amount}, total -> total + amount end)

        if movable > 0, do: :ok, else: {:payment_not_chargeable, group}

      {:not_a_payment} ->
        {:payment_not_chargeable, group}
    end
  end

  defp ensure_payment_record(record) do
    if record.type == "record_cash_payment" and record.status == "applied" do
      :ok
    else
      {:not_a_payment}
    end
  end

  ## payment-targeted operation helpers

  # An applied operation increments the revision of every group whose state
  # it changes. The operation's addressed group is still incremented by its
  # own changeset, so it is excluded here.
  defp bump_other_groups!(removed_by_group, addressed_group) do
    removed_by_group
    |> Map.delete(addressed_group.id)
    |> Enum.each(fn {group_id, removed} ->
      Repo.get!(Group, group_id)
      |> Group.reopen_changeset(removed)
      |> Repo.update!()
    end)
  end

  defp fetch_record(operation_id) do
    case get_record(operation_id) do
      nil -> {:operation_not_found}
      %OperationRecord{} = record -> {:ok, record}
    end
  end

  # The group a payment-targeted operation addresses is the original
  # payment's group. It can only be missing when the stored operation was
  # rejected (an applied payment's group always exists), and such targets are
  # never reducible or chargeable.
  defp fetch_payment_group(record) do
    payload = Jason.decode!(record.payload)
    {:ok, Groups.get_group(payload["group_id"])}
  end

  ## shared helpers

  # Ensures the operation carries the data needed to identify and apply it.
  defp validate_common(op, required_ids) do
    common? =
      is_binary(op["operation_id"]) and is_binary(op["type"]) and
        match?({:ok, _}, parse_date(op["occurred_on"]))

    ids? = Enum.all?(required_ids, &is_binary(op[&1]))

    if common? and ids?, do: :ok, else: {:invalid_operation}
  end

  defp fetch_group(op), do: fetch_group(op, "group_id")

  defp fetch_group(op, key) do
    case Groups.get_group(op[key]) do
      nil -> {:not_found, op[key]}
      %Group{} = group -> {:ok, group}
    end
  end

  # Group existence is resolved before revisions are compared, so this check
  # always runs against a fetched group. A payment-targeted operation whose
  # group is missing has no revision to compare. The guard accepts the value
  # under the operation's `expected_revision`-style field.
  defp match_revision(group, expected) do
    if is_nil(group) or is_nil(expected) or expected == group.revision do
      :ok
    else
      {:stale, group, expected}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{} = group), do: {:group_not_active, group.group_id}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  # Only safe after validate_common accepted the operation.
  defp occurred_on!(op), do: Date.from_iso8601!(op["occurred_on"])

  defp serialize_date(nil), do: nil
  defp serialize_date(%Date{} = date), do: Date.to_string(date)

  defp applied(op, extra) do
    op
    |> base_result("applied")
    |> Map.merge(extra)
  end

  defp reject(op, code) when is_binary(code) do
    op
    |> base_result("rejected")
    |> Map.put("code", code)
  end

  # A rejection naming the group it concerns, when the operation's own fields
  # do not carry it (transfers address two groups through custom keys).
  defp reject_group(op, code, nil), do: reject(op, code)

  defp reject_group(op, code, group_id) do
    op
    |> reject(code)
    |> Map.put("group_id", group_id)
  end

  # A rejection of an operation whose group is derived from a payment record
  # rather than supplied directly.
  defp reject_derived(op, code, nil), do: reject(op, code)

  defp reject_derived(op, code, group) do
    op
    |> reject(code)
    |> Map.put("group_id", group.group_id)
  end

  defp reject_stale(op, group, expected) do
    op
    |> base_result("rejected")
    |> Map.merge(%{
      "code" => "stale_revision",
      "group_id" => group.group_id,
      "expected_revision" => expected,
      "actual_revision" => group.revision
    })
  end

  defp base_result(op, status) do
    base = %{"operation_id" => op["operation_id"], "status" => status}

    if group_id = op["group_id"] do
      Map.put(base, "group_id", group_id)
    else
      base
    end
  end
end
