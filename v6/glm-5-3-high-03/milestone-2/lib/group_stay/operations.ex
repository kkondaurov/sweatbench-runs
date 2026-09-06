defmodule GroupStay.Operations do
  @moduledoc """
  Applies the operations of a partner batch, in order, and builds the outcome
  reported for each one.

  Each operation is validated before anything is written, so a rejected
  operation always leaves the database exactly as it was before that
  operation began, and processing continues with the next operation.

  Ordering rules shared by every operation addressed to an existing group:

    * group existence is resolved first (`group_not_found`);
    * an `expected_revision` mismatch is rejected next (`stale_revision`);
    * an inactive group is rejected after that (`group_not_active`);
    * only then are the operation's own domain rules evaluated.

  Rejected operations never increment the group's revision. Every applied
  operation addressed to an existing group increments the revision exactly
  once, even when it does not change the group's visible booking fields.

  Cancellation policy versions are fixed when a group is opened: a flexible
  group booked before 2027-01-01 keeps a 14-day cancellation window, one
  booked on or after 2027-01-01 uses a 30-day window, and advance purchase
  remains non-refundable. A refundable cancellation settles the cash portion
  as a cash refund, or as hotel credit worth 110% of that cash when
  `refund_method` is `hotel_credit`. Credit applied to a group is redeemed
  into its deposit and restored to its original lots on a refundable
  cancellation.
  """

  import Ecto.Changeset

  alias GroupStay.Credits
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)
  @flexible_deposit_percent 20

  @doc """
  Runs every operation in the batch, in array order, and returns one result
  per operation in the same order. An operation observes the changes made by
  earlier operations in the same batch.
  """
  @spec run([map()]) :: [map()]
  def run(operations) when is_list(operations) do
    Enum.map(operations, &process/1)
  end

  defp process(operation) when is_map(operation) do
    case identify(operation) do
      {:ok, ctx} -> dispatch(ctx)
      {:error, code} -> reject(operation, code)
    end
  end

  defp process(operation) do
    reject(operation, "invalid_operation")
  end

  # Identification: the common fields every operation needs before its type
  # specific rules can even be evaluated.

  defp identify(operation) do
    with {:ok, operation_id} <- identify_string(operation["operation_id"]),
         {:ok, type} <- identify_type(operation["type"]),
         {:ok, occurred_on} <- identify_date(operation["occurred_on"]),
         {:ok, group_id} <- identify_string(operation["group_id"]) do
      {:ok,
       %{
         operation: operation,
         operation_id: operation_id,
         type: type,
         occurred_on: occurred_on,
         group_id: group_id
       }}
    end
  end

  defp identify_string(value) when is_binary(value), do: {:ok, value}
  defp identify_string(_), do: {:error, "invalid_operation"}

  defp identify_type(type) when type in @operation_types, do: {:ok, type}
  defp identify_type(_), do: {:error, "invalid_operation"}

  defp identify_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_operation"}
    end
  end

  defp identify_date(_), do: {:error, "invalid_operation"}

  defp dispatch(%{type: "open_group"} = ctx), do: open_group(ctx)
  defp dispatch(%{type: "record_cash_payment"} = ctx), do: record_cash_payment(ctx)
  defp dispatch(%{type: "reschedule_group"} = ctx), do: reschedule_group(ctx)
  defp dispatch(%{type: "cancel_group"} = ctx), do: cancel_group(ctx)
  defp dispatch(%{type: "apply_hotel_credit"} = ctx), do: apply_hotel_credit(ctx)

  ## open_group

  defp open_group(ctx) do
    operation = ctx.operation

    with :ok <- require_group_absent(ctx.group_id),
         {:ok, guest_id} <- require_string(operation["guest_id"]),
         {:ok, property_id} <- require_string(operation["property_id"]),
         {:ok, arrival_on} <- stay_date(operation["arrival_on"]),
         {:ok, departure_on} <- stay_date(operation["departure_on"]),
         :ok <- ensure_at_least_one_night(arrival_on, departure_on),
         {:ok, rooms} <- parse_rooms(operation["rooms"]),
         {:ok, rate_plan} <- parse_rate_plan(operation["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)

      lodging_total_cents = nights * Enum.sum(Enum.map(rooms, & &1.nightly_rate_cents))

      deposit_due_cents =
        rooms
        |> Enum.map(&room_deposit_cents(&1, nights, rate_plan))
        |> Enum.sum()

      group =
        %Group{}
        |> change(%{
          group_id: ctx.group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: ctx.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          credit_paid_cents: 0,
          converted_to_credit_cents: 0,
          refunded_cents: 0,
          retained_cents: 0
        })
        |> put_assoc(:rooms, rooms)
        |> Repo.insert!()

      applied(ctx, %{
        "group_id" => group.group_id,
        "deposit_due_cents" => group.deposit_due_cents,
        "revision" => group.revision
      })
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp require_group_absent(group_id) do
    if Groups.group_exists?(group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp require_string(value) when is_binary(value), do: {:ok, value}
  defp require_string(_), do: {:error, "invalid_operation"}

  # Dates that are present but unusable are stay problems; the stay rules are
  # evaluated as domain validation.
  defp stay_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_stay"}
    end
  end

  defp stay_date(_), do: {:error, "invalid_stay"}

  defp ensure_at_least_one_night(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp parse_rooms(value) when is_list(value) do
    case Enum.reduce_while(value, {:ok, []}, fn raw, {:ok, acc} ->
           case parse_room(raw, length(acc)) do
             {:ok, room} -> {:cont, {:ok, [room | acc]}}
             :error -> {:halt, :error}
           end
         end) do
      {:ok, rooms} ->
        rooms = Enum.reverse(rooms)
        room_ids = Enum.map(rooms, & &1.room_id)

        cond do
          rooms == [] -> {:error, "invalid_rooms"}
          room_ids != Enum.uniq(room_ids) -> {:error, "invalid_rooms"}
          true -> {:ok, rooms}
        end

      :error ->
        {:error, "invalid_rooms"}
    end
  end

  defp parse_rooms(_), do: {:error, "invalid_rooms"}

  defp parse_room(raw, position) when is_map(raw) do
    room_id = raw["room_id"]
    nightly_rate_cents = raw["nightly_rate_cents"]

    if is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents >= 0 do
      {:ok, %Room{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
    else
      :error
    end
  end

  defp parse_room(_, _), do: :error

  defp parse_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp parse_rate_plan(_), do: {:error, "invalid_rate_plan"}

  # The deposit of each room is calculated and rounded separately, then the
  # room deposits are summed for the group.
  defp room_deposit_cents(room, nights, "flexible") do
    lodging_cents = room.nightly_rate_cents * nights
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp room_deposit_cents(room, nights, "advance_purchase") do
    room.nightly_rate_cents * nights
  end

  # Rounds numerator / denominator to the nearest cent; an exact half-cent
  # rounds upward. Integer arithmetic keeps the rounding exact.
  defp round_half_up(numerator, denominator) do
    div(2 * numerator + denominator, 2 * denominator)
  end

  ## record_cash_payment

  defp record_cash_payment(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_amount(operation["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      outstanding_cents = Groups.outstanding_deposit_cents(group)

      group
      |> change(%{
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

      applied(ctx, %{
        "group_id" => group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => outstanding_cents - amount_cents,
        "revision" => group.revision + 1
      })
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  defp parse_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp parse_amount(_), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  ## reschedule_group

  defp reschedule_group(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- stay_date(operation["new_arrival_on"]),
         :ok <- ensure_after_operation_date(new_arrival_on, ctx.occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      updated_group =
        group
        |> change(%{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(ctx, %{
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival_on),
        "new_departure_on" => Date.to_iso8601(new_departure_on),
        "policy_version" => Groups.policy_version(updated_group),
        "refundable_until" => updated_group |> Groups.refundable_until() |> iso_date(),
        "revision" => updated_group.revision
      })
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  defp ensure_after_operation_date(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  ## cancel_group

  defp cancel_group(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- parse_refund_method(operation["refund_method"]) do
      cond do
        Groups.refundable?(group, ctx.occurred_on) ->
          refundable_cancellation(ctx, group, refund_method)

        refund_method == "hotel_credit" ->
          # Hotel credit is not a way around a non-refundable policy.
          reject(operation, "refund_method_not_available")

        true ->
          non_refundable_cancellation(ctx, group)
      end
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  # Omitting refund_method means cash, preserving existing callers.
  defp parse_refund_method(nil), do: {:ok, "cash"}

  defp parse_refund_method(refund_method) when refund_method in @refund_methods,
    do: {:ok, refund_method}

  defp parse_refund_method(_), do: {:error, "invalid_operation"}

  # A refundable cancellation settles the cash portion as a cash refund or,
  # when hotel credit is selected, as a new credit lot worth 110% of that
  # cash. Credit previously applied to the group returns to its original lots
  # and never receives a second bonus.
  defp refundable_cancellation(ctx, group, refund_method) do
    cash_cents = Groups.cash_paid_cents(group)

    refunded_cents = if refund_method == "cash", do: cash_cents, else: 0

    Repo.transaction(fn ->
      {converted_cents, credit_issued_cents} =
        if refund_method == "hotel_credit" and cash_cents > 0 do
          lot = Credits.issue_lot(group.guest_id, ctx.operation_id, cash_cents, ctx.occurred_on)
          {cash_cents, lot.remaining_cents}
        else
          {0, 0}
        end

      Credits.restore_group_credit(group, ctx.occurred_on)

      group
      |> change(%{
        status: "cancelled",
        deposit_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: refunded_cents,
        retained_cents: 0,
        converted_to_credit_cents: group.converted_to_credit_cents + converted_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

      credit_issued_cents
    end)
    |> case do
      {:ok, credit_issued_cents} ->
        applied(ctx, %{
          "group_id" => group.group_id,
          "refunded_cents" => refunded_cents,
          "retained_cents" => 0,
          "credit_issued_cents" => credit_issued_cents,
          "revision" => group.revision + 1
        })

      {:error, reason} ->
        raise "cancellation failed: #{inspect(reason)}"
    end
  end

  # A non-refundable cancellation retains the cash and consumes the credit
  # applied to the group.
  defp non_refundable_cancellation(ctx, group) do
    retained_cents = Groups.cash_paid_cents(group)

    group
    |> change(%{
      status: "cancelled",
      deposit_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: retained_cents,
      revision: group.revision + 1
    })
    |> Repo.update!()

    applied(ctx, %{
      "group_id" => group.group_id,
      "refunded_cents" => 0,
      "retained_cents" => retained_cents,
      "credit_issued_cents" => 0,
      "revision" => group.revision + 1
    })
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_amount(operation["amount_cents"]),
         :ok <- ensure_credit_available(group, amount_cents, ctx.occurred_on),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      outstanding_cents = Groups.outstanding_deposit_cents(group)

      {:ok, _} =
        Repo.transaction(fn ->
          Credits.consume_for_group(group, amount_cents, ctx.occurred_on)

          group
          |> change(%{
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            credit_paid_cents: group.credit_paid_cents + amount_cents,
            revision: group.revision + 1
          })
          |> Repo.update!()
        end)

      applied(ctx, %{
        "group_id" => group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => outstanding_cents - amount_cents,
        "revision" => group.revision + 1
      })
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  defp ensure_credit_available(group, amount_cents, occurred_on) do
    if Credits.available_cents(group.guest_id, occurred_on) >= amount_cents do
      :ok
    else
      {:error, "insufficient_credit"}
    end
  end

  ## Shared helpers

  defp fetch_group(group_id) do
    case Groups.fetch_group(group_id) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, "group_not_found"}
    end
  end

  defp check_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, "stale_revision",
           %{
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_), do: {:error, "group_not_active"}

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp applied(ctx, fields) do
    Map.merge(%{"operation_id" => ctx.operation_id, "status" => "applied"}, fields)
  end

  defp reject(operation, code, extra \\ %{}) do
    result = %{"status" => "rejected", "code" => code}

    result =
      if is_map(operation) do
        result
        |> maybe_put("operation_id", operation["operation_id"])
        |> maybe_put("group_id", operation["group_id"])
      else
        result
      end

    Map.merge(result, extra)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
