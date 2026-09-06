defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditLot}
  alias GroupStay.Operations.Record
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @new_flexible_policy_on ~D[2027-01-01]

  def submit(operations), do: Enum.map(operations, &process/1)

  def get_operation(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> restore_result(record.result)
    end
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        rooms = Repo.all(from r in Room, where: r.group_id == ^group_id, order_by: r.position)
        serialize_group(group, rooms)
    end
  end

  def guest_credit(guest_id, on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on and
              lot.expires_on >= ^on,
          order_by: [lot.expires_on, lot.source_operation_id, lot.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        cash =
          Repo.one(
            from g in Group,
              select: %{
                cash_held_cents:
                  fragment(
                    "COALESCE(SUM(CASE WHEN ? = 'active' THEN ? - ? ELSE 0 END), 0)",
                    g.status,
                    g.deposit_paid_cents,
                    g.credit_paid_cents
                  ),
                cash_refunded_cents: fragment("COALESCE(SUM(?), 0)", g.refunded_cents),
                cash_retained_cents: fragment("COALESCE(SUM(?), 0)", g.retained_cents),
                cash_converted_to_credit_cents:
                  fragment("COALESCE(SUM(?), 0)", g.cash_converted_to_credit_cents)
              }
          )

        available_credit =
          Repo.one(
            from lot in CreditLot,
              where: lot.remaining_cents > 0 and lot.issued_on <= ^on and lot.expires_on >= ^on,
              select: fragment("COALESCE(SUM(?), 0)", lot.remaining_cents)
          )

        applied_credit =
          Repo.one(
            from allocation in CreditAllocation,
              join: g in Group,
              on: g.group_id == allocation.group_id,
              join: lot in CreditLot,
              on: lot.id == allocation.credit_lot_id,
              where: g.status == "active" and lot.issued_on <= ^on,
              select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
          )

        Map.put(cash, :credit_liability_cents, available_credit + applied_credit)
      end)

    totals
  end

  def reporting_date(nil), do: {:ok, Date.utc_today()}

  def reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_date"}
    end
  end

  def reporting_date(_value), do: {:error, "invalid_date"}

  defp process(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    {:ok, result} =
      Repo.transaction(
        fn -> process_idempotently(operation_id, operation) end,
        mode: :immediate
      )

    result
  end

  defp process(operation), do: reject(operation, "invalid_operation")

  defp process_idempotently(operation_id, operation) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil ->
        result = operation |> dispatch() |> normalize_result()

        %Record{}
        |> Record.changeset(%{
          operation_id: operation_id,
          operation_type: submitted_type(operation),
          submitted_content: operation,
          result: result
        })
        |> Repo.insert!()

        result

      record ->
        if record.submitted_content === operation do
          restore_result(record.result)
        else
          reject(operation, "operation_id_conflict")
        end
    end
  end

  defp dispatch(%{"type" => type} = operation) do
    case type do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> update_group(operation, &record_cash_payment/2)
      "apply_hotel_credit" -> update_group(operation, &apply_hotel_credit/2)
      "reschedule_group" -> update_group(operation, &reschedule_group/2)
      "cancel_group" -> update_group(operation, &cancel_group/2)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp dispatch(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with {:ok, fields} <- open_fields(operation),
         {:ok, booked_on} <- parse_required_date(fields.occurred_on, "invalid_operation"),
         {:ok, arrival_on} <- parse_required_date(fields.arrival_on, "invalid_stay"),
         {:ok, departure_on} <- parse_required_date(fields.departure_on, "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(fields.rate_plan),
         {:ok, rooms} <- validate_rooms(fields.rooms) do
      nights = Date.diff(departure_on, arrival_on)

      lodging_total_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          total + room.nightly_rate_cents * nights
        end)

      deposit_due_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          lodging = room.nightly_rate_cents * nights
          total + room_deposit(fields.rate_plan, lodging)
        end)

      attrs = %{
        group_id: fields.group_id,
        guest_id: fields.guest_id,
        property_id: fields.property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: fields.rate_plan,
        policy_version: policy_version(fields.rate_plan, booked_on),
        status: "active",
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1
      }

      case insert_group(attrs, rooms) do
        :ok ->
          applied(operation, %{
            group_id: fields.group_id,
            deposit_due_cents: deposit_due_cents,
            revision: 1
          })

        {:error, :group_already_exists} ->
          reject(operation, "group_already_exists")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp insert_group(attrs, rooms) do
    case Repo.insert(Group.create_changeset(%Group{}, attrs)) do
      {:ok, _group} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            %{
              group_id: attrs.group_id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: position,
              inserted_at: now,
              updated_at: now
            }
          end)

        {_count, nil} = Repo.insert_all(Room, room_rows)
        :ok

      {:error, changeset} ->
        if changeset.errors[:group_id] do
          {:error, :group_already_exists}
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp update_group(operation, apply_operation) do
    case operation do
      %{"group_id" => group_id} when is_binary(group_id) and group_id != "" ->
        case Repo.get(Group, group_id) do
          nil ->
            reject(operation, "group_not_found")

          group ->
            with :ok <- validate_expected_revision(operation, group),
                 :ok <- validate_active(group) do
              apply_operation.(operation, group)
            else
              {:error, "stale_revision"} -> stale(operation, group)
              {:error, code} -> reject(operation, code)
            end
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp record_cash_payment(operation, group) do
    case operation do
      %{"occurred_on" => occurred_on, "amount_cents" => amount_cents} ->
        case parse_required_date(occurred_on, "invalid_operation") do
          {:ok, _occurred_on} ->
            outstanding = group.deposit_due_cents - group.deposit_paid_cents

            cond do
              not (is_integer(amount_cents) and amount_cents > 0) ->
                reject(operation, "invalid_amount")

              amount_cents > outstanding ->
                reject(operation, "payment_exceeds_outstanding")

              true ->
                revision = group.revision + 1
                paid = group.deposit_paid_cents + amount_cents

                group
                |> Group.update_changeset(%{deposit_paid_cents: paid, revision: revision})
                |> Repo.update!()

                applied(operation, %{
                  group_id: group.group_id,
                  amount_cents: amount_cents,
                  outstanding_deposit_cents: group.deposit_due_cents - paid,
                  revision: revision
                })
            end

          {:error, code} ->
            reject(operation, code)
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp apply_hotel_credit(operation, group) do
    case operation do
      %{"occurred_on" => occurred_on, "amount_cents" => amount_cents} ->
        with {:ok, occurred_on} <- parse_required_date(occurred_on, "invalid_operation") do
          outstanding = group.deposit_due_cents - group.deposit_paid_cents

          cond do
            not (is_integer(amount_cents) and amount_cents > 0) ->
              reject(operation, "invalid_amount")

            amount_cents > outstanding ->
              reject(operation, "payment_exceeds_outstanding")

            true ->
              lots = available_credit_lots(group.guest_id, occurred_on)

              if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
                reject(operation, "insufficient_credit")
              else
                consume_credit(lots, amount_cents, group.group_id)

                revision = group.revision + 1
                paid = group.deposit_paid_cents + amount_cents

                group
                |> Group.update_changeset(%{
                  deposit_paid_cents: paid,
                  credit_paid_cents: group.credit_paid_cents + amount_cents,
                  revision: revision
                })
                |> Repo.update!()

                applied(operation, %{
                  group_id: group.group_id,
                  amount_cents: amount_cents,
                  outstanding_deposit_cents: group.deposit_due_cents - paid,
                  revision: revision
                })
              end
          end
        else
          {:error, code} -> reject(operation, code)
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp reschedule_group(operation, group) do
    with %{"occurred_on" => occurred_on, "new_arrival_on" => new_arrival_on} <- operation,
         {:ok, occurred_on} <- parse_required_date(occurred_on, "invalid_stay"),
         {:ok, new_arrival_on} <- parse_required_date(new_arrival_on, "invalid_stay"),
         true <- Date.after?(new_arrival_on, occurred_on) do
      new_departure_on = Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))
      revision = group.revision + 1

      group
      |> Group.update_changeset(%{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        revision: revision
      })
      |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: new_arrival_on,
        new_departure_on: new_departure_on,
        policy_version: group.policy_version,
        refundable_until: refundable_until(group.policy_version, new_arrival_on),
        revision: revision
      })
    else
      {:error, code} -> reject(operation, code)
      false -> reject(operation, "invalid_stay")
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp cancel_group(operation, group) do
    case operation do
      %{"occurred_on" => occurred_on} ->
        case parse_required_date(occurred_on, "invalid_operation") do
          {:ok, occurred_on} ->
            case Map.get(operation, "refund_method", "cash") do
              refund_method when refund_method in ["cash", "hotel_credit"] ->
                settle_cancellation(operation, group, occurred_on, refund_method)

              _other ->
                reject(operation, "invalid_operation")
            end

          {:error, code} ->
            reject(operation, code)
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp settle_cancellation(operation, group, occurred_on, refund_method) do
    refundable = refundable?(group, occurred_on)

    if refund_method == "hotel_credit" and not refundable do
      reject(operation, "refund_method_not_available")
    else
      cash_paid_cents = group.deposit_paid_cents - group.credit_paid_cents

      {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
        cancellation_amounts(refundable, refund_method, cash_paid_cents)

      settle_credit_allocations(group.group_id, occurred_on, refundable)

      if credit_issued_cents > 0 do
        %CreditLot{}
        |> CreditLot.changeset(%{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          issued_on: occurred_on,
          expires_on: Date.add(occurred_on, 365),
          remaining_cents: credit_issued_cents
        })
        |> Repo.insert!()
      end

      revision = group.revision + 1

      group
      |> Group.update_changeset(%{
        status: "cancelled",
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        cash_converted_to_credit_cents: converted_cents,
        revision: revision
      })
      |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: revision
      })
    end
  end

  defp available_credit_lots(guest_id, occurred_on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.issued_on <= ^occurred_on and lot.expires_on >= ^occurred_on,
        order_by: [lot.expires_on, lot.source_operation_id, lot.id]
    )
  end

  defp consume_credit(lots, amount_cents, group_id) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining ->
      if remaining == 0 do
        {:halt, 0}
      else
        consumed = min(lot.remaining_cents, remaining)

        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - consumed})
        |> Repo.update!()

        %CreditAllocation{}
        |> CreditAllocation.changeset(%{
          group_id: group_id,
          credit_lot_id: lot.id,
          amount_cents: consumed
        })
        |> Repo.insert!()

        {:cont, remaining - consumed}
      end
    end)
  end

  defp settle_credit_allocations(group_id, occurred_on, refundable) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where: allocation.group_id == ^group_id,
          preload: [credit_lot: lot]
      )

    Enum.each(allocations, fn allocation ->
      lot = allocation.credit_lot

      if refundable and not Date.before?(lot.expires_on, occurred_on) do
        lot
        |> CreditLot.changeset(%{
          remaining_cents: lot.remaining_cents + allocation.amount_cents
        })
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp cancellation_amounts(true, "cash", cash_paid_cents) do
    {cash_paid_cents, 0, 0, 0}
  end

  defp cancellation_amounts(true, "hotel_credit", cash_paid_cents) do
    credit_issued_cents = cash_paid_cents + percentage(cash_paid_cents, 10)
    {0, 0, cash_paid_cents, credit_issued_cents}
  end

  defp cancellation_amounts(false, "cash", cash_paid_cents) do
    {0, cash_paid_cents, 0, 0}
  end

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, @new_flexible_policy_on), do: "flex-14", else: "flex-30"
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group.policy_version, group.arrival_on) do
      nil -> false
      cutoff -> not Date.after?(occurred_on, cutoff)
    end
  end

  defp open_fields(operation) do
    required = [
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      {:ok,
       %{
         occurred_on: operation["occurred_on"],
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         arrival_on: operation["arrival_on"],
         departure_on: operation["departure_on"],
         rate_plan: operation["rate_plan"],
         rooms: operation["rooms"]
       }}
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    parsed =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}
        when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
               nightly_rate_cents > 0 ->
          %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}

        _ ->
          :invalid
      end)

    room_ids = Enum.map(parsed, &if(is_map(&1), do: &1.room_id, else: nil))

    if :invalid in parsed or length(Enum.uniq(room_ids)) != length(room_ids) do
      {:error, "invalid_rooms"}
    else
      {:ok, parsed}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_stay(arrival_on, departure_on) do
    if Date.before?(arrival_on, departure_on), do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, "invalid_rate_plan"}
  end

  defp validate_active(%Group{status: "active"}), do: :ok
  defp validate_active(_group), do: {:error, "group_not_active"}

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected > 0 ->
        if expected == group.revision, do: :ok, else: {:error, "stale_revision"}

      {:ok, _expected} ->
        {:error, "invalid_operation"}
    end
  end

  defp parse_required_date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, error_code}
    end
  end

  defp parse_required_date(_value, error_code), do: {:error, error_code}

  defp room_deposit("flexible", lodging_cents), do: percentage(lodging_cents, 20)
  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  defp percentage(cents, percent), do: div(cents * percent + 50, 100)

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(%{"type" => type}), do: Jason.encode!(type)
  defp submitted_type(_operation), do: nil

  defp normalize_result(result) do
    result
    |> Jason.encode!()
    |> Jason.decode!()
    |> restore_result()
  end

  defp restore_result(result) do
    Map.new(result, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp serialize_group(group, rooms) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group.policy_version, group.arrival_on),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.deposit_paid_cents - group.credit_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents:
        if(group.status == "active",
          do: group.deposit_due_cents - group.deposit_paid_cents,
          else: 0
        )
    }
  end

  defp applied(operation, fields) do
    Map.merge(
      %{operation_id: operation["operation_id"], status: "applied"},
      fields
    )
  end

  defp reject(operation, code, fields \\ %{}) do
    operation_id = if is_map(operation), do: operation["operation_id"], else: nil

    Map.merge(
      %{operation_id: operation_id, status: "rejected", code: code},
      fields
    )
  end

  defp stale(operation, group) do
    reject(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    })
  end
end
