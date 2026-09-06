defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations (open, fund, move, cancel) against groups.

  Operations validate before they write, so a rejected operation never changes
  the database. Every applied operation addressed to a group increments its
  revision exactly once; rejections never do.
  """

  alias GroupStay.Credits
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_lifetime_days 365

  @doc """
  Applies a single operation and returns its result map.
  """
  def apply_operation(op) when is_map(op) do
    case op["type"] do
      "open_group" -> open_group(op)
      "record_cash_payment" -> record_cash_payment(op)
      "reschedule_group" -> reschedule_group(op)
      "cancel_group" -> cancel_group(op)
      "apply_hotel_credit" -> apply_hotel_credit(op)
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
      lodging_total = lodging_total(rooms, nights)
      deposit_due = deposit_due(rooms, nights, op["rate_plan"])
      positioned_rooms = with_positions(rooms)

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

  defp with_positions(rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.map(fn {room, index} -> Map.put(room, "position", index) end)
  end

  defp lodging_total(rooms, nights) do
    Enum.sum(Enum.map(rooms, fn room -> nights * room["nightly_rate_cents"] end))
  end

  # Advance purchase deposits equal the full stay; flexible deposits are a
  # percentage of each room, rounded per room and then summed.
  defp deposit_due(rooms, nights, "advance_purchase"), do: lodging_total(rooms, nights)

  defp deposit_due(rooms, nights, "flexible") do
    Enum.sum(
      Enum.map(rooms, fn room ->
        rounded_percentage(nights * room["nightly_rate_cents"], @flexible_deposit_percent)
      end)
    )
  end

  # Rounds a percentage to the nearest cent; an exact half-cent rounds upward.
  defp rounded_percentage(amount_cents, percent) do
    dividend = amount_cents * percent
    quotient = div(dividend, 100)
    remainder = rem(dividend, 100)

    if remainder * 2 >= 100, do: quotient + 1, else: quotient
  end

  ## record_cash_payment

  defp record_cash_payment(op) do
    with :ok <- validate_common(op, ["group_id"]),
         {:ok, group} <- fetch_group(op),
         :ok <- match_revision(group, op),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount) do
      updated =
        group
        |> Group.payment_changeset(amount)
        |> Repo.update!()

      applied(op, %{
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => Groups.outstanding_deposit(updated),
        "revision" => updated.revision
      })
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found} -> reject(op, "group_not_found")
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active} -> reject(op, "group_not_active")
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
         :ok <- match_revision(group, op),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount),
         :ok <- ensure_sufficient_credit(group, amount, occurred_on!(op)) do
      {:ok, updated} =
        Repo.transaction(fn ->
          Credits.consume(group.guest_id, amount, occurred_on!(op), group)

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
      {:not_found} -> reject(op, "group_not_found")
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active} -> reject(op, "group_not_active")
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
         :ok <- match_revision(group, op),
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
      {:not_found} -> reject(op, "group_not_found")
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active} -> reject(op, "group_not_active")
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
         :ok <- match_revision(group, op),
         :ok <- ensure_active(group),
         {:ok, method} <- refund_method(op["refund_method"]) do
      occurred_on = occurred_on!(op)
      refundable = Groups.refundable?(group, occurred_on)

      if method == :hotel_credit and not refundable do
        # Hotel credit is not a way around a non-refundable policy.
        reject(op, "refund_method_not_available")
      else
        settle_cancellation(op, group, occurred_on, method, refundable)
      end
    else
      {:invalid_operation} -> reject(op, "invalid_operation")
      {:not_found} -> reject(op, "group_not_found")
      {:stale, group, expected} -> reject_stale(op, group, expected)
      {:group_not_active} -> reject(op, "group_not_active")
    end
  end

  # Omitting the refund method means cash, preserving existing callers.
  defp refund_method(nil), do: {:ok, :cash}
  defp refund_method("cash"), do: {:ok, :cash}
  defp refund_method("hotel_credit"), do: {:ok, :hotel_credit}
  defp refund_method(_), do: {:invalid_operation}

  # Refundable cash settlements refund; refundable credit settlements convert
  # the cash into a bonus credit lot; non-refundable settlements retain the
  # cash. Previously applied credit returns to its lots on a refundable
  # cancellation and is consumed on a non-refundable one.
  defp settle_cancellation(op, group, occurred_on, method, refundable) do
    cash = group.cash_paid_cents

    settlement =
      case {refundable, method} do
        {true, :cash} ->
          %{refunded: cash, retained: 0, converted: 0, credit_issued: 0}

        {true, :hotel_credit} ->
          %{refunded: 0, retained: 0, converted: cash, credit_issued: credit_value(cash)}

        {false, :cash} ->
          %{refunded: 0, retained: cash, converted: 0, credit_issued: 0}
      end

    {:ok, updated} =
      Repo.transaction(fn ->
        if settlement.credit_issued > 0 do
          Credits.create_lot(%{
            guest_id: group.guest_id,
            source_operation_id: op["operation_id"],
            amount_cents: settlement.credit_issued,
            expires_on: Date.add(occurred_on, @credit_lifetime_days)
          })
        end

        if refundable do
          Credits.restore_applications(group)
        else
          Credits.consume_applications(group)
        end

        group
        |> Group.cancel_changeset(%{
          refunded_cents: settlement.refunded,
          retained_cents: settlement.retained,
          converted_cents: settlement.converted
        })
        |> Repo.update!()
      end)

    applied(op, %{
      "group_id" => group.group_id,
      "refunded_cents" => settlement.refunded,
      "retained_cents" => settlement.retained,
      "credit_issued_cents" => settlement.credit_issued,
      "revision" => updated.revision
    })
  end

  # A credit lot is worth 110% of the converted cash: the cash plus its 10%
  # bonus, rounded to the nearest cent with half-cents up.
  defp credit_value(cash_cents) do
    cash_cents + rounded_percentage(cash_cents, @credit_bonus_percent)
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

  defp fetch_group(op) do
    case Groups.get_group(op["group_id"]) do
      nil -> {:not_found}
      %Group{} = group -> {:ok, group}
    end
  end

  # Group existence is resolved before revisions are compared, so this check
  # always runs against a fetched group.
  defp match_revision(group, op) do
    expected = op["expected_revision"]

    if is_nil(expected) or expected == group.revision do
      :ok
    else
      {:stale, group, expected}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:group_not_active}

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

  defp reject_stale(op, group, expected) do
    op
    |> base_result("rejected")
    |> Map.merge(%{
      "code" => "stale_revision",
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
