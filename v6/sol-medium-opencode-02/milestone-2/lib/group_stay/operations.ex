defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{CreditApplication, CreditLot, Group, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)
  @operation_types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group)
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
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_), do: {:error, :not_found}

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
            coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    {held, refunded, retained, converted} = totals

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

    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "credit_liability_cents" => available_credit + applied_credit
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
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
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
    type = operation["type"]

    if common_fields?(operation) and type in @operation_types do
      transact(type, operation)
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp process_operation(_), do: rejected(%{}, "invalid_operation")

  defp transact(type, operation) do
    case Repo.transaction(fn -> apply_operation(type, operation) end) do
      {:ok, response} -> response
      {:error, :retry} -> transact(type, operation)
      {:error, response} -> response
    end
  end

  defp apply_operation("open_group", operation), do: open_group(operation)

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
            Repo.insert!(%Room{
              group_id: group.id,
              room_id: room["room_id"],
              nightly_rate_cents: room["nightly_rate_cents"],
              position: position
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
        settle_cancellation(group, operation, occurred_on, refundable, refund_method)
      end
    else
      false -> rollback(operation, "group_not_active", %{"group_id" => group.group_id})
      _ -> rollback(operation, "invalid_operation", %{"group_id" => group.group_id})
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
      consume_credit_lots(lots, group, amount)

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

  defp consume_credit_lots(_lots, _group, 0), do: :ok

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

        consume_credit_lots(lots, group, remaining - amount)

      {0, nil} ->
        Repo.rollback(:retry)
    end
  end

  defp settle_cancellation(group, operation, occurred_on, refundable, refund_method) do
    applications =
      Repo.all(
        from application in CreditApplication,
          where: application.group_id == ^group.id,
          preload: [:credit_lot]
      )

    if refundable, do: restore_credit(applications, occurred_on)

    Repo.delete_all(
      from application in CreditApplication, where: application.group_id == ^group.id
    )

    refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    credit_issued =
      if refundable and refund_method == "hotel_credit" do
        group.cash_paid_cents + round_percentage(group.cash_paid_cents, 10)
      else
        0
      end

    if credit_issued > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    converted = if credit_issued > 0, do: group.cash_paid_cents, else: 0

    group =
      update_group!(group, %{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained,
        cash_converted_to_credit_cents: converted
      })

    applied(operation, %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "credit_issued_cents" => credit_issued,
      "revision" => group.revision
    })
  end

  defp restore_credit(applications, occurred_on) do
    Enum.each(applications, fn application ->
      if Date.compare(application.credit_lot.expires_on, occurred_on) in [:gt, :eq] do
        Repo.update_all(
          from(lot in CreditLot, where: lot.id == ^application.credit_lot_id),
          inc: [remaining_cents: application.amount_cents]
        )
      end
    end)
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

  defp revision_matches(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected} when expected == group.revision -> :ok
      {:ok, expected} -> {:stale, group, expected}
    end
  end

  defp totals(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_sum, deposit_sum} ->
      lodging = nights * room["nightly_rate_cents"]
      deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
      {lodging_sum + lodging, deposit_sum + deposit}
    end)
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
    do: Repo.rollback(rejected(operation, code, fields))
end
