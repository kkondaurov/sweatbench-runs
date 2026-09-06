defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations and exposes the resulting group and ledger views.

  Every operation has its own database transaction. This lets a batch retain earlier
  successes while guaranteeing that a rejected operation cannot leave partial data behind.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias GroupStay.Credits.{CreditApplication, CreditLot}
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @rate_plans ~w(flexible advance_purchase)
  @new_flexible_policy_on ~D[2027-01-01]

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def group_view(%Group{} = group) do
    group = if Ecto.assoc_loaded?(group.rooms), do: group, else: Repo.preload(group, :rooms)

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
      refundable_until: refundable_until_view(group),
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
      outstanding_deposit_cents: outstanding(group)
    }
  end

  def ledger_view(on \\ Date.utc_today()) do
    cash_totals =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
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
            cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    available_credit =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      ) || 0

    applied_credit =
      Repo.one(
        from application in CreditApplication,
          join: group in Group,
          on: group.group_id == application.group_id,
          where: group.status == "active",
          select: coalesce(sum(application.amount_cents), 0)
      ) || 0

    cash_totals
    |> Map.new(fn {key, value} -> {key, value || 0} end)
    |> Map.put(:credit_liability_cents, available_credit + applied_credit)
  end

  def guest_credit_view(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  defp process(operation) when not is_map(operation), do: rejected(nil, "invalid_operation")

  defp process(operation) do
    operation_id = operation["operation_id"]

    with :ok <- valid_common(operation),
         type when type in @operation_types <- operation["type"] do
      apply_operation(type, operation)
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp valid_common(%{
         "operation_id" => operation_id,
         "type" => type,
         "occurred_on" => occurred_on
       })
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on),
       do: :ok

  defp valid_common(_operation), do: :error

  defp apply_operation("open_group", operation), do: open_group(operation)

  defp apply_operation(type, operation) do
    operation_id = operation["operation_id"]

    if valid_identifier?(operation["group_id"]) do
      Repo.transaction(
        fn ->
          case Repo.get(Group, operation["group_id"]) do
            nil -> rejected(operation_id, "group_not_found")
            group -> apply_to_existing(type, operation, group)
          end
        end,
        mode: :immediate
      )
      |> transaction_result()
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp open_group(operation) do
    operation_id = operation["operation_id"]

    with :ok <- require_open_fields(operation),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_stay_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_stay_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = rooms |> Enum.map(&(&1["nightly_rate_cents"] * nights)) |> Enum.sum()

      deposit_due =
        rooms
        |> Enum.map(fn room ->
          lodging = room["nightly_rate_cents"] * nights
          room_deposit(lodging, operation["rate_plan"])
        end)
        |> Enum.sum()

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version(operation["rate_plan"], booked_on),
        status: "active",
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1
      }

      multi =
        Multi.new()
        |> Multi.insert(
          :group,
          %Group{}
          |> Ecto.Changeset.change(attrs)
          |> Ecto.Changeset.unique_constraint(:group_id)
        )
        |> Multi.run(:rooms, fn repo, %{group: group} ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          rows =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              %{
                group_id: group.group_id,
                position: position,
                room_id: room["room_id"],
                nightly_rate_cents: room["nightly_rate_cents"],
                inserted_at: now,
                updated_at: now
              }
            end)

          {_count, inserted} = repo.insert_all(Room, rows, returning: true)
          {:ok, inserted}
        end)

      case Repo.transaction(multi, mode: :immediate) do
        {:ok, _changes} ->
          applied(operation_id, %{
            group_id: operation["group_id"],
            deposit_due_cents: deposit_due,
            revision: 1
          })

        {:error, :group, changeset, _changes} ->
          if unique_error?(changeset) do
            rejected(operation_id, "group_already_exists")
          else
            rejected(operation_id, "invalid_operation")
          end

        {:error, _step, _reason, _changes} ->
          rejected(operation_id, "invalid_operation")
      end
    else
      {:error, code} -> rejected(operation_id, code)
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_to_existing(type, operation, group) do
    operation_id = operation["operation_id"]

    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      rejected(operation_id, "stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      case parse_date(operation["occurred_on"]) do
        {:ok, _occurred_on} -> apply_existing_domain(type, operation, group)
        :error -> rejected(operation_id, "invalid_operation")
      end
    end
  end

  defp apply_existing_domain("record_cash_payment", operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rejected(operation["operation_id"], "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation["operation_id"], "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]

        updated =
          update_group!(group,
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          )

        applied(operation["operation_id"], %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(updated),
          revision: updated.revision
        })
    end
  end

  defp apply_existing_domain("reschedule_group", operation, group) do
    cond do
      not Map.has_key?(operation, "new_arrival_on") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, shift)

          updated =
            update_group!(group,
              arrival_on: new_arrival_on,
              departure_on: new_departure_on
            )

          applied(operation["operation_id"], %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            policy_version: group.policy_version,
            refundable_until: refundable_until_view(updated),
            revision: updated.revision
          })
        else
          _ -> rejected(operation["operation_id"], "invalid_stay")
        end
    end
  end

  defp apply_existing_domain("cancel_group", operation, group) do
    if group.status != "active" do
      rejected(operation["operation_id"], "group_not_active")
    else
      case parse_date(operation["occurred_on"]) do
        {:ok, occurred_on} ->
          settle_cancellation(operation, group, occurred_on)

        :error ->
          rejected(operation["operation_id"], "invalid_operation")
      end
    end
  end

  defp apply_existing_domain("apply_hotel_credit", operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rejected(operation["operation_id"], "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation["operation_id"], "payment_exceeds_outstanding")

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        amount = operation["amount_cents"]

        lots =
          Repo.all(
            from lot in CreditLot,
              where:
                lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
                  lot.expires_on >= ^occurred_on,
              order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
          )

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          rejected(operation["operation_id"], "insufficient_credit")
        else
          consume_credit_lots!(lots, group.group_id, amount)

          updated =
            update_group!(group,
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: group.credit_paid_cents + amount
            )

          applied(operation["operation_id"], %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          })
        end
    end
  end

  defp settle_cancellation(operation, group, occurred_on) do
    refund_method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred_on)

    cond do
      refund_method not in ["cash", "hotel_credit"] ->
        rejected(operation["operation_id"], "invalid_operation")

      refund_method == "hotel_credit" and not refundable ->
        rejected(operation["operation_id"], "refund_method_not_available")

      true ->
        restore_or_consume_applied_credit!(group, occurred_on, refundable)

        refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
        retained = if refundable, do: 0, else: group.cash_paid_cents

        credit_issued =
          if refundable and refund_method == "hotel_credit" do
            issue_credit!(group, operation["operation_id"], occurred_on)
          else
            0
          end

        converted =
          if refundable and refund_method == "hotel_credit", do: group.cash_paid_cents, else: 0

        updated =
          update_group!(group,
            status: "cancelled",
            cash_refunded_cents: group.cash_refunded_cents + refunded,
            cash_retained_cents: group.cash_retained_cents + retained,
            cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
          )

        applied(operation["operation_id"], %{
          group_id: group.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: credit_issued,
          revision: updated.revision
        })
    end
  end

  defp consume_credit_lots!(lots, group_id, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)

      lot
      |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
      |> Repo.update!()

      %CreditApplication{}
      |> Ecto.Changeset.change(
        group_id: group_id,
        credit_lot_id: lot.id,
        amount_cents: used
      )
      |> Repo.insert!()

      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp restore_or_consume_applied_credit!(group, occurred_on, refundable) do
    applications =
      Repo.all(
        from application in CreditApplication,
          where: application.group_id == ^group.group_id
      )

    if refundable do
      applications
      |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
      |> Enum.each(fn {lot_id, amounts} ->
        lot = Repo.get!(CreditLot, lot_id)

        if Date.compare(lot.expires_on, occurred_on) != :lt do
          lot
          |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + Enum.sum(amounts))
          |> Repo.update!()
        end
      end)
    end

    Repo.delete_all(
      from application in CreditApplication,
        where: application.group_id == ^group.group_id
    )
  end

  defp issue_credit!(group, source_operation_id, occurred_on) do
    if group.cash_paid_cents == 0 do
      0
    else
      bonus = div(group.cash_paid_cents * 10 + 50, 100)
      amount = group.cash_paid_cents + bonus

      %CreditLot{}
      |> Ecto.Changeset.change(
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        issued_on: occurred_on,
        remaining_cents: amount,
        expires_on: Date.add(occurred_on, 365)
      )
      |> Repo.insert!()

      amount
    end
  end

  defp refundable?(%Group{policy_version: "advance-nonrefundable"}, _occurred_on), do: false

  defp refundable?(%Group{} = group, occurred_on) do
    Date.compare(occurred_on, refundable_until(group)) != :gt
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until_view(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @new_flexible_policy_on) == :lt, do: "flex-14", else: "flex-30"
  end

  defp update_group!(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(%Group{status: "cancelled"}), do: 0

  defp outstanding(%Group{} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp require_open_fields(operation) do
    identifiers_valid? =
      Enum.all?(~w(group_id guest_id property_id), fn key -> valid_identifier?(operation[key]) end)

    fields_present? =
      Enum.all?(~w(arrival_on departure_on rate_plan rooms), &Map.has_key?(operation, &1))

    if identifiers_valid? and fields_present?, do: :ok, else: :error
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 ->
          true

        _ ->
          false
      end)

    ids = Enum.map(rooms, & &1["room_id"])

    if valid? and Enum.uniq(ids) == ids,
      do: {:ok, rooms},
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp room_deposit(lodging, "advance_purchase"), do: lodging
  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp parse_stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_stay"}
    end
  end

  defp valid_identifier?(identifier), do: is_binary(identifier) and identifier != ""

  defp unique_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :unique
    end)
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, _reason}), do: raise("operation transaction failed")

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejected(operation_id, code, fields \\ %{}),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
end
