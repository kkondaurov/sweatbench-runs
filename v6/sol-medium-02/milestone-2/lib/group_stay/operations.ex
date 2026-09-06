defmodule GroupStay.Operations do
  @moduledoc "Applies partner operations and exposes the resulting group-deposit state."

  import Ecto.Query

  alias GroupStay.Credits.{CreditApplication, CreditLot}
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  def ledger(on \\ Date.utc_today()) do
    cash =
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
            cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from application in CreditApplication,
          join: group in assoc(application, :group),
          where: group.status == "active",
          select: coalesce(sum(application.amount_cents), 0)
      )

    Map.put(cash, :credit_liability_cents, available + applied)
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
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

  def serialize_group(group) do
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
      refundable_until: iso_date(group.refundable_until),
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

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    result =
      Repo.transaction(fn ->
        case dispatch(operation) do
          {:ok, result} -> result
          {:error, result} -> Repo.rollback(result)
        end
      end)

    case result do
      {:ok, applied} -> Map.merge(%{operation_id: operation_id, status: "applied"}, applied)
      {:error, rejected} -> Map.merge(%{operation_id: operation_id, status: "rejected"}, rejected)
    end
  end

  defp apply_operation(_),
    do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)
  defp dispatch(%{"type" => "record_cash_payment"} = operation), do: with_group(operation, &pay/3)

  defp dispatch(%{"type" => "reschedule_group"} = operation),
    do: with_group(operation, &reschedule/3)

  defp dispatch(%{"type" => "cancel_group"} = operation), do: with_group(operation, &cancel/3)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: with_group(operation, &apply_credit/3)

  defp dispatch(_), do: reject("invalid_operation")

  defp open_group(operation) do
    with true <-
           required_keys?(
             operation,
             ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         true <- common_valid?(operation),
         {:ok, booked_on} <- date(operation["occurred_on"]),
         true <- valid_identifier?(operation["group_id"]),
         true <- valid_identifier?(operation["guest_id"]),
         true <- valid_identifier?(operation["property_id"]),
         false <- Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]),
         {:ok, arrival_on} <- date(operation["arrival_on"]),
         {:ok, departure_on} <- date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rooms} <- rooms(operation["rooms"]),
         true <- operation["rate_plan"] in @rate_plans do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))

      deposit_due =
        case operation["rate_plan"] do
          "flexible" ->
            Enum.sum(Enum.map(rooms, &round_flexible_deposit(&1.nightly_rate_cents * nights)))

          "advance_purchase" ->
            lodging_total
        end

      policy_version = policy_version(operation["rate_plan"], booked_on)
      refundable_until = refundable_until(policy_version, arrival_on)

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version,
        refundable_until: refundable_until,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }

      case Repo.insert(Group.create_changeset(%Group{}, attrs)) do
        {:ok, group} ->
          Enum.each(rooms, fn room ->
            room
            |> Map.put(:group_id, group.id)
            |> then(&Room.changeset(%Room{}, &1))
            |> Repo.insert!()
          end)

          {:ok, %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: 1}}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id),
            do: reject("group_already_exists"),
            else: reject("invalid_operation")
      end
    else
      false -> open_error(operation)
      {:error, :invalid_rooms} -> reject("invalid_rooms")
      {:error, :invalid_date} -> open_error(operation)
    end
  end

  defp open_error(operation) do
    cond do
      not required_keys?(
        operation,
        ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
      ) ->
        reject("invalid_operation")

      not common_valid?(operation) ->
        reject("invalid_operation")

      not valid_identifier?(operation["group_id"]) ->
        reject("invalid_operation")

      not valid_identifier?(operation["guest_id"]) ->
        reject("invalid_operation")

      not valid_identifier?(operation["property_id"]) ->
        reject("invalid_operation")

      Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) ->
        reject("group_already_exists")

      operation["rate_plan"] not in @rate_plans ->
        reject("invalid_rate_plan")

      not valid_rooms?(operation["rooms"]) ->
        reject("invalid_rooms")

      true ->
        reject("invalid_stay")
    end
  end

  defp with_group(operation, function) do
    with true <- required_keys?(operation, required_fields(operation["type"])),
         true <- common_valid?(operation),
         true <- valid_identifier?(operation["group_id"]),
         %Group{} = group <- Repo.get_by(Group, group_id: operation["group_id"]),
         :ok <- revision_matches(operation, group) do
      function.(operation, group, operation_date(operation))
    else
      false -> reject("invalid_operation")
      nil -> reject("group_not_found", %{group_id: operation["group_id"]})
      {:error, :invalid_date} -> reject("invalid_operation")
      {:error, stale} when is_map(stale) -> {:error, stale}
    end
  end

  defp pay(operation, group, {:ok, _occurred_on}) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      not (is_integer(amount) and amount > 0) ->
        reject("invalid_amount", %{group_id: group.group_id})

      amount > outstanding(group) ->
        reject("payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        new_outstanding = outstanding(group) - amount

        {:ok, updated} =
          persist_update(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: new_outstanding,
           revision: updated.revision
         }}
    end
  end

  defp pay(_operation, _group, {:error, :invalid_date}), do: reject("invalid_operation")

  defp reschedule(operation, group, {:ok, occurred_on}) do
    with true <- group.status == "active",
         {:ok, arrival_on} <- date(operation["new_arrival_on"]),
         true <- Date.compare(arrival_on, occurred_on) == :gt do
      departure_on = Date.add(group.departure_on, Date.diff(arrival_on, group.arrival_on))

      {:ok, updated} =
        persist_update(group, %{
          arrival_on: arrival_on,
          departure_on: departure_on,
          refundable_until: refundable_until(group.policy_version, arrival_on)
        })

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: Date.to_iso8601(arrival_on),
         new_departure_on: Date.to_iso8601(departure_on),
         policy_version: group.policy_version,
         refundable_until: iso_date(updated.refundable_until),
         revision: updated.revision
       }}
    else
      false when group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      _ ->
        reject("invalid_stay", %{group_id: group.group_id})
    end
  end

  defp reschedule(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp cancel(operation, group, {:ok, occurred_on}) do
    if group.status == "active" do
      refund_method = Map.get(operation, "refund_method", "cash")
      refundable = refundable?(group, occurred_on)

      cond do
        refund_method not in ["cash", "hotel_credit"] ->
          reject("invalid_operation", %{group_id: group.group_id})

        refund_method == "hotel_credit" and not refundable ->
          reject("refund_method_not_available", %{group_id: group.group_id})

        true ->
          settle_cancellation(operation, group, occurred_on, refundable, refund_method)
      end
    else
      reject("group_not_active", %{group_id: group.group_id})
    end
  end

  defp cancel(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp settle_cancellation(operation, group, occurred_on, true, refund_method) do
    {refunded, converted, credit_issued} =
      case refund_method do
        "cash" ->
          {group.cash_paid_cents, 0, 0}

        "hotel_credit" ->
          issued = group.cash_paid_cents + round_ten_percent(group.cash_paid_cents)

          if issued > 0 do
            insert_credit_lot!(
              group.guest_id,
              operation["operation_id"],
              issued,
              Date.add(occurred_on, 365)
            )
          end

          {0, group.cash_paid_cents, issued}
      end

    restore_applied_credit(group, occurred_on)

    {:ok, updated} =
      persist_update(group, %{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: 0,
        cash_converted_to_credit_cents: converted
      })

    cancellation_result(updated, refunded, 0, credit_issued)
  end

  defp settle_cancellation(_operation, group, _occurred_on, false, "cash") do
    {:ok, updated} =
      persist_update(group, %{
        status: "cancelled",
        refunded_cents: 0,
        retained_cents: group.cash_paid_cents
      })

    cancellation_result(updated, 0, group.cash_paid_cents, 0)
  end

  defp cancellation_result(group, refunded, retained, credit_issued) do
    {:ok,
     %{
       group_id: group.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       credit_issued_cents: credit_issued,
       revision: group.revision
     }}
  end

  defp apply_credit(operation, group, {:ok, occurred_on}) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      not (is_integer(amount) and amount > 0) ->
        reject("invalid_amount", %{group_id: group.group_id})

      amount > outstanding(group) ->
        reject("payment_exceeds_outstanding", %{group_id: group.group_id})

      available_credit(group.guest_id, occurred_on) < amount ->
        reject("insufficient_credit", %{group_id: group.group_id})

      true ->
        consume_credit(group, amount, occurred_on)

        {:ok, updated} =
          persist_update(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            credit_paid_cents: group.credit_paid_cents + amount
          })

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding(updated),
           revision: updated.revision
         }}
    end
  end

  defp apply_credit(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp persist_update(group, attrs) do
    group
    |> Group.update_changeset(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update()
  end

  defp available_credit(guest_id, on) do
    Repo.one(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        select: coalesce(sum(lot.remaining_cents), 0)
    )
  end

  defp consume_credit(group, amount, on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)

      lot
      |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - used})
      |> Repo.update!()

      %CreditApplication{}
      |> CreditApplication.changeset(%{
        group_id: group.id,
        credit_lot_id: lot.id,
        amount_cents: used
      })
      |> Repo.insert!()

      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp restore_applied_credit(group, occurred_on) do
    restorations =
      Repo.all(
        from application in CreditApplication,
          where: application.group_id == ^group.id,
          group_by: application.credit_lot_id,
          select: {application.credit_lot_id, sum(application.amount_cents)}
      )

    Enum.each(restorations, fn {lot_id, amount} ->
      lot = Repo.get!(CreditLot, lot_id)

      if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt] do
        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents + amount})
        |> Repo.update!()
      end
    end)
  end

  defp insert_credit_lot!(guest_id, source_operation_id, amount, expires_on) do
    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount,
      expires_on: expires_on
    })
    |> Repo.insert!()
  end

  defp revision_matches(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp common_valid?(operation) do
    valid_identifier?(operation["operation_id"]) and
      is_binary(operation["type"]) and
      match?({:ok, _}, date(operation["occurred_on"]))
  end

  defp operation_date(operation), do: date(operation["occurred_on"])

  defp required_fields("record_cash_payment"),
    do: ~w(operation_id type occurred_on group_id amount_cents)

  defp required_fields("reschedule_group"),
    do: ~w(operation_id type occurred_on group_id new_arrival_on)

  defp required_fields("cancel_group"), do: ~w(operation_id type occurred_on group_id)

  defp required_fields("apply_hotel_credit"),
    do: ~w(operation_id type occurred_on group_id amount_cents)

  defp required_fields(_), do: []

  defp required_keys?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))

  defp rooms(value) do
    if valid_rooms?(value) do
      {:ok,
       value
       |> Enum.with_index()
       |> Enum.map(fn {room, position} ->
         %{
           room_id: room["room_id"],
           nightly_rate_cents: room["nightly_rate_cents"],
           position: position
         }
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn
      %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
        valid_identifier?(room_id) and is_integer(rate) and rate > 0

      _ ->
        false
    end) and Enum.uniq_by(rooms, & &1["room_id"]) == rooms
  end

  defp valid_rooms?(_), do: false

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp date(_), do: {:error, :invalid_date}

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0
  defp round_flexible_deposit(lodging_cents), do: div(lodging_cents + 2, 5)
  defp round_ten_percent(cents), do: div(cents + 5, 10)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable?(%Group{refundable_until: nil}, _occurred_on), do: false

  defp refundable?(group, occurred_on) do
    Date.compare(occurred_on, group.refundable_until) in [:lt, :eq]
  end

  defp iso_date(nil), do: nil
  defp iso_date(date), do: Date.to_iso8601(date)

  defp reject(code, extra \\ %{}), do: {:error, Map.put(extra, :code, code)}
end
