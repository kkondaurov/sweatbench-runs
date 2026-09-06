defmodule GroupStay.Groups do
  @moduledoc """
  The GroupStay domain: applying partner operations to group reservations and
  reading reservation and finance state.

  Partner operations are applied one at a time, each inside its own
  transaction. An operation either applies fully or is rejected.

  Operations carrying an `operation_id` are made durably idempotent: the first
  submission commits its result together with the idempotency record (handled
  rejections commit the record while leaving domain state unchanged), an
  equivalent retry returns the stored result verbatim, and a conflicting reuse
  of the identifier is rejected without replacing the stored record.
  Operations without an identifier keep the legacy all-or-nothing rollback
  behavior.
  """

  import Ecto.Query

  alias GroupStay.Money
  alias GroupStay.Repo
  alias GroupStay.Groups.{CreditApplication, CreditLot, Group, OperationRecord, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_lifetime_days 365
  @policy_cutover ~D[2027-01-01]

  # --- Applying operations --------------------------------------------------

  @doc """
  Applies every operation in the list, in order, and returns one result per
  operation (applied or rejected) in the same order. A rejected operation
  never stops later operations.
  """
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single operation inside its own transaction. Returns a result map
  with `status` of either `"applied"` or `"rejected"`.

  When the operation carries a string `operation_id`, its first submission is
  remembered durably: the computed result (applied or rejected) commits
  together with the idempotency record. An equivalent retry returns the stored
  result without re-reading or changing domain state; a re-use with a
  different payload is rejected with `operation_id_conflict`. An unexpected
  exception rolls the current operation back and is deliberately not
  remembered.
  """
  def apply_operation(operation) do
    case operation_id(operation) do
      nil -> apply_operation_once(operation)
      op_id -> apply_idempotent(operation, op_id)
    end
  end

  # Legacy processing for operations that do not carry an identifier: applied
  # operations commit, rejected operations roll back entirely.
  defp apply_operation_once(operation) do
    case Repo.transaction(fn ->
           case process(operation) do
             {:applied, result} -> result
             {:rejected, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_idempotent(operation, op_id) do
    outcome =
      Repo.transaction(fn ->
        case Repo.get_by(OperationRecord, operation_id: op_id) do
          nil -> remember(operation, op_id)
          record -> replay_or_conflict(operation, record)
        end
      end)

    case outcome do
      {:ok, result} ->
        result

      # Lost an insert race against the same identifier (or an undeclared
      # constraint fired): try the whole cycle again from a fresh lookup.
      {:error, :retry} ->
        apply_idempotent(operation, op_id)
    end
  end

  defp operation_id(operation) when is_map(operation) do
    case Map.get(operation, "operation_id") do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp operation_id(_operation), do: nil

  # First submission for this identifier: process the operation and commit
  # the idempotency record together with any domain changes. Handled
  # rejections commit only the record; unexpected exceptions roll everything
  # back and are not remembered.
  defp remember(operation, op_id) do
    {status, result} =
      case process(operation) do
        {:applied, result} -> {"applied", result}
        {:rejected, result} -> {"rejected", result}
      end

    changeset =
      OperationRecord.changeset(%{
        operation_id: op_id,
        type: retained_type(operation),
        status: status,
        request: Jason.encode!(operation),
        result: Jason.encode!(result)
      })

    case Repo.insert(changeset) do
      {:ok, _record} -> result
      {:error, _changeset} -> Repo.rollback(:retry)
    end
  rescue
    Ecto.ConstraintError -> Repo.rollback(:retry)
  end

  # The complete submitted content and the stored result are JSON-encoded;
  # decoded maps ignore object key order, so equivalent payloads compare
  # equal while array order and values remain significant.
  defp replay_or_conflict(operation, record) do
    if Jason.decode!(record.request) == operation do
      Jason.decode!(record.result)
    else
      reject_result(operation, "operation_id_conflict")
    end
  end

  # Only a valid binary type is retained; anything else was an invalid
  # operation anyway and has no type to keep.
  defp retained_type(operation) do
    case get_in_map(operation, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp process(%{"type" => type} = operation) when is_binary(type) do
    case type do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      _unknown -> reject(operation, "invalid_operation")
    end
  end

  defp process(operation), do: reject(operation, "invalid_operation")

  # --- open_group -----------------------------------------------------------

  defp open_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- required_date(operation, "departure_on", "invalid_stay"),
         {:ok, rate_plan} <- required_string(operation, "rate_plan"),
         {:ok, rooms} <- required_rooms(operation) do
      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      }

      cond do
        Repo.get_by(Group, group_id: group_id) ->
          reject(operation, "group_already_exists")

        Date.compare(departure_on, arrival_on) != :gt ->
          reject(operation, "invalid_stay")

        not valid_rooms?(rooms) ->
          reject(operation, "invalid_rooms")

        rate_plan not in @rate_plans ->
          reject(operation, "invalid_rate_plan")

        true ->
          apply_open_group(operation, attrs)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_open_group(operation, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    {lodging_total, deposit_due} =
      Enum.reduce(attrs.rooms, {0, 0}, fn room, {lodging_acc, deposit_acc} ->
        room_lodging = room.nightly_rate_cents * nights
        room_deposit = room_deposit(room_lodging, attrs.rate_plan)
        {lodging_acc + room_lodging, deposit_acc + room_deposit}
      end)

    group =
      %Group{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        booked_on: attrs.booked_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        rate_plan: attrs.rate_plan,
        policy_version: policy_version_for(attrs.rate_plan, attrs.booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }
      |> Repo.insert!()

    attrs.rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      %Room{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position
      }
      |> Repo.insert!()
    end)

    apply_result(operation, %{
      group_id: group.group_id,
      deposit_due_cents: group.deposit_due_cents,
      revision: group.revision
    })
  end

  defp room_deposit(lodging_cents, "flexible"),
    do: Money.percent(lodging_cents, @flexible_deposit_percent)

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  # --- Cancellation policy ---------------------------------------------------

  # A group's policy version is fixed when it is opened, from its booking
  # date and rate plan. Rescheduling never moves it to a newer policy.
  defp policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp window_days("flex-14"), do: 14
  defp window_days("flex-30"), do: 30
  defp window_days(_other), do: nil

  # Cancellation on the refundable_until date itself is refundable.
  defp refundable_until(group) do
    case window_days(group.policy_version) do
      nil -> nil
      days -> group.arrival_on |> Date.add(-days) |> Date.to_string()
    end
  end

  # --- record_cash_payment --------------------------------------------------

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      with_group(operation, group_id, fn group ->
        outstanding = group.deposit_due_cents - group.deposit_paid_cents

        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          not usable_amount?(amount) ->
            reject(operation, "invalid_amount")

          amount > outstanding ->
            reject(operation, "payment_exceeds_outstanding")

          true ->
            apply_payment(operation, group, amount)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_payment(operation, group, amount) do
    group
    |> Ecto.Changeset.change(%{
      cash_paid_cents: group.cash_paid_cents + amount,
      deposit_paid_cents: group.deposit_paid_cents + amount,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents - amount,
      revision: group.revision + 1
    })
  end

  # --- reschedule_group -----------------------------------------------------

  defp reschedule_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on", "invalid_stay") do
      with_group(operation, group_id, fn group ->
        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          Date.compare(new_arrival_on, occurred_on) != :gt ->
            reject(operation, "invalid_stay")

          true ->
            apply_reschedule(operation, group, new_arrival_on)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_reschedule(operation, group, new_arrival_on) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, nights)

    group
    |> Ecto.Changeset.change(%{
      arrival_on: new_arrival_on,
      departure_on: new_departure_on,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      new_arrival_on: Date.to_string(new_arrival_on),
      new_departure_on: Date.to_string(new_departure_on),
      policy_version: group.policy_version,
      refundable_until: refundable_until(%{group | arrival_on: new_arrival_on}),
      revision: group.revision + 1
    })
  end

  # --- cancel_group ---------------------------------------------------------

  defp cancel_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation") do
      with_group(operation, group_id, fn group ->
        if group.status != "active" do
          reject(operation, "group_not_active")
        else
          case refund_method(operation) do
            {:ok, method} -> apply_cancel(operation, group, occurred_on, method)
            :error -> reject(operation, "invalid_operation")
          end
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  # `refund_method` is optional; omitting it means cash.
  defp refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _other -> :error
    end
  end

  defp apply_cancel(operation, group, occurred_on, refund_method) do
    window = window_days(group.policy_version)
    refundable? = window != nil and Date.diff(group.arrival_on, occurred_on) >= window

    if refund_method == "hotel_credit" and not refundable? do
      # Hotel credit is not a way around a non-refundable policy.
      reject(operation, "refund_method_not_available")
    else
      settle_cancel(operation, group, occurred_on, refund_method, refundable?)
    end
  end

  defp settle_cancel(operation, group, occurred_on, refund_method, refundable?) do
    cash = group.cash_paid_cents

    {refunded, retained, converted, issued} =
      cond do
        refundable? and refund_method == "hotel_credit" ->
          {0, 0, cash, cash + Money.percent(cash, @credit_bonus_percent)}

        refundable? ->
          {cash, 0, 0, 0}

        true ->
          {0, cash, 0, 0}
      end

    applications = group_applications(group.id)

    if refundable? do
      # Applied credit returns to its original lots with its original expiry.
      Enum.each(applications, &restore_application/1)
    else
      # Applied credit is consumed by a non-refundable cancellation.
      Enum.each(applications, &Repo.delete!/1)
    end

    if refund_method == "hotel_credit" and refundable? and issued > 0 do
      %CreditLot{
        guest_id: group.guest_id,
        source_operation_id: Map.get(operation, "operation_id"),
        available_cents: issued,
        expires_on: Date.add(occurred_on, @credit_lifetime_days)
      }
      |> Repo.insert!()
    end

    group
    |> Ecto.Changeset.change(%{
      status: "cancelled",
      refunded_cents: refunded,
      retained_cents: retained,
      converted_cents: converted,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: group.revision + 1
    })
  end

  defp restore_application(application) do
    Repo.delete!(application)

    lot = Repo.get!(CreditLot, application.lot_id)

    lot
    |> Ecto.Changeset.change(available_cents: lot.available_cents + application.amount_cents)
    |> Repo.update!()
  end

  defp group_applications(group_id) do
    Repo.all(from a in CreditApplication, where: a.group_id == ^group_id)
  end

  # --- apply_hotel_credit ----------------------------------------------------

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      with_group(operation, group_id, fn group ->
        outstanding = group.deposit_due_cents - group.deposit_paid_cents

        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          not usable_amount?(amount) ->
            reject(operation, "invalid_amount")

          amount > outstanding ->
            reject(operation, "payment_exceeds_outstanding")

          true ->
            apply_credit(operation, group, occurred_on, amount)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_credit(operation, group, occurred_on, amount) do
    lots = available_lots(group.guest_id, occurred_on)
    available = Enum.sum(Enum.map(lots, & &1.available_cents))

    if available < amount do
      reject(operation, "insufficient_credit")
    else
      consume_lots(lots, group, amount)

      group
      |> Ecto.Changeset.change(%{
        credit_paid_cents: group.credit_paid_cents + amount,
        deposit_paid_cents: group.deposit_paid_cents + amount,
        revision: group.revision + 1
      })
      |> Repo.update!()

      apply_result(operation, %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents - amount,
        revision: group.revision + 1
      })
    end
  end

  # Consume lots by earliest expiry, then by source_operation_id.
  defp consume_lots(lots, group, amount) do
    {_remaining, taken} =
      Enum.reduce(lots, {amount, []}, fn lot, {remaining, acc} ->
        if remaining <= 0 do
          {remaining, acc}
        else
          take = min(lot.available_cents, remaining)
          {remaining - take, [{lot, take} | acc]}
        end
      end)

    Enum.each(taken, fn {lot, take} ->
      lot
      |> Ecto.Changeset.change(available_cents: lot.available_cents - take)
      |> Repo.update!()

      %CreditApplication{lot_id: lot.id, group_id: group.id, amount_cents: take}
      |> Repo.insert!()
    end)
  end

  # --- Shared operation helpers ---------------------------------------------

  # Resolves an existing group for group-addressed operations, then enforces
  # the optional `expected_revision` precondition before running the domain
  # rule in `fun`.
  defp with_group(operation, group_id, fun) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject(operation, "group_not_found")

      group ->
        case revision_ok?(group, operation) do
          :ok -> fun.(group)
          {:rejected, _result} = rejected -> rejected
        end
    end
  end

  defp revision_ok?(group, operation) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected when is_integer(expected) ->
        if expected == group.revision do
          :ok
        else
          stale_revision(operation, group, expected)
        end

      _other ->
        reject(operation, "invalid_operation")
    end
  end

  # --- Field extraction / validation ----------------------------------------

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp required_value(operation, field) do
    case Map.get(operation, field) do
      nil -> {:error, "invalid_operation"}
      value -> {:ok, value}
    end
  end

  # Missing data makes the operation unidentifiable/unappliable
  # (invalid_operation); data that is present but unusable for the field gets
  # the field-specific code (e.g. invalid_stay for stay dates).
  defp required_date(operation, field, code) do
    case Map.get(operation, field) do
      nil ->
        {:error, "invalid_operation"}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, code}
        end

      _other ->
        {:error, code}
    end
  end

  defp required_rooms(operation) do
    case Map.get(operation, "rooms") do
      rooms when is_list(rooms) ->
        if Enum.all?(rooms, &valid_room?/1) do
          {:ok,
           Enum.map(rooms, fn room ->
             %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
           end)}
        else
          {:error, "invalid_rooms"}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and is_integer(rate) and rate >= 0,
       do: true

  defp valid_room?(_other), do: false

  defp valid_rooms?(rooms) do
    rooms != [] and unique_room_ids?(rooms)
  end

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

  # --- Result builders -------------------------------------------------------

  defp apply_result(operation, extra) do
    {:applied,
     Map.merge(
       %{operation_id: Map.get(operation, "operation_id"), status: "applied"},
       extra
     )}
  end

  defp reject(operation, code, extra \\ %{}) do
    base = %{
      operation_id: get_in_map(operation, "operation_id"),
      status: "rejected",
      code: code,
      group_id: get_in_map(operation, "group_id")
    }

    {:rejected, Map.merge(base, extra)}
  end

  # The rejection map alone, for paths that return a result directly instead
  # of a tagged tuple.
  defp reject_result(operation, code) do
    {:rejected, result} = reject(operation, code)
    result
  end

  defp stale_revision(operation, group, expected) do
    {:rejected,
     %{
       operation_id: Map.get(operation, "operation_id"),
       status: "rejected",
       code: "stale_revision",
       group_id: group.group_id,
       expected_revision: expected,
       actual_revision: group.revision
     }}
  end

  defp get_in_map(operation, key) when is_map(operation), do: Map.get(operation, key)
  defp get_in_map(_operation, _key), do: nil

  # --- Reads -----------------------------------------------------------------

  @doc """
  Returns the stored result for a remembered operation id, or nil. The read
  endpoint exposes only the stored result, not the retained submission.
  """
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> Jason.decode!(record.result)
    end
  end

  def get_operation(_operation_id), do: nil

  @doc "Fetches a group by its partner-supplied id, with rooms in order."
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  @doc "Serializes a group for the partner read endpoint."
  def group_view(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_string(group.booked_on),
      arrival_on: Date.to_string(group.arrival_on),
      departure_on: Date.to_string(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  @doc "Returns the finance totals for the ledger endpoint as of `as_of`."
  def ledger_totals(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: sum_for_status("active", :cash_paid_cents),
      cash_refunded_cents: sum_for_status("cancelled", :refunded_cents),
      cash_retained_cents: sum_for_status("cancelled", :retained_cents),
      cash_converted_to_credit_cents: sum_for_status("cancelled", :converted_cents),
      credit_liability_cents: credit_liability(as_of)
    }
  end

  # Credit liability covers both available credit and credit currently applied
  # to active groups. Expiry and non-refundable consumption reduce it.
  defp credit_liability(as_of) do
    available =
      CreditLot
      |> where([l], l.available_cents > 0 and l.expires_on >= ^as_of)
      |> select([l], coalesce(sum(l.available_cents), 0))
      |> Repo.one()

    applied_to_active =
      CreditApplication
      |> join(:inner, [a], g in Group, on: a.group_id == g.id)
      |> where([a, g], g.status == "active")
      |> select([a, g], coalesce(sum(a.amount_cents), 0))
      |> Repo.one()

    available + applied_to_active
  end

  @doc "Returns a guest's unexpired credit lots and their total as of `as_of`."
  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.available_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.available_cents,
            expires_on: Date.to_string(lot.expires_on)
          }
        end)
    }
  end

  # Unexpired, non-exhausted lots for a guest, in consumption order: earliest
  # expiry first, then source_operation_id.
  defp available_lots(guest_id, as_of) do
    CreditLot
    |> where([l], l.guest_id == ^guest_id and l.available_cents > 0 and l.expires_on >= ^as_of)
    |> order_by([l], asc: l.expires_on, asc: l.source_operation_id)
    |> Repo.all()
  end

  defp sum_for_status(status, field) do
    Group
    |> where([g], g.status == ^status)
    |> select([g], coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end
end
