defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditApplication, CreditLot, Group, PartnerOperation, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @flex_30_start ~D[2027-01-01]

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def fetch_group(group_id) when is_binary(group_id) do
    case group_by_partner_id(group_id) do
      nil -> :not_found
      group -> {:ok, group_payload(group)}
    end
  end

  def fetch_group(_), do: :not_found

  def fetch_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> :not_found
      operation -> {:ok, operation.result}
    end
  end

  def fetch_operation(_), do: :not_found

  def ledger(on \\ Date.utc_today()) do
    totals =
      Repo.one(
        from group in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    group.status,
                    group.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(group.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(group.cash_converted_to_credit_cents), 0)
          }
      )

    (totals ||
       %{
         cash_held_cents: 0,
         cash_refunded_cents: 0,
         cash_retained_cents: 0,
         cash_converted_to_credit_cents: 0
       })
    |> Map.put(:credit_liability_cents, credit_liability(on))
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
      available_cents: Enum.sum_by(lots, & &1.remaining_cents),
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

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      with_operation_lock(operation_id, fn ->
        with_group_lock(operation, fn -> apply_or_replay(operation, operation_id) end)
      end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_operation(_), do: rejected(nil, "invalid_operation")

  defp apply_or_replay(operation, operation_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(PartnerOperation, operation_id: operation_id) do
             nil -> remember_new_operation(operation, operation_id)
             remembered -> replay_or_conflict(remembered, operation, operation_id)
           end
         end) do
      {:ok, result} -> result
      {:error, :operation_id_raced} -> apply_or_replay(operation, operation_id)
    end
  end

  defp remember_new_operation(operation, operation_id) do
    attrs = %{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload: operation,
      result: %{}
    }

    case Repo.insert(PartnerOperation.changeset(%PartnerOperation{}, attrs)) do
      {:ok, remembered} ->
        result = run_domain_operation(operation, operation_id)

        case Repo.update(PartnerOperation.changeset(remembered, %{result: result})) do
          {:ok, _remembered} ->
            result

          {:error, changeset} ->
            raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
        end

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :operation_id) do
          Repo.rollback(:operation_id_raced)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp replay_or_conflict(remembered, operation, operation_id) do
    if remembered.payload == operation do
      remembered.result
    else
      rejected(operation_id, "operation_id_conflict")
    end
  end

  defp run_domain_operation(operation, operation_id) do
    operation
    |> dispatch()
    |> Map.put("operation_id", operation_id)
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)

  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp dispatch(_), do: reject("invalid_operation")

  defp open_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         nil <- group_by_partner_id(group_id),
         {:ok, attrs, room_attrs} <- opening_attrs(operation, group_id),
         {:ok, group} <- Repo.insert(Group.changeset(%Group{}, attrs)),
         :ok <- insert_rooms(group, room_attrs) do
      applied(%{
        "group_id" => group.group_id,
        "deposit_due_cents" => group.deposit_due_cents,
        "revision" => group.revision
      })
    else
      %Group{} -> reject("group_already_exists", group_result(operation))
      {:error, code} when is_binary(code) -> reject(code)
      {:error, {:room_insert_failed, changeset}} -> unexpected_changeset!(changeset)
      {:error, %Ecto.Changeset{}} -> reject("group_already_exists", group_result(operation))
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, _occurred_on} <- operation_date(operation),
         {:ok, amount} <- positive_amount(operation, "amount_cents"),
         :ok <- payment_within_outstanding?(group, amount),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             cash_paid_cents: group.cash_paid_cents + amount,
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        reject("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:error, :invalid_operation_date} ->
        reject("invalid_operation", group_result(operation))

      {:error, :invalid_amount} ->
        reject("invalid_amount", group_result(operation))

      {:error, :payment_exceeds_outstanding} ->
        reject("payment_exceeds_outstanding", group_result(operation))

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)

      {:stale, details} ->
        reject("stale_revision", details)

      :inactive ->
        reject("group_not_active", group_result(operation))
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, amount} <- positive_amount(operation, "amount_cents"),
         :ok <- payment_within_outstanding?(group, amount),
         :ok <- consume_credit(group, amount, occurred_on),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             credit_paid_cents: group.credit_paid_cents + amount,
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        reject("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:error, :invalid_operation_date} ->
        reject("invalid_operation", group_result(operation))

      {:error, :invalid_amount} ->
        reject("invalid_amount", group_result(operation))

      {:error, :payment_exceeds_outstanding} ->
        reject("payment_exceeds_outstanding", group_result(operation))

      {:error, :insufficient_credit} ->
        reject("insufficient_credit", group_result(operation))

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)

      {:stale, details} ->
        reject("stale_revision", details)

      :inactive ->
        reject("group_not_active", group_result(operation))
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, new_arrival_on} <- date_value(operation, "new_arrival_on"),
         :ok <- future_arrival?(new_arrival_on, occurred_on),
         new_departure_on <-
           Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
        "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
        "policy_version" => updated_group.policy_version,
        "refundable_until" => refundable_until_payload(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} -> reject("group_not_found", group_result(operation))
      {:error, :invalid_identifier} -> reject("invalid_operation")
      {:error, :invalid_operation_date} -> reject("invalid_operation", group_result(operation))
      {:error, :invalid_stay} -> reject("invalid_stay", group_result(operation))
      {:error, %Ecto.Changeset{} = changeset} -> unexpected_changeset!(changeset)
      {:stale, details} -> reject("stale_revision", details)
      :inactive -> reject("group_not_active", group_result(operation))
    end
  end

  defp cancel_group(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- refund_method_available?(group, occurred_on, refund_method),
         {:ok, refunded_cents, retained_cents, credit_issued_cents} <-
           settle_cancellation(group, occurred_on, refund_method, operation["operation_id"]),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             status: "cancelled",
             deposit_due_cents: 0,
             deposit_paid_cents: 0,
             cash_paid_cents: 0,
             credit_paid_cents: 0,
             refunded_cents: group.refunded_cents + refunded_cents,
             retained_cents: group.retained_cents + retained_cents,
             cash_converted_to_credit_cents:
               group.cash_converted_to_credit_cents + cash_converted(refund_method, group),
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "refunded_cents" => refunded_cents,
        "retained_cents" => retained_cents,
        "credit_issued_cents" => credit_issued_cents,
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        reject("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:error, :invalid_operation_date} ->
        reject("invalid_operation", group_result(operation))

      {:error, :invalid_refund_method} ->
        reject("invalid_operation", group_result(operation))

      {:error, :refund_method_not_available} ->
        reject("refund_method_not_available", group_result(operation))

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)

      {:stale, details} ->
        reject("stale_revision", details)

      :inactive ->
        reject("group_not_active", group_result(operation))
    end
  end

  defp opening_attrs(operation, group_id) do
    with {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- date_value(operation, "arrival_on"),
         {:ok, departure_on} <- date_value(operation, "departure_on"),
         :ok <- valid_stay?(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
           rooms(operation, arrival_on, departure_on, rate_plan) do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         policy_version: policy_for(rate_plan, booked_on),
         status: "active",
         lodging_total_cents: lodging_total_cents,
         deposit_due_cents: deposit_due_cents,
         deposit_paid_cents: 0,
         cash_paid_cents: 0,
         credit_paid_cents: 0,
         refunded_cents: 0,
         retained_cents: 0,
         cash_converted_to_credit_cents: 0,
         revision: 1
       }, rooms}
    else
      {:error, :invalid_operation_date} -> {:error, "invalid_operation"}
      {:error, :invalid_stay} -> {:error, "invalid_stay"}
      {:error, :invalid_rate_plan} -> {:error, "invalid_rate_plan"}
      {:error, :invalid_rooms} -> {:error, "invalid_rooms"}
      {:error, :invalid_identifier} -> {:error, "invalid_operation"}
    end
  end

  defp group_for_operation(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      case group_by_partner_id(group_id) do
        nil -> {:error, :not_found}
        group -> {:ok, group}
      end
    end
  end

  defp group_by_partner_id(group_id) do
    Repo.one(
      from group in Group,
        where: group.group_id == ^group_id,
        preload: [rooms: ^from(room in Room, order_by: room.position)]
    )
  end

  defp insert_rooms(group, room_attrs) do
    Enum.reduce_while(room_attrs, :ok, fn room_attrs, :ok ->
      attrs = Map.put(room_attrs, :group_db_id, group.id)

      case Repo.insert(Room.changeset(%Room{}, attrs)) do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, {:room_insert_failed, changeset}}}
      end
    end)
  end

  defp rooms(%{"rooms" => rooms}, arrival_on, departure_on, rate_plan)
       when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({[], MapSet.new(), 0, 0}, fn {room, position},
                                                      {attrs, room_ids, lodging_total,
                                                       deposit_total} ->
      case room_attrs(room, position, room_ids, nights, rate_plan) do
        {:ok, room_attrs, room_id, lodging_cents, deposit_cents} ->
          {:cont,
           {[room_attrs | attrs], MapSet.put(room_ids, room_id), lodging_total + lodging_cents,
            deposit_total + deposit_cents}}

        {:error, :invalid_rooms} ->
          {:halt, :invalid_rooms}
      end
    end)
    |> case do
      :invalid_rooms ->
        {:error, :invalid_rooms}

      {attrs, _room_ids, lodging_total, deposit_total} ->
        {:ok, Enum.reverse(attrs), lodging_total, deposit_total}
    end
  end

  defp rooms(_, _, _, _), do: {:error, :invalid_rooms}

  defp room_attrs(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position,
         room_ids,
         nights,
         rate_plan
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents >= 0 do
    if MapSet.member?(room_ids, room_id) do
      {:error, :invalid_rooms}
    else
      lodging_cents = nights * nightly_rate_cents
      deposit_cents = deposit_for(lodging_cents, rate_plan)

      {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position},
       room_id, lodging_cents, deposit_cents}
    end
  end

  defp room_attrs(_, _, _, _, _), do: {:error, :invalid_rooms}

  defp deposit_for(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, "advance_purchase"), do: lodging_cents

  defp rate_plan(%{"rate_plan" => rate_plan}) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp rate_plan(_), do: {:error, :invalid_rate_plan}

  defp valid_stay?(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp future_arrival?(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp positive_amount(operation, key) do
    case Map.get(operation, key) do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp payment_within_outstanding?(group, amount) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, :payment_exceeds_outstanding}
  end

  defp active?(%Group{status: "active"}), do: :ok
  defp active?(_), do: :inactive

  defp revision_matches?(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:stale,
           %{
             "group_id" => group.group_id,
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end

      {:ok, _} ->
        {:error, :invalid_identifier}
    end
  end

  defp operation_date(operation) do
    case date_value(operation, "occurred_on") do
      {:ok, date} -> {:ok, date}
      {:error, :invalid_stay} -> {:error, :invalid_operation_date}
    end
  end

  defp date_value(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, :invalid_stay}
        end

      _ ->
        {:error, :invalid_stay}
    end
  end

  defp required_identifier(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_identifier}
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp consume_credit(group, amount, occurred_on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    if Enum.sum_by(lots, & &1.remaining_cents) < amount do
      {:error, :insufficient_credit}
    else
      consume_credit_lots(lots, group.id, amount)
    end
  end

  defp consume_credit_lots(lots, group_db_id, amount) do
    lots
    |> Enum.reduce_while({:ok, amount}, fn lot, {:ok, remaining} ->
      applied_cents = min(lot.remaining_cents, remaining)

      with {:ok, _lot} <-
             Repo.update(
               CreditLot.changeset(lot, %{remaining_cents: lot.remaining_cents - applied_cents})
             ),
           {:ok, _application} <-
             Repo.insert(
               CreditApplication.changeset(%CreditApplication{}, %{
                 group_db_id: group_db_id,
                 credit_lot_id: lot.id,
                 amount_cents: applied_cents
               })
             ) do
        if applied_cents == remaining do
          {:halt, :ok}
        else
          {:cont, {:ok, remaining - applied_cents}}
        end
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      :ok -> :ok
      {:ok, _remaining} -> {:error, :insufficient_credit}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp settle_cancellation(group, occurred_on, refund_method, operation_id) do
    applications = credit_applications_for_group(group.id)

    if refundable?(group, occurred_on) do
      with :ok <- restore_credit(applications, occurred_on),
           {:ok, credit_issued_cents} <-
             issue_credit(group, refund_method, operation_id, occurred_on) do
        refunded_cents = if refund_method == "cash", do: group.cash_paid_cents, else: 0
        {:ok, refunded_cents, 0, credit_issued_cents}
      end
    else
      with :ok <- consume_applied_credit(applications) do
        {:ok, 0, group.cash_paid_cents, 0}
      end
    end
  end

  defp credit_applications_for_group(group_db_id) do
    Repo.all(
      from application in CreditApplication,
        where: application.group_db_id == ^group_db_id,
        preload: [:credit_lot]
    )
  end

  defp restore_credit(applications, occurred_on) do
    with :ok <- restore_credit_lots(applications, occurred_on),
         :ok <- consume_applied_credit(applications) do
      :ok
    end
  end

  defp restore_credit_lots(applications, occurred_on) do
    applications
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.reduce_while(:ok, fn {_credit_lot_id, applications}, :ok ->
      [application | _] = applications
      restored_cents = Enum.sum_by(applications, & &1.amount_cents)

      if Date.compare(application.credit_lot.expires_on, occurred_on) == :lt do
        {:cont, :ok}
      else
        case Repo.update(
               CreditLot.changeset(application.credit_lot, %{
                 remaining_cents: application.credit_lot.remaining_cents + restored_cents
               })
             ) do
          {:ok, _lot} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end
    end)
  end

  defp consume_applied_credit(applications) do
    Enum.reduce_while(applications, :ok, fn application, :ok ->
      case Repo.delete(application) do
        {:ok, _application} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp issue_credit(_group, "cash", _operation_id, _occurred_on), do: {:ok, 0}

  defp issue_credit(group, "hotel_credit", operation_id, occurred_on) do
    credit_issued_cents = group.cash_paid_cents + bonus_for(group.cash_paid_cents)

    if credit_issued_cents == 0 do
      {:ok, 0}
    else
      Repo.insert(
        CreditLot.changeset(%CreditLot{}, %{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: credit_issued_cents,
          expires_on: Date.add(occurred_on, 365)
        })
      )
      |> case do
        {:ok, _lot} -> {:ok, credit_issued_cents}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp bonus_for(cash_cents), do: div(cash_cents * 10 + 50, 100)

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, :invalid_refund_method}
    end
  end

  defp refund_method_available?(group, occurred_on, "hotel_credit") do
    if refundable?(group, occurred_on),
      do: :ok,
      else: {:error, :refund_method_not_available}
  end

  defp refund_method_available?(_group, _occurred_on, "cash"), do: :ok

  defp cash_converted("hotel_credit", group), do: group.cash_paid_cents
  defp cash_converted("cash", _group), do: 0

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(%Group{}), do: nil

  defp refundable_until_payload(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp credit_liability(on) do
    available_cents =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from application in CreditApplication,
          join: group in Group,
          on: group.id == application.group_db_id,
          where: group.status == "active",
          select: coalesce(sum(application.amount_cents), 0)
      )

    available_cents + applied_cents
  end

  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  # Serializing a group's operations makes revision checks and writes a single critical section.
  defp with_group_lock(operation, fun) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and group_id != "" ->
        :global.trans({__MODULE__, group_id}, fun)

      _ ->
        fun.()
    end
  end

  # The database uniqueness constraint is durable; this lock also lets concurrent local retries
  # return the stored result instead of racing to insert it.
  defp with_operation_lock(operation_id, fun) do
    :global.trans({{__MODULE__, :operation}, operation_id}, fun)
  end

  defp group_payload(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => refundable_until_payload(group),
      "status" => group.status,
      "revision" => group.revision,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp applied(fields), do: Map.merge(%{"status" => "applied"}, fields)

  defp reject(code, fields \\ %{}), do: rejected(nil, code, fields)

  defp unexpected_changeset!(changeset) do
    raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
  end

  defp rejected(operation_id, code, fields \\ %{}) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    |> Map.merge(fields)
  end

  defp group_result(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) -> %{"group_id" => group_id}
      _ -> %{}
    end
  end
end
