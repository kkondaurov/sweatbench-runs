defmodule GroupStay.Batches do
  @moduledoc """
  Applies partner batch operations.

  Operations are processed in array order, each in its own database
  transaction, so an operation observes the changes of earlier operations in
  the same batch. A rejected operation leaves the database exactly as it was
  before that operation began and never stops later operations.
  """

  alias GroupStay.Credits
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group
                      apply_hotel_credit)

  # Fields an operation must carry to be identifiable and applicable at all.
  # Missing or wrongly typed values reject the operation as `invalid_operation`.
  @required_string_fields %{
    "open_group" => ~w(group_id guest_id property_id),
    "record_cash_payment" => ~w(group_id),
    "reschedule_group" => ~w(group_id),
    "cancel_group" => ~w(group_id),
    "apply_hotel_credit" => ~w(group_id)
  }

  @required_present_fields %{
    "open_group" => ~w(arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => [],
    "apply_hotel_credit" => ~w(amount_cents)
  }

  @refund_methods ~w(cash hotel_credit)

  # The number of days a credit lot is available after the cancellation that
  # issued it; it expires the following day.
  @credit_available_days 365

  @doc """
  Applies every operation in order and returns one result per operation, in
  the same order.
  """
  def apply_operations(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(operation) do
    case Repo.transaction(fn ->
           case dispatch(operation) do
             {:applied, result} -> result
             {:rejected, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  ## Dispatch and structural validation

  defp dispatch(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp dispatch(operation) do
    operation_id = operation["operation_id"]
    type = operation["type"]

    with :ok <- check_operation_id(operation_id),
         :ok <- check_type(type),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         :ok <- check_required_fields(operation, type),
         :ok <- check_refund_method(operation, type) do
      dispatch_typed(type, operation, occurred_on)
    else
      :error -> rejected(operation_id_if_string(operation_id), "invalid_operation")
    end
  end

  ## Operation types

  defp dispatch_typed("open_group", operation, occurred_on) do
    operation_id = operation["operation_id"]

    with :ok <- check_group_absent(operation["group_id"]),
         {:ok, arrival_on, departure_on} <- fetch_stay(operation),
         {:ok, rooms} <- fetch_rooms(operation["rooms"]),
         :ok <- check_rate_plan(operation["rate_plan"]) do
      apply_open_group(operation, occurred_on, arrival_on, departure_on, rooms)
    else
      {:rejected, code} -> rejected(operation_id, code)
    end
  end

  defp dispatch_typed("record_cash_payment", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]
      amount = operation["amount_cents"]

      with :ok <- check_active(group),
           :ok <- check_amount(group, amount) do
        {:ok, group} =
          group
          |> Group.update_changeset(%{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })
          |> Repo.update()

        Ledger.record_cash_received!(group, amount, occurred_on)

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("apply_hotel_credit", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]
      amount = operation["amount_cents"]

      with :ok <- check_active(group),
           :ok <- check_amount(group, amount),
           :ok <- check_credit_available(group, amount, occurred_on) do
        Credits.apply_to_group!(group, amount, occurred_on)

        {:ok, group} =
          group
          |> Group.update_changeset(%{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            credit_paid_cents: group.credit_paid_cents + amount
          })
          |> Repo.update()

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("reschedule_group", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]

      with :ok <- check_active(group),
           {:ok, new_arrival_on} <- fetch_new_arrival(operation, occurred_on) do
        shift = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.shift(group.departure_on, day: shift)

        {:ok, group} =
          group
          |> Group.update_changeset(%{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on
          })
          |> Repo.update()

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(group.arrival_on),
          new_departure_on: Date.to_iso8601(group.departure_on),
          policy_version: group.policy_version,
          refundable_until: Groups.refundable_until_iso8601(group),
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("cancel_group", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]
      refund_method = Map.get(operation, "refund_method") || "cash"

      with :ok <- check_active(group),
           :ok <- check_refund_method_available(group, refund_method, occurred_on) do
        settle_cancellation(group, operation_id, refund_method, occurred_on)
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  ## Cancellation settlement

  # On a refundable cancellation cash is refunded or, when hotel credit is
  # selected, converted to a credit lot worth 110% of the cash; previously
  # applied credit returns to its original lots without a second bonus. On a
  # non-refundable cancellation cash is retained and applied credit is
  # consumed. Either way the unpaid deposit is no longer due.
  defp settle_cancellation(group, operation_id, refund_method, occurred_on) do
    refundable? = Groups.refundable?(group, occurred_on)
    cash = group.cash_paid_cents

    {refunded_cents, retained_cents, credit_issued_cents} =
      case {refundable?, refund_method} do
        {true, "hotel_credit"} ->
          credit_issued = cash + Groups.round_half_up(cash * 10, 100)

          Ledger.record_cash_converted_to_credit!(group, cash, occurred_on)

          Credits.issue_lot!(
            group.guest_id,
            operation_id,
            credit_issued,
            Date.shift(occurred_on, day: @credit_available_days + 1)
          )

          Credits.restore_applied_credit!(group, occurred_on)

          {0, 0, credit_issued}

        {true, "cash"} ->
          Ledger.record_cash_refunded!(group, cash, occurred_on)
          Credits.restore_applied_credit!(group, occurred_on)

          {cash, 0, 0}

        {false, "cash"} ->
          Ledger.record_cash_retained!(group, cash, occurred_on)
          Credits.consume_applied_credit!(group)

          {0, cash, 0}
      end

    {:ok, group} =
      group
      |> Group.update_changeset(%{status: "cancelled"})
      |> Repo.update()

    applied(operation_id, %{
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents,
      revision: group.revision
    })
  end

  ## Structural validation helpers

  defp check_operation_id(operation_id) when is_binary(operation_id), do: :ok
  defp check_operation_id(_operation_id), do: :error

  defp check_type(type) when type in @operation_types, do: :ok
  defp check_type(_type), do: :error

  defp fetch_occurred_on(operation) do
    case operation["occurred_on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> :error
        end

      _other ->
        :error
    end
  end

  defp check_required_fields(operation, type) do
    string_fields = Map.fetch!(@required_string_fields, type)
    present_fields = Map.fetch!(@required_present_fields, type)

    strings_ok? = Enum.all?(string_fields, &is_binary(operation[&1]))
    present_ok? = Enum.all?(present_fields, &(not is_nil(operation[&1])))

    if strings_ok? and present_ok?, do: :ok, else: :error
  end

  # `refund_method` is optional on `cancel_group`; when present it must be
  # one of the supported methods.
  defp check_refund_method(operation, "cancel_group") do
    case Map.get(operation, "refund_method") do
      nil -> :ok
      method when method in @refund_methods -> :ok
      _other -> :error
    end
  end

  defp check_refund_method(_operation, _type), do: :ok

  defp operation_id_if_string(operation_id) when is_binary(operation_id), do: operation_id
  defp operation_id_if_string(_operation_id), do: nil

  ## Domain validation helpers

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(%Group{}), do: {:rejected, "group_not_active"}

  defp check_amount(_group, amount) when not is_integer(amount) or amount <= 0 do
    {:rejected, "invalid_amount"}
  end

  defp check_amount(%Group{} = group, amount) do
    if amount > Groups.outstanding_deposit_cents(group) do
      {:rejected, "payment_exceeds_outstanding"}
    else
      :ok
    end
  end

  defp check_credit_available(%Group{} = group, amount, %Date{} = occurred_on) do
    if Credits.available_cents(group.guest_id, occurred_on) >= amount do
      :ok
    else
      {:rejected, "insufficient_credit"}
    end
  end

  # Hotel credit is not a way around a non-refundable policy.
  defp check_refund_method_available(%Group{} = group, "hotel_credit", %Date{} = occurred_on) do
    if Groups.refundable?(group, occurred_on) do
      :ok
    else
      {:rejected, "refund_method_not_available"}
    end
  end

  defp check_refund_method_available(%Group{}, _refund_method, %Date{}), do: :ok

  defp fetch_new_arrival(operation, occurred_on) do
    case parse_date(operation["new_arrival_on"]) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:rejected, "invalid_stay"}
        end

      {:error, _} ->
        {:rejected, "invalid_stay"}
    end
  end

  defp check_group_absent(group_id) do
    case Groups.get_group(group_id) do
      nil -> :ok
      %Group{} -> {:rejected, "group_already_exists"}
    end
  end

  defp fetch_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- check_nights(arrival_on, departure_on) do
      {:ok, arrival_on, departure_on}
    else
      _other -> {:rejected, "invalid_stay"}
    end
  end

  defp check_nights(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: :error
  end

  defp fetch_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:rejected, "invalid_rooms"}
    end
  end

  defp fetch_rooms(_rooms), do: {:rejected, "invalid_rooms"}

  defp valid_room?(room) when is_map(room) do
    is_binary(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] > 0
  end

  defp valid_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1["room_id"])
    length(Enum.uniq(room_ids)) == length(room_ids)
  end

  defp check_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"], do: :ok
  defp check_rate_plan(_rate_plan), do: {:rejected, "invalid_rate_plan"}

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_format}

  ## Application helpers

  defp apply_open_group(operation, occurred_on, arrival_on, departure_on, rooms) do
    nights = Date.diff(departure_on, arrival_on)
    totals = Groups.totals(operation["rate_plan"], rooms, nights)

    rooms_with_position =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} -> Map.put(room, :position, position) end)

    attrs = %{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: occurred_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      policy_version: Groups.policy_version(operation["rate_plan"], occurred_on),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      rooms: rooms_with_position
    }

    {:ok, group} =
      Group.open_changeset(attrs)
      |> Repo.insert()

    applied(operation["operation_id"], %{
      group_id: group.group_id,
      deposit_due_cents: group.deposit_due_cents,
      revision: group.revision
    })
  end

  # Resolves the addressed group, then checks the optional expected revision.
  # Existence is resolved first; a stale revision is rejected before any other
  # domain validation.
  defp with_group(operation, fun) do
    operation_id = operation["operation_id"]

    case Groups.get_group(operation["group_id"]) do
      nil ->
        rejected(operation_id, "group_not_found")

      %Group{} = group ->
        case Map.get(operation, "expected_revision") do
          nil ->
            fun.(group)

          expected_revision ->
            if expected_revision == group.revision do
              fun.(group)
            else
              rejected(operation_id, "stale_revision", %{
                group_id: group.group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              })
            end
        end
    end
  end

  defp applied(operation_id, fields) do
    {:applied, Map.merge(%{operation_id: operation_id, status: "applied"}, fields)}
  end

  defp rejected(operation_id, code, fields \\ %{}) do
    {:rejected, Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)}
  end
end
