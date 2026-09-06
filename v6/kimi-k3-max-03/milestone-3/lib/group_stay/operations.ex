defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and reports one result per operation.

  Every operation runs in its own transaction together with its durable
  idempotency record: applied operations commit their domain changes and
  handled rejections commit nothing but the record. The first request for an
  `operation_id` is processed normally; equivalent later submissions replay the
  stored result without touching domain state, and different payloads are
  rejected with `operation_id_conflict`.
  """

  import Ecto.Query

  alias GroupStay.{CanonicalJSON, Groups, Money, Policy, Repo}
  alias GroupStay.Credit.{CreditApplication, CreditLot}
  alias GroupStay.Groups.Group
  alias GroupStay.Operations.OperationRecord

  @deposit_percent 20
  @addressed_types ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group)
  @refund_methods ~w(cash hotel_credit)
  @max_record_attempts 3

  @doc """
  Applies a list of operations sequentially, returning one result per
  operation in the same order.
  """
  def apply_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &apply_operation/1)}
  end

  @doc """
  Fetches the durable record for an operation identifier, or `nil`.
  """
  def get_record(operation_id) do
    Repo.get_by(OperationRecord, operation_id: operation_id)
  end

  @doc """
  Applies a single operation. Returns a result map whose `status` is
  `"applied"` or `"rejected"`. Operations without a usable `operation_id`
  are rejected and remembered nowhere, because there is no key to store.
  """
  def apply_operation(operation) when is_map(operation) do
    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> apply_idempotent(operation, operation_id)
      :error -> dispatch(operation)
    end
  end

  def apply_operation(operation) do
    reject_result(operation, "invalid_operation")
  end

  ## idempotency

  defp apply_idempotent(operation, operation_id) do
    canonical = CanonicalJSON.encode(operation)

    case get_record(operation_id) do
      nil -> process_and_record(operation, operation_id, canonical, 1)
      record -> replay_or_conflict(record, canonical, operation)
    end
  end

  defp replay_or_conflict(record, canonical, operation) do
    if record.payload == canonical do
      Jason.decode!(record.result)
    else
      reject_result(operation, "operation_id_conflict")
    end
  end

  defp process_and_record(operation, operation_id, canonical, attempt) do
    outcome =
      Repo.transaction(fn ->
        result = dispatch(operation)

        case store_record(operation_id, operation["type"], canonical, result) do
          {:ok, _record} ->
            result

          {:error, changeset} ->
            if unique_violation?(changeset) do
              Repo.rollback(:concurrent_record)
            else
              Repo.rollback({:unexpected, changeset})
            end
        end
      end)

    case outcome do
      {:ok, result} ->
        result

      {:error, :concurrent_record} ->
        # A concurrent request recorded this operation first. Replay its
        # stored result or report the payload conflict.
        case get_record(operation_id) do
          nil when attempt < @max_record_attempts ->
            process_and_record(operation, operation_id, canonical, attempt + 1)

          nil ->
            raise "operation record for #{operation_id} vanished after a conflict"

          record ->
            replay_or_conflict(record, canonical, operation)
        end

      {:error, {:unexpected, changeset}} ->
        raise "could not store the idempotency record for #{operation_id}: " <>
                inspect(changeset)
    end
  end

  defp store_record(operation_id, type, canonical, result) do
    %{
      operation_id: operation_id,
      type: type,
      payload: canonical,
      result: Jason.encode!(result)
    }
    |> OperationRecord.changeset()
    |> Repo.insert()
  end

  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {"has already been taken", _}} -> true
      _ -> false
    end)
  end

  ## dispatch

  defp dispatch(operation) when is_map(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, type} <- required_string(operation, "type"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      apply_typed(operation, operation_id, type, occurred_on)
    else
      :error -> reject_result(operation, "invalid_operation")
    end
  end

  defp apply_typed(operation, operation_id, "open_group", occurred_on) do
    open_group(operation, operation_id, occurred_on)
  end

  defp apply_typed(operation, operation_id, type, occurred_on)
       when type in @addressed_types do
    with_addressed_group(operation, operation_id, type, occurred_on)
  end

  defp apply_typed(operation, _operation_id, _unknown_type, _occurred_on) do
    reject_result(operation, "invalid_operation")
  end

  ## open_group

  defp open_group(operation, operation_id, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         :ok <- group_missing?(Groups.get_group(group_id)),
         {:ok, rate_plan} <- valid_rate_plan(operation["rate_plan"]),
         {:ok, arrival_on, departure_on} <- valid_stay(operation),
         {:ok, rooms} <- valid_rooms(operation["rooms"]) do
      create_group(operation, %{
        operation_id: operation_id,
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        rate_plan: rate_plan,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rooms: rooms
      })
    else
      :error -> reject_result(operation, "invalid_operation", operation_id)
      {:reject, code} -> reject_result(operation, code, operation_id)
    end
  end

  defp create_group(operation, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms_attrs =
      attrs.rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"]
        }
      end)

    lodging_total_cents =
      Enum.sum(for room <- attrs.rooms, do: nights * room["nightly_rate_cents"])

    deposit_due_cents =
      case attrs.rate_plan do
        "flexible" ->
          attrs.rooms
          |> Enum.map(&Money.percent_of(nights * &1["nightly_rate_cents"], @deposit_percent))
          |> Enum.sum()

        "advance_purchase" ->
          lodging_total_cents
      end

    {policy_version, _window} = Policy.for_plan(attrs.rate_plan, attrs.booked_on)

    changeset =
      Group.create_changeset(%{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        rate_plan: attrs.rate_plan,
        status: "active",
        booked_on: attrs.booked_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        revision: 1,
        policy_version: policy_version,
        refundable_until: Policy.refundable_until(policy_version, attrs.arrival_on),
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        rooms: rooms_attrs
      })

    case Repo.insert(changeset) do
      {:ok, group} ->
        apply_result(operation, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, _changeset} ->
        reject_result(operation, "invalid_operation", attrs.operation_id)
    end
  end

  ## operations addressed to an existing group

  defp with_addressed_group(operation, operation_id, type, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id") do
      case Groups.get_group(group_id) do
        nil ->
          reject_result(operation, "group_not_found", operation_id)

        group ->
          case revision_ok?(operation, group) do
            :ok ->
              apply_addressed(operation, operation_id, type, occurred_on, group)

            {:error, stale} ->
              reject_result(operation, "stale_revision", operation_id, stale)
          end
      end
    else
      :error -> reject_result(operation, "invalid_operation", operation_id)
    end
  end

  defp revision_ok?(operation, group) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:error,
         %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}
    end
  end

  defp apply_addressed(operation, op_id, "record_cash_payment", _on, group) do
    record_payment(operation, op_id, group)
  end

  defp apply_addressed(operation, op_id, "apply_hotel_credit", occurred_on, group) do
    apply_credit(operation, op_id, occurred_on, group)
  end

  defp apply_addressed(operation, op_id, "reschedule_group", occurred_on, group) do
    reschedule(operation, op_id, occurred_on, group)
  end

  defp apply_addressed(operation, op_id, "cancel_group", occurred_on, group) do
    cancel(operation, op_id, occurred_on, group)
  end

  ## record_cash_payment

  defp record_payment(operation, operation_id, group) do
    cond do
      group.status != "active" ->
        reject_result(operation, "group_not_active", operation_id)

      not usable_amount?(operation["amount_cents"]) ->
        reject_result(operation, "invalid_amount", operation_id)

      operation["amount_cents"] > outstanding(group) ->
        reject_result(operation, "payment_exceeds_outstanding", operation_id)

      true ->
        amount = operation["amount_cents"]

        changeset =
          Group.changeset(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            apply_result(operation, %{
              group_id: updated.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: outstanding(updated),
              revision: updated.revision
            })

          {:error, _changeset} ->
            reject_result(operation, "invalid_operation", operation_id)
        end
    end
  end

  ## apply_hotel_credit

  # Splits credit application into a pure sufficiency check (which may reject
  # before anything is written) followed by the group update; the mutating
  # consumption runs only once the group update succeeded.
  defp apply_credit(operation, operation_id, occurred_on, group) do
    cond do
      group.status != "active" ->
        reject_result(operation, "group_not_active", operation_id)

      not usable_amount?(operation["amount_cents"]) ->
        reject_result(operation, "invalid_amount", operation_id)

      operation["amount_cents"] > outstanding(group) ->
        reject_result(operation, "payment_exceeds_outstanding", operation_id)

      true ->
        amount = operation["amount_cents"]

        case usable_lots(group, occurred_on, amount) do
          :insufficient_credit ->
            reject_result(operation, "insufficient_credit", operation_id)

          {:ok, lots} ->
            changeset =
              Group.changeset(group, %{
                deposit_paid_cents: group.deposit_paid_cents + amount,
                credit_paid_cents: group.credit_paid_cents + amount,
                revision: group.revision + 1
              })

            case Repo.update(changeset) do
              {:ok, updated} ->
                consume_credit_lots(group, lots, amount)

                apply_result(operation, %{
                  group_id: updated.group_id,
                  amount_cents: amount,
                  outstanding_deposit_cents: outstanding(updated),
                  revision: updated.revision
                })

              {:error, _changeset} ->
                reject_result(operation, "invalid_operation", operation_id)
            end
        end
    end
  end

  # Checks that the guest's unexpired lots as of `occurred_on` can cover
  # `amount`. Consumption order is earliest expiry, then
  # `source_operation_id`.
  defp usable_lots(group, occurred_on, amount) do
    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
              l.expires_on >= ^occurred_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      :insufficient_credit
    else
      {:ok, lots}
    end
  end

  # Decrements the lots and records exactly which of them funded the group so
  # the amounts can be restored on a refundable cancellation. Unexpected
  # failures raise, aborting the whole transaction.
  defp consume_credit_lots(group, lots, amount) do
    Enum.reduce(lots, amount, fn lot, needed ->
      take = min(lot.remaining_cents, needed)

      if take > 0 do
        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - take})
        |> Repo.update!()

        %CreditApplication{}
        |> CreditApplication.changeset(%{
          credit_lot_id: lot.id,
          group_id: group.id,
          amount_cents: take
        })
        |> Repo.insert!()
      end

      needed - take
    end)
  end

  ## reschedule_group

  defp reschedule(operation, operation_id, occurred_on, group) do
    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      if group.status == "active" do
        shift_days = Date.diff(new_arrival, group.arrival_on)
        new_departure = Date.add(group.departure_on, shift_days)
        refundable_until = Policy.refundable_until(group.policy_version, new_arrival)

        changeset =
          Group.changeset(group, %{
            arrival_on: new_arrival,
            departure_on: new_departure,
            refundable_until: refundable_until,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            apply_result(operation, %{
              group_id: updated.group_id,
              new_arrival_on: updated.arrival_on,
              new_departure_on: updated.departure_on,
              policy_version: updated.policy_version,
              refundable_until: updated.refundable_until,
              revision: updated.revision
            })

          {:error, _changeset} ->
            reject_result(operation, "invalid_operation", operation_id)
        end
      else
        reject_result(operation, "group_not_active", operation_id)
      end
    else
      _ -> reject_result(operation, "invalid_stay", operation_id)
    end
  end

  ## cancel_group

  defp cancel(operation, operation_id, occurred_on, group) do
    cond do
      group.status != "active" ->
        reject_result(operation, "group_not_active", operation_id)

      not valid_refund_method?(operation["refund_method"]) ->
        reject_result(operation, "invalid_operation", operation_id)

      true ->
        method = operation["refund_method"] || "cash"
        refundable = Policy.refundable?(group, occurred_on)

        if method == "hotel_credit" and not refundable do
          reject_result(operation, "refund_method_not_available", operation_id)
        else
          settle_cancellation(operation, operation_id, occurred_on, group, method, refundable)
        end
    end
  end

  defp valid_refund_method?(nil), do: true
  defp valid_refund_method?(method) when is_binary(method), do: method in @refund_methods
  defp valid_refund_method?(_method), do: false

  defp settle_cancellation(operation, operation_id, occurred_on, group, method, refundable) do
    cash = group.cash_paid_cents

    credit_issued =
      if refundable and method == "hotel_credit" do
        cash + Money.percent_of(cash, 10)
      else
        0
      end

    {refunded, retained, converted} =
      cond do
        not refundable -> {0, cash, 0}
        method == "hotel_credit" -> {0, 0, cash}
        true -> {cash, 0, 0}
      end

    changeset =
      Group.changeset(group, %{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained,
        cash_converted_to_credit_cents: converted,
        revision: group.revision + 1
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        settle_applied_credit(group, occurred_on, refundable)
        maybe_issue_credit_lot(group, operation_id, occurred_on, credit_issued)

        apply_result(operation, %{
          group_id: updated.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: credit_issued,
          revision: updated.revision
        })

      {:error, _changeset} ->
        reject_result(operation, "invalid_operation", operation_id)
    end
  end

  # On a refundable cancellation the applied credit returns to its original
  # lots, unless a lot had already expired on the cancellation date; on a
  # non-refundable cancellation the credit is simply consumed.
  defp settle_applied_credit(group, occurred_on, refundable) do
    applications =
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^group.id,
          preload: :credit_lot
      )

    Enum.each(applications, fn application ->
      lot = application.credit_lot
      restore? = refundable and Date.compare(lot.expires_on, occurred_on) != :lt

      if restore? do
        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents + application.amount_cents})
        |> Repo.update!()
      end

      Repo.delete!(application)
    end)
  end

  defp maybe_issue_credit_lot(_group, _operation_id, _occurred_on, 0), do: :ok

  defp maybe_issue_credit_lot(group, operation_id, occurred_on, credit_issued) do
    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      expires_on: Date.add(occurred_on, 365),
      remaining_cents: credit_issued
    })
    |> Repo.insert!()
  end

  ## validation helpers

  defp group_missing?(nil), do: :ok
  defp group_missing?(_group), do: {:reject, "group_already_exists"}

  defp valid_rate_plan(rate_plan) when rate_plan in ~w(flexible advance_purchase) do
    {:ok, rate_plan}
  end

  defp valid_rate_plan(_rate_plan), do: {:reject, "invalid_rate_plan"}

  defp valid_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.diff(departure_on, arrival_on) >= 1 do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:reject, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &usable_room?/1) and unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      {:reject, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:reject, "invalid_rooms"}

  defp usable_room?(room) when is_map(room) do
    is_binary(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] > 0
  end

  defp usable_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) == length(Enum.uniq(ids))
  end

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp required_string(map, key) when is_map(map) do
    case map do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp required_string(_map, _key), do: :error

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_value), do: :error

  ## result helpers

  defp apply_result(operation, fields) do
    %{status: "applied"}
    |> put_optional(:operation_id, operation["operation_id"])
    |> Map.merge(fields)
  end

  defp reject_result(operation, code, operation_id \\ nil, extra \\ %{}) do
    %{status: "rejected", code: code}
    |> put_optional(:operation_id, operation_id || operation_value(operation, "operation_id"))
    |> Map.merge(extra)
    |> put_optional_group(operation)
  end

  defp operation_value(operation, key) when is_map(operation), do: Map.get(operation, key)
  defp operation_value(_operation, _key), do: nil

  defp put_optional_group(result, operation) do
    if is_map(operation) do
      put_optional(result, :group_id, Map.get(operation, "group_id"))
    else
      result
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
