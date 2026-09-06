defmodule GroupStay.Batches do
  alias GroupStay.Repo
  alias GroupStay.Group
  alias GroupStay.Room
  alias GroupStay.CreditLot
  alias GroupStay.CreditUsage
  alias GroupStay.OperationRecord
  alias GroupStay.RoomFunding
  import Ecto.Query

  @policy_cutoff ~D[2027-01-01]
  @credit_bonus_pct 10
  @credit_valid_days 365

  def policy_version_for(rate_plan, booked_on) do
    cond do
      rate_plan == "advance_purchase" -> "advance-nonrefundable"
      Date.compare(booked_on, @policy_cutoff) == :lt -> "flex-14"
      true -> "flex-30"
    end
  end

  def cancellation_window_days(%Group{policy_version: "flex-14"}), do: 14
  def cancellation_window_days(%Group{policy_version: "flex-30"}), do: 30

  def cancellation_window_days(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: 14, else: 30
  end

  def cancellation_window_days(_), do: nil

  def policy_version_of(%Group{policy_version: pv}) when is_binary(pv) and pv != "", do: pv
  def policy_version_of(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version_of(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    policy_version_for("flexible", booked_on)
  end

  def policy_version_of(_), do: nil

  def refundable_until_of(%Group{} = group) do
    pv = policy_version_of(group)

    case pv do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      _ -> nil
    end
  end

  def refundable?(%Group{rate_plan: "advance_purchase"}, _occurred_on), do: false

  def refundable?(%Group{} = group, occurred_on) do
    pv = policy_version_of(group)

    case pv do
      "advance-nonrefundable" -> false
      "flex-14" -> Date.diff(group.arrival_on, occurred_on) >= 14
      "flex-30" -> Date.diff(group.arrival_on, occurred_on) >= 30
      _ -> false
    end
  end

  def credit_bonus(cash_cents) when is_integer(cash_cents) and cash_cents >= 0 do
    div(cash_cents * @credit_bonus_pct + 50, 100)
  end

  defp effective_cash_paid(%Group{} = group) do
    try do
      case Map.fetch!(group, :cash_paid_cents) do
        v when is_integer(v) -> v
        _ -> group.deposit_paid_cents
      end
    rescue
      _ -> group.deposit_paid_cents
    end
  end

  defp effective_credit_paid(%Group{} = group) do
    try do
      case Map.fetch!(group, :credit_paid_cents) do
        v when is_integer(v) -> v
        _ -> 0
      end
    rescue
      _ -> 0
    end
  end

  defp has_column?(table, column) do
    # Detect at runtime so reads work both before and after the economics migration.
    case Repo.query("SELECT #{column} FROM #{table} LIMIT 0") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp has_table?(table) do
    case Repo.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table]) do
      {:ok, %{rows: [[_]]}} -> true
      {:ok, _} -> false
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp available_lots(guest_id, as_of) do
    # Remaining was decremented at apply time, so the stored remainder is
    # exactly the free balance before shortfall handling. Lots are available
    # strictly before `expires_on` (available through the day before it).
    # Lots carrying unrecovered clawback absorb returns before becoming
    # available; `remaining_cents` already reflects that (absorption reduces
    # unrecovered first, only excess increases remaining).
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation_durable/1)
  end

  # ---- durable idempotency ----
  # Every op with a usable operation_id is remembered durably together with the
  # domain changes in one transaction. Retries with equivalent payload return the
  # stored result verbatim; retries with a different payload get conflict.
  defp process_operation_durable(op) when not is_map(op) do
    %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
  end

  # Non-map ops and ops without a usable operation_id cannot be remembered.
  defp process_operation_durable(op) do
    raw_id = Map.get(op, "operation_id") || Map.get(op, :operation_id)

    operation_id =
      if is_binary(raw_id) and raw_id != "", do: raw_id, else: nil

    if is_nil(operation_id) do
      # No usable identifier: cannot be remembered; compute result directly.
      process_operation(op)
    else
      canonical = canonical_payload(op)

      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        %OperationRecord{} = existing ->
          if payloads_equivalent?(existing.payload_json, canonical) do
            Jason.decode!(existing.result_json)
          else
            conflict_result(operation_id, op)
          end

        nil ->
          run_operation_transactionally(operation_id, canonical, op)
      end
    end
  end

  defp conflict_result(operation_id, op) do
    base = %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => "operation_id_conflict"
    }

    case extract_group_id(op) do
      nil ->
        pid = Map.get(op, "payment_operation_id") || Map.get(op, :payment_operation_id)

        if is_binary(pid) and pid != "",
          do: Map.put(base, "payment_operation_id", pid),
          else: base

      gid ->
        Map.put(base, "group_id", gid)
    end
  end

  # Canonical payload: normalize map keys to strings recursively, preserving
  # array order and values. Key order is irrelevant.
  defp canonical_payload(term), do: normalize_term(term)

  defp normalize_term(%Date{} = d), do: Date.to_iso8601(d)
  defp normalize_term(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_term(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp normalize_term(%Time{} = t), do: Time.to_iso8601(t)
  defp normalize_term(%{__struct__: _} = s), do: normalize_term(Map.from_struct(s))

  defp normalize_term(map) when is_map(map) do
    map
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_term(v)}
      {k, v} when is_binary(k) -> {k, normalize_term(v)}
      {k, v} -> {to_string(k), normalize_term(v)}
    end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new()
  end

  defp normalize_term(list) when is_list(list), do: Enum.map(list, &normalize_term/1)
  defp normalize_term(other), do: other

  defp payloads_equivalent?(stored_json, canonical) when is_binary(stored_json) do
    case Jason.decode(stored_json) do
      {:ok, stored} -> stored == canonical
      _ -> false
    end
  end

  defp run_operation_transactionally(operation_id, canonical, op) do
    payload_json = Jason.encode!(canonical)
    op_type = operation_type_of(op)

    # Idempotency record and domain changes commit atomically. An unexpected
    # exception aborts the transaction (nothing remembered) and propagates
    # so the request fails with 500.
    Repo.transaction(
      fn ->
        # Reserve the identifier first so concurrent retries serialize here.
        placeholder_changeset =
          OperationRecord.changeset(%OperationRecord{}, %{
            operation_id: operation_id,
            operation_type: op_type,
            payload_json: payload_json,
            result_json: Jason.encode!(%{"__placeholder__" => true})
          })

        case Repo.insert(placeholder_changeset) do
          {:ok, placeholder} ->
            # Domain logic runs inside the same transaction so the
            # idempotency record and domain changes commit atomically.
            result = process_operation(op)

            result_json = Jason.encode!(result)

            placeholder
            |> OperationRecord.changeset(%{
              operation_type: op_type,
              result_json: result_json
            })
            |> Repo.update!()

            result

          {:error, changeset} ->
            if unique_conflict?(changeset) do
              # Lost the race: another transaction committed this
              # operation_id. Roll back and serve the winner's record.
              Repo.rollback({:conflict_retry, operation_id, canonical})
            else
              Repo.rollback(:unexpected)
            end
        end
      end,
      timeout: 15_000
    )
    |> case do
      {:ok, result} ->
        result

      {:error, {:conflict_retry, op_id, canon}} ->
        # Re-read the committed record outside our rolled-back transaction.
        case Repo.get_by(OperationRecord, operation_id: op_id) do
          %OperationRecord{} = existing ->
            if payloads_equivalent?(existing.payload_json, canon) do
              Jason.decode!(existing.result_json)
            else
              conflict_result(op_id, op)
            end

          nil ->
            # Extremely unlikely: winner rolled back. Retry once.
            run_operation_transactionally(op_id, canon, op)
        end

      {:error, :unexpected} ->
        raise "unexpected operation failure"
    end
  end

  defp unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp operation_type_of(op) do
    t = Map.get(op, "type") || Map.get(op, :type)
    if is_binary(t), do: t, else: nil
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :not_found
      %OperationRecord{result_json: json} -> {:ok, Jason.decode!(json)}
    end
  end

  def get_operation(_), do: :not_found

  defp process_operation(op) do
    operation_id = Map.get(op, "operation_id") || Map.get(op, :operation_id)
    type = Map.get(op, "type") || Map.get(op, :type)

    op_id_valid? = is_binary(operation_id) and operation_id != ""

    if not op_id_valid? or not is_binary(type) do
      %{
        "operation_id" => if(op_id_valid?, do: operation_id, else: nil),
        "status" => "rejected",
        "code" => "invalid_operation"
      }
      |> maybe_put_group_id(extract_group_id(op))
    else
      case type do
        "open_group" ->
          apply_open_group(op, operation_id)

        "record_cash_payment" ->
          apply_payment(op, operation_id)

        "reschedule_group" ->
          apply_reschedule(op, operation_id)

        "apply_hotel_credit" ->
          apply_credit(op, operation_id)

        "cancel_group" ->
          apply_cancel(op, operation_id)

        "cancel_rooms" ->
          apply_cancel_rooms(op, operation_id)

        "reduce_cash_payment" ->
          apply_reduce_cash(op, operation_id)

        "charge_back_payment" ->
          apply_charge_back(op, operation_id)

        _ ->
          %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
          |> maybe_put_group_id(extract_group_id(op))
      end
    end
  end

  defp extract_group_id(op) when is_map(op) do
    gid = Map.get(op, "group_id") || Map.get(op, :group_id)

    if is_binary(gid) do
      gid
    else
      pid = Map.get(op, "payment_operation_id") || Map.get(op, :payment_operation_id)

      if is_binary(pid) and pid != "" do
        case Repo.get_by(OperationRecord, operation_id: pid) do
          %OperationRecord{result_json: json} ->
            case Jason.decode(json) do
              {:ok, %{"group_id" => g}} when is_binary(g) -> g
              _ -> nil
            end

          _ ->
            nil
        end
      else
        nil
      end
    end
  end

  defp maybe_put_group_id(result, nil), do: result
  defp maybe_put_group_id(result, gid), do: Map.put(result, "group_id", gid)

  defp parse_date(nil), do: :error
  defp parse_date(%Date{} = d), do: {:ok, d}

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> {:ok, d}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp get_string(map, key) do
    v = Map.get(map, key) || Map.get(map, String.to_atom(key))
    if is_binary(v) and v != "", do: {:ok, v}, else: :error
  end

  # ---- OPEN ----
  defp apply_open_group(op, operation_id) do
    group_id =
      case get_string(op, "group_id") do
        {:ok, v} -> v
        :error -> nil
      end

    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)

    if is_nil(group_id) do
      %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
    else
      with {:occurred, {:ok, occurred_on}} <- {:occurred, parse_date(occurred_raw)},
           {:guest, {:ok, guest_id}} <- {:guest, get_string(op, "guest_id")},
           {:property, {:ok, property_id}} <- {:property, get_string(op, "property_id")} do
        # check existence
        case Repo.get_by(Group, group_id: group_id) do
          %Group{} ->
            %{
              "operation_id" => operation_id,
              "status" => "rejected",
              "code" => "group_already_exists",
              "group_id" => group_id
            }

          nil ->
            rate_plan = Map.get(op, "rate_plan") || Map.get(op, :rate_plan)

            if rate_plan not in ["flexible", "advance_purchase"] do
              %{
                "operation_id" => operation_id,
                "status" => "rejected",
                "code" => "invalid_rate_plan",
                "group_id" => group_id
              }
            else
              arrival_raw = Map.get(op, "arrival_on") || Map.get(op, :arrival_on)
              departure_raw = Map.get(op, "departure_on") || Map.get(op, :departure_on)

              with {:ok, arrival_on} <- parse_date_result(arrival_raw),
                   {:ok, departure_on} <- parse_date_result(departure_raw),
                   true <- Date.compare(departure_on, arrival_on) == :gt do
                nights = Date.diff(departure_on, arrival_on)
                rooms_raw = Map.get(op, "rooms") || Map.get(op, :rooms)

                case validate_rooms(rooms_raw) do
                  {:error, :invalid_rooms} ->
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "invalid_rooms",
                      "group_id" => group_id
                    }

                  {:ok, rooms} ->
                    {lodging_total, deposit_due} = compute_totals(rooms, nights, rate_plan)
                    policy_version = policy_version_for(rate_plan, occurred_on)

                    case insert_group(%{
                           group_id: group_id,
                           guest_id: guest_id,
                           property_id: property_id,
                           booked_on: occurred_on,
                           arrival_on: arrival_on,
                           departure_on: departure_on,
                           rate_plan: rate_plan,
                           policy_version: policy_version,
                           rooms: rooms,
                           lodging_total_cents: lodging_total,
                           deposit_due_cents: deposit_due
                         }) do
                      {:ok, _group} ->
                        %{
                          "operation_id" => operation_id,
                          "status" => "applied",
                          "group_id" => group_id,
                          "deposit_due_cents" => deposit_due,
                          "revision" => 1
                        }

                      {:error, :exists} ->
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "group_already_exists",
                          "group_id" => group_id
                        }
                    end
                end
              else
                _ ->
                  %{
                    "operation_id" => operation_id,
                    "status" => "rejected",
                    "code" => "invalid_stay",
                    "group_id" => group_id
                  }
              end
            end
        end
      else
        _ ->
          %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
          |> maybe_put_group_id(group_id)
      end
    end
  end

  defp parse_date_result(v) do
    case parse_date(v) do
      {:ok, d} -> {:ok, d}
      :error -> :error
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and length(rooms) > 0 do
    if Enum.all?(rooms, &is_map/1) do
      parsed =
        Enum.map(rooms, fn r ->
          room_id = Map.get(r, "room_id") || Map.get(r, :room_id)
          rate = Map.get(r, "nightly_rate_cents") || Map.get(r, :nightly_rate_cents)
          {room_id, rate}
        end)

      valid? =
        Enum.all?(parsed, fn
          {room_id, rate}
          when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
            true

          _ ->
            false
        end)

      ids = Enum.map(parsed, fn {id, _} -> id end)

      if valid? and length(Enum.uniq(ids)) == length(ids) do
        {:ok, Enum.map(parsed, fn {id, rate} -> %{room_id: id, nightly_rate_cents: rate} end)}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp compute_totals(rooms, nights, "flexible") do
    lodging_total = Enum.reduce(rooms, 0, fn r, acc -> acc + nights * r.nightly_rate_cents end)

    deposit_due =
      Enum.reduce(rooms, 0, fn r, acc ->
        lodging = nights * r.nightly_rate_cents
        acc + div(lodging * 20 + 50, 100)
      end)

    {lodging_total, deposit_due}
  end

  defp compute_totals(rooms, nights, "advance_purchase") do
    lodging_total = Enum.reduce(rooms, 0, fn r, acc -> acc + nights * r.nightly_rate_cents end)
    {lodging_total, lodging_total}
  end

  defp insert_group(attrs) do
    Repo.transaction(fn ->
      group_changeset =
        %Group{}
        |> Group.changeset(%{
          group_id: attrs.group_id,
          guest_id: attrs.guest_id,
          property_id: attrs.property_id,
          booked_on: attrs.booked_on,
          arrival_on: attrs.arrival_on,
          departure_on: attrs.departure_on,
          rate_plan: attrs.rate_plan,
          policy_version:
            Map.get(attrs, :policy_version) ||
              policy_version_for(attrs.rate_plan, attrs.booked_on),
          status: "active",
          revision: 1,
          lodging_total_cents: attrs.lodging_total_cents,
          deposit_due_cents: attrs.deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0
        })

      case Repo.insert(group_changeset) do
        {:ok, group} ->
          nights = Date.diff(attrs.departure_on, attrs.arrival_on)

          attrs.rooms
          |> Enum.with_index()
          |> Enum.each(fn {r, idx} ->
            lodging = nights * r.nightly_rate_cents

            deposit =
              if attrs.rate_plan == "flexible" do
                div(lodging * 20 + 50, 100)
              else
                lodging
              end

            {:ok, _} =
              %Room{}
              |> Room.changeset(%{
                group_db_id: group.id,
                room_id: r.room_id,
                nightly_rate_cents: r.nightly_rate_cents,
                position: idx,
                lodging_cents: lodging,
                deposit_due_cents: deposit,
                cash_paid_cents: 0,
                credit_paid_cents: 0,
                status: "active"
              })
              |> Repo.insert()
          end)

          group

        {:error, changeset} ->
          if has_unique_violation?(changeset) do
            Repo.rollback(:exists)
          else
            Repo.rollback(:invalid)
          end
      end
    end)
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, :exists} -> {:error, :exists}
      {:error, _} -> {:error, :exists}
    end
  end

  # ---- room accounting ----
  # Fundings are per-room allocations of cash/credit. Ordering: legacy
  # (unattributed senior block) first, then durable funding in durable-record
  # commit order (operation_records.id order).
  defp funded_seq_next(group_db_id) do
    Repo.aggregate(
      from(f in RoomFunding, where: f.group_db_id == ^group_db_id),
      :max,
      :seq
    ) || 0
  end

  defp group_rooms(group_db_id) do
    Repo.all(from r in Room, where: r.group_db_id == ^group_db_id, order_by: r.position)
  end

  defp ensure_room_accounting(%Group{} = group) do
    rooms = group_rooms(group.id)

    seeded? =
      try do
        Map.get(group, :room_accounting_seeded) == true
      rescue
        _ -> false
      end

    if seeded? do
      {group, rooms}
    else
      # Lazily migrate data that predates request 04 (in particular funding
      # from before durable operation records existed):
      #  1. enrich room per-row lodging/deposit fields;
      #  2. bring aggregate funding forward as ONE unattributed senior block
      #     per group: aggregate cash first, then hotel-credit lots in
      #     original consumption order (CreditUsage id order within the
      #     group == consumption order);
      #  3. replay recorded funding (applied cash payments + hotel-credit
      #     applications with durable records) afterwards in durable-record
      #     commit order (operation_records.id), regardless of occurred_on.
      # Aggregate cash/credit/liability balances never change here.
      group = Repo.get!(Group, group.id)
      rooms = group_rooms(group.id)
      nights = Date.diff(group.departure_on, group.arrival_on)

      Enum.each(rooms, fn r ->
        lodging =
          if r.lodging_cents not in [nil, 0],
            do: r.lodging_cents,
            else: nights * r.nightly_rate_cents

        deposit =
          if r.deposit_due_cents not in [nil, 0] do
            r.deposit_due_cents
          else
            if group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
          end

        r
        |> Room.changeset(%{
          lodging_cents: lodging,
          deposit_due_cents: deposit,
          status: r.status || "active"
        })
        |> Repo.update!()
      end)

      rooms = group_rooms(group.id)

      # Only active groups carry held funding. Cancelled groups keep their
      # historical aggregates; nothing to seed (settled history never moves
      # through reduce/chargeback paths and needs no per-room rows).
      if group.status == "cancelled" do
        group
        |> Group.changeset(%{room_accounting_seeded: true})
        |> Repo.update!()

        {Repo.get!(Group, group.id), group_rooms(group.id)}
      else
        cash_total =
          try do
            group.cash_paid_cents || 0
          rescue
            _ -> group.deposit_paid_cents
          end

        credit_total =
          try do
            group.credit_paid_cents || 0
          rescue
            _ -> 0
          end

        existing_fundings = Repo.all(from f in RoomFunding, where: f.group_db_id == ^group.id)

        if existing_fundings == [] and (cash_total > 0 or credit_total > 0) do
          durably_recorded = durably_recorded_funding(group)

          legacy_cash = max(cash_total - durably_recorded.cash, 0)
          legacy_credit_usages = legacy_credit_split(group, durably_recorded)

          seq = 0

          seq =
            if legacy_cash > 0,
              do: allocate_block(group.id, rooms, legacy_cash, "legacy_cash", nil, nil, seq),
              else: seq

          # Legacy credit: aggregate lots in original consumption order.
          seq =
            Enum.reduce(legacy_credit_usages, seq, fn u, s ->
              rooms_now = group_rooms(group.id)

              allocate_block(
                group.id,
                rooms_now,
                u.amount_cents,
                "legacy_credit",
                nil,
                u.credit_lot_id,
                s
              )
            end)

          # Recorded funding in durable-record commit order (operation id),
          # regardless of occurred_on. Each recorded cash payment / credit
          # application allocates in processing order across rooms.
          recorded_ops = durably_recorded.ops

          Enum.reduce(recorded_ops, seq, fn op, s ->
            rooms_now = group_rooms(group.id)

            case op do
              {:cash, op_id, amount} ->
                allocate_block(group.id, rooms_now, amount, "cash", op_id, nil, s)

              {:credit, op_id, lot_id, amount} ->
                allocate_block(group.id, rooms_now, amount, "credit", op_id, lot_id, s)
            end
          end)
        end

        group
        |> Group.changeset(%{room_accounting_seeded: true})
        |> Repo.update!()

        {Repo.get!(Group, group.id), group_rooms(group.id)}
      end
    end
  end

  # Durably recorded funding for a group: applied cash payments + credit
  # applications with operation records, in commit (operation_records.id)
  # order. Returns %{cash: total, ops: [{:cash|:credit, op_id, ...}]}.
  defp durably_recorded_funding(group) do
    cash_recs =
      Repo.all(
        from r in OperationRecord,
          where: r.operation_type == "record_cash_payment",
          order_by: r.id
      )
      |> Enum.filter(fn rec ->
        with {:ok, payload} <- Jason.decode(rec.payload_json),
             %{"group_id" => gid} <- payload,
             true <- gid == group.group_id,
             {:ok, %{"status" => "applied", "amount_cents" => amt}} <-
               Jason.decode(rec.result_json),
             true <- is_integer(amt) and amt > 0 do
          true
        else
          _ -> false
        end
      end)

    cash_ops =
      Enum.map(cash_recs, fn rec ->
        {:ok, %{"amount_cents" => amt}} = Jason.decode(rec.result_json)
        {:cash, rec.operation_id, amt, rec.id}
      end)

    credit_recs =
      Repo.all(
        from r in OperationRecord,
          where: r.operation_type == "apply_hotel_credit",
          order_by: r.id
      )
      |> Enum.filter(fn rec ->
        with {:ok, payload} <- Jason.decode(rec.payload_json),
             %{"group_id" => gid} <- payload,
             true <- gid == group.group_id,
             {:ok, %{"status" => "applied", "amount_cents" => amt}} <-
               Jason.decode(rec.result_json),
             true <- is_integer(amt) and amt > 0 do
          true
        else
          _ -> false
        end
      end)

    credit_ops_with_lots =
      Enum.flat_map(credit_recs, fn rec ->
        usages =
          Repo.all(
            from u in CreditUsage,
              join: l in CreditLot,
              on: l.id == u.credit_lot_id,
              where: u.group_db_id == ^group.id and l.source_operation_id == ^rec.operation_id,
              order_by: u.id
          )
          |> Enum.map(fn u ->
            {:credit, rec.operation_id, u.credit_lot_id, u.amount_cents, rec.id}
          end)

        # Fallback: if usages were cleaned (shouldn't be for active groups),
        # attribute the whole applied amount without a lot link.
        if usages == [] do
          {:ok, %{"amount_cents" => amt}} = Jason.decode(rec.result_json)
          [{:credit, rec.operation_id, nil, amt, rec.id}]
        else
          usages
        end
      end)

    all =
      (Enum.map(cash_ops, fn {:cash, op, amt, id} -> {:cash, op, amt, id} end) ++
         Enum.map(credit_ops_with_lots, fn
           {:credit, op, lot, amt, id} -> {:credit, op, lot, amt, id}
         end))
      |> Enum.sort_by(fn
        {:cash, _, _, id} -> id
        {:credit, _, _, _, id} -> id
      end)

    ops =
      Enum.map(all, fn
        {:cash, op, amt, _} -> {:cash, op, amt}
        {:credit, op, lot, amt, _} -> {:credit, op, lot, amt}
      end)

    cash_total = Enum.reduce(cash_ops, 0, fn {:cash, _, amt, _}, acc -> acc + amt end)

    %{cash: cash_total, ops: ops}
  end

  # Credit usages belonging to this group that are NOT represented by durable
  # credit-application records (i.e. legacy credit), in original consumption
  # order (CreditUsage id order).
  defp legacy_credit_split(group, durably_recorded) do
    durable_keys =
      durably_recorded.ops
      |> Enum.filter(fn
        {:credit, _, _, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:credit, op, lot, amt} -> {op, lot, amt} end)
      |> MapSet.new()

    Repo.all(from u in CreditUsage, where: u.group_db_id == ^group.id, order_by: u.id)
    |> Enum.reject(fn u ->
      # A usage is "recorded" when its lot links back to a durable
      # apply_hotel_credit record for this group with the same amount. Since
      # one apply op may create several usage rows (one per lot), match on
      # (lot, amount) pairs.
      lot =
        try do
          Repo.get(CreditLot, u.credit_lot_id)
        rescue
          _ -> nil
        end

      lot != nil and
        Enum.any?(durable_keys, fn {op, lot_id, amt} ->
          lot.source_operation_id == op and lot_id == u.credit_lot_id and amt == u.amount_cents
        end)
    end)
  end

  # Allocate `amount` cents across active rooms in position order, filling one
  # room's remaining deposit need before moving to the next. Creates one
  # RoomFunding row per (room, chunk). Returns next seq.
  defp allocate_block(group_db_id, rooms, amount, kind, source_op_id, credit_lot_id, seq)
       when is_integer(amount) and amount >= 0 do
    active = Enum.filter(rooms, &(&1.status != "cancelled"))
    do_allocate(group_db_id, active, amount, kind, source_op_id, credit_lot_id, seq)
  end

  defp do_allocate(_group_db_id, _rooms, amount, _kind, _src, _lot, seq) when amount <= 0, do: seq

  defp do_allocate(group_db_id, rooms, amount, kind, src, lot, seq) do
    Enum.reduce_while(rooms, {amount, seq}, fn room, {left, s} ->
      if left <= 0 do
        {:halt, {left, s}}
      else
        held_cash = room.cash_paid_cents || 0
        held_credit = room.credit_paid_cents || 0
        due = room.deposit_due_cents || 0
        room_open = due - (held_cash + held_credit)

        if room_open <= 0 do
          {:cont, {left, s}}
        else
          take = min(room_open, left)
          ns = s + 1

          %RoomFunding{}
          |> RoomFunding.changeset(%{
            group_db_id: group_db_id,
            room_db_id: room.id,
            kind: kind,
            source_operation_id: src,
            credit_lot_id: lot,
            amount_cents: take,
            seq: ns
          })
          |> Repo.insert!()

          room
          |> Room.changeset(%{
            cash_paid_cents:
              if(kind in ["cash", "legacy_cash"], do: held_cash + take, else: held_cash),
            credit_paid_cents:
              if(kind in ["credit", "legacy_credit"], do: held_credit + take, else: held_credit)
          })
          |> Repo.update!()

          {:cont, {left - take, ns}}
        end
      end
    end)
    |> elem(1)
  end

  defp has_unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # ---- helpers for addressed ops ----
  defp fetch_group(group_id) when is_binary(group_id) and group_id != "" do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :not_found
      group -> {:ok, group}
    end
  end

  defp fetch_group(_), do: :no_id

  defp check_expected_revision(op, group) do
    raw =
      cond do
        Map.has_key?(op, "expected_revision") -> Map.get(op, "expected_revision")
        Map.has_key?(op, :expected_revision) -> Map.get(op, :expected_revision)
        true -> :absent
      end

    case raw do
      :absent ->
        :ok

      v when is_integer(v) ->
        if v == group.revision do
          :ok
        else
          {:stale, v, group.revision}
        end

      _ ->
        :invalid_expected
    end
  end

  defp stale_result(operation_id, group_id, expected, actual) do
    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group_id,
      "expected_revision" => expected,
      "actual_revision" => actual
    }
  end

  # ---- PAYMENT ----
  defp apply_payment(op, operation_id) do
    group_id = Map.get(op, "group_id") || Map.get(op, :group_id)
    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)

    if not is_binary(group_id) or group_id == "" do
      %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
    else
      case parse_date(occurred_raw) do
        :error ->
          %{
            "operation_id" => operation_id,
            "status" => "rejected",
            "code" => "invalid_operation",
            "group_id" => group_id
          }

        {:ok, _occurred} ->
          case fetch_group(group_id) do
            :not_found ->
              %{
                "operation_id" => operation_id,
                "status" => "rejected",
                "code" => "group_not_found",
                "group_id" => group_id
              }

            {:ok, group} ->
              case check_expected_revision(op, group) do
                {:stale, exp, actual} ->
                  stale_result(operation_id, group_id, exp, actual)

                :invalid_expected ->
                  %{
                    "operation_id" => operation_id,
                    "status" => "rejected",
                    "code" => "invalid_operation",
                    "group_id" => group_id
                  }

                :ok ->
                  if group.status != "active" do
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "group_not_active",
                      "group_id" => group_id
                    }
                  else
                    amount = Map.get(op, "amount_cents") || Map.get(op, :amount_cents)

                    if not is_integer(amount) or amount <= 0 do
                      %{
                        "operation_id" => operation_id,
                        "status" => "rejected",
                        "code" => "invalid_amount",
                        "group_id" => group_id
                      }
                    else
                      {group2, _rooms} = ensure_room_accounting(group)
                      outstanding = group2.deposit_due_cents - group2.deposit_paid_cents

                      if amount > outstanding do
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "payment_exceeds_outstanding",
                          "group_id" => group_id
                        }
                      else
                        cash_paid = effective_cash_paid(group2)
                        new_cash = cash_paid + amount
                        new_paid = group2.deposit_paid_cents + amount
                        new_revision = group2.revision + 1
                        new_outstanding = group2.deposit_due_cents - new_paid

                        {:ok, _} =
                          Repo.transaction(fn ->
                            group2
                            |> Group.changeset(%{
                              deposit_paid_cents: new_paid,
                              cash_paid_cents: new_cash,
                              revision: new_revision
                            })
                            |> Repo.update!()

                            rooms2 = group_rooms(group2.id)
                            seq = funded_seq_next(group2.id)

                            allocate_block(
                              group2.id,
                              rooms2,
                              amount,
                              "cash",
                              operation_id,
                              nil,
                              seq
                            )
                          end)

                        %{
                          "operation_id" => operation_id,
                          "status" => "applied",
                          "group_id" => group_id,
                          "amount_cents" => amount,
                          "outstanding_deposit_cents" => new_outstanding,
                          "revision" => new_revision
                        }
                      end
                    end
                  end
              end
          end
      end
    end
  end

  # ---- RESCHEDULE ----
  defp apply_reschedule(op, operation_id) do
    group_id = Map.get(op, "group_id") || Map.get(op, :group_id)
    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)

    if not is_binary(group_id) or group_id == "" do
      %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
    else
      case parse_date(occurred_raw) do
        :error ->
          %{
            "operation_id" => operation_id,
            "status" => "rejected",
            "code" => "invalid_operation",
            "group_id" => group_id
          }

        {:ok, occurred_on} ->
          case fetch_group(group_id) do
            :not_found ->
              %{
                "operation_id" => operation_id,
                "status" => "rejected",
                "code" => "group_not_found",
                "group_id" => group_id
              }

            {:ok, group} ->
              case check_expected_revision(op, group) do
                {:stale, exp, actual} ->
                  stale_result(operation_id, group_id, exp, actual)

                :invalid_expected ->
                  %{
                    "operation_id" => operation_id,
                    "status" => "rejected",
                    "code" => "invalid_operation",
                    "group_id" => group_id
                  }

                :ok ->
                  if group.status != "active" do
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "group_not_active",
                      "group_id" => group_id
                    }
                  else
                    new_arrival_raw =
                      Map.get(op, "new_arrival_on") || Map.get(op, :new_arrival_on)

                    case parse_date(new_arrival_raw) do
                      :error ->
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "invalid_stay",
                          "group_id" => group_id
                        }

                      {:ok, new_arrival} ->
                        if Date.compare(new_arrival, occurred_on) != :gt do
                          %{
                            "operation_id" => operation_id,
                            "status" => "rejected",
                            "code" => "invalid_stay",
                            "group_id" => group_id
                          }
                        else
                          shift = Date.diff(new_arrival, group.arrival_on)
                          new_departure = Date.add(group.departure_on, shift)
                          new_revision = group.revision + 1

                          {:ok, _} =
                            Repo.transaction(fn ->
                              group
                              |> Group.changeset(%{
                                arrival_on: new_arrival,
                                departure_on: new_departure,
                                revision: new_revision
                              })
                              |> Repo.update!()
                            end)

                          updated = Repo.get_by!(Group, id: group.id)
                          pv = policy_version_of(updated)
                          ru = refundable_until_of(updated)

                          %{
                            "operation_id" => operation_id,
                            "status" => "applied",
                            "group_id" => group_id,
                            "new_arrival_on" => Date.to_iso8601(new_arrival),
                            "new_departure_on" => Date.to_iso8601(new_departure),
                            "revision" => new_revision,
                            "policy_version" => pv,
                            "refundable_until" => if(ru, do: Date.to_iso8601(ru), else: nil)
                          }
                        end
                    end
                  end
              end
          end
      end
    end
  end

  # ---- APPLY CREDIT ----
  defp apply_credit(op, operation_id) do
    group_id = Map.get(op, "group_id") || Map.get(op, :group_id)
    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)

    if not is_binary(group_id) or group_id == "" do
      %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
    else
      case parse_date(occurred_raw) do
        :error ->
          %{
            "operation_id" => operation_id,
            "status" => "rejected",
            "code" => "invalid_operation",
            "group_id" => group_id
          }

        {:ok, occurred_on} ->
          case fetch_group(group_id) do
            :not_found ->
              %{
                "operation_id" => operation_id,
                "status" => "rejected",
                "code" => "group_not_found",
                "group_id" => group_id
              }

            {:ok, group} ->
              case check_expected_revision(op, group) do
                {:stale, exp, actual} ->
                  stale_result(operation_id, group_id, exp, actual)

                :invalid_expected ->
                  %{
                    "operation_id" => operation_id,
                    "status" => "rejected",
                    "code" => "invalid_operation",
                    "group_id" => group_id
                  }

                :ok ->
                  if group.status != "active" do
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "group_not_active",
                      "group_id" => group_id
                    }
                  else
                    amount = Map.get(op, "amount_cents") || Map.get(op, :amount_cents)

                    if not is_integer(amount) or amount <= 0 do
                      %{
                        "operation_id" => operation_id,
                        "status" => "rejected",
                        "code" => "invalid_amount",
                        "group_id" => group_id
                      }
                    else
                      {group2, _rooms0} = ensure_room_accounting(group)
                      outstanding = group2.deposit_due_cents - group2.deposit_paid_cents

                      if amount > outstanding do
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "payment_exceeds_outstanding",
                          "group_id" => group_id
                        }
                      else
                        lots = available_lots(group2.guest_id, occurred_on)
                        available = Enum.reduce(lots, 0, fn l, acc -> acc + l.remaining_cents end)

                        if available < amount do
                          %{
                            "operation_id" => operation_id,
                            "status" => "rejected",
                            "code" => "insufficient_credit",
                            "group_id" => group_id
                          }
                        else
                          plan = consume_plan(lots, amount)
                          new_paid = group2.deposit_paid_cents + amount
                          credit_paid = effective_credit_paid(group2)
                          new_credit = credit_paid + amount
                          new_revision = group2.revision + 1
                          new_outstanding = group2.deposit_due_cents - new_paid

                          {:ok, _} =
                            Repo.transaction(fn ->
                              Enum.each(plan, fn {lot, take} ->
                                stored = Repo.get!(CreditLot, lot.id)

                                stored
                                |> CreditLot.changeset(%{
                                  remaining_cents: stored.remaining_cents - take
                                })
                                |> Repo.update!()

                                %CreditUsage{}
                                |> CreditUsage.changeset(%{
                                  credit_lot_id: lot.id,
                                  group_db_id: group2.id,
                                  amount_cents: take
                                })
                                |> Repo.insert!()
                              end)

                              group2
                              |> Group.changeset(%{
                                deposit_paid_cents: new_paid,
                                credit_paid_cents: new_credit,
                                revision: new_revision
                              })
                              |> Repo.update!()

                              rooms2 = group_rooms(group2.id)
                              seq = funded_seq_next(group2.id)

                              Enum.reduce(plan, seq, fn {lot, take}, s ->
                                allocate_block(
                                  group2.id,
                                  group_rooms(group2.id),
                                  take,
                                  "credit",
                                  operation_id,
                                  lot.id,
                                  s
                                )
                              end)

                              _ = rooms2
                            end)

                          %{
                            "operation_id" => operation_id,
                            "status" => "applied",
                            "group_id" => group_id,
                            "amount_cents" => amount,
                            "outstanding_deposit_cents" => new_outstanding,
                            "revision" => new_revision
                          }
                        end
                      end
                    end
                  end
              end
          end
      end
    end
  end

  defp refund_method_of(op) do
    raw = Map.get(op, "refund_method") || Map.get(op, :refund_method)

    cond do
      is_nil(raw) -> {:ok, "cash"}
      raw in ["cash", "hotel_credit"] -> {:ok, raw}
      true -> :invalid
    end
  end

  defp consume_plan(lots, amount) do
    {plan, _} =
      Enum.reduce_while(lots, {[], amount}, fn lot, {acc, left} ->
        if left <= 0 do
          {:halt, {acc, left}}
        else
          take = min(lot.remaining_cents, left)
          {:cont, {[{lot, take} | acc], left - take}}
        end
      end)

    Enum.reverse(plan)
  end

  # ---- CANCEL ----
  defp apply_cancel(op, operation_id) do
    group_id = Map.get(op, "group_id") || Map.get(op, :group_id)
    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)

    if not is_binary(group_id) or group_id == "" do
      %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
    else
      case parse_date(occurred_raw) do
        :error ->
          %{
            "operation_id" => operation_id,
            "status" => "rejected",
            "code" => "invalid_operation",
            "group_id" => group_id
          }

        {:ok, occurred_on} ->
          case fetch_group(group_id) do
            :not_found ->
              %{
                "operation_id" => operation_id,
                "status" => "rejected",
                "code" => "group_not_found",
                "group_id" => group_id
              }

            {:ok, group} ->
              case check_expected_revision(op, group) do
                {:stale, exp, actual} ->
                  stale_result(operation_id, group_id, exp, actual)

                :invalid_expected ->
                  %{
                    "operation_id" => operation_id,
                    "status" => "rejected",
                    "code" => "invalid_operation",
                    "group_id" => group_id
                  }

                :ok ->
                  if group.status != "active" do
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "group_not_active",
                      "group_id" => group_id
                    }
                  else
                    case refund_method_of(op) do
                      :invalid ->
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "invalid_operation",
                          "group_id" => group_id
                        }

                      {:ok, refund_method_raw} ->
                        {group2, _} = ensure_room_accounting(group)
                        is_refundable = refundable?(group2, occurred_on)

                        if refund_method_raw == "hotel_credit" and not is_refundable do
                          %{
                            "operation_id" => operation_id,
                            "status" => "rejected",
                            "code" => "refund_method_not_available",
                            "group_id" => group_id
                          }
                        else
                          rooms_all = group_rooms(group2.id)
                          active_rooms = Enum.filter(rooms_all, &(&1.status != "cancelled"))
                          room_ids = Enum.map(active_rooms, & &1.room_id)

                          settle =
                            settle_rooms(
                              group2,
                              active_rooms,
                              occurred_on,
                              operation_id,
                              refund_method_raw,
                              is_refundable
                            )

                          new_revision = group2.revision + 1

                          Repo.transaction(fn ->
                            apply_settlement(group2, settle, new_revision, true)
                          end)

                          %{
                            "operation_id" => operation_id,
                            "status" => "applied",
                            "group_id" => group_id,
                            "refunded_cents" => settle.refunded,
                            "retained_cents" => settle.retained,
                            "revision" => new_revision,
                            "credit_issued_cents" => settle.credit_issued
                          }
                          |> then(fn base ->
                            _ = room_ids
                            base
                          end)
                        end
                    end
                  end
              end
          end
      end
    end
  end

  # ---- settlement core (shared by cancel_group and cancel_rooms) ----
  # Computes how selected active rooms settle. Returns a map describing cash
  # movements and credit restores. No DB writes here except reads.
  defp settle_rooms(
         group,
         selected_rooms,
         occurred_on,
         cancel_op_id,
         refund_method,
         is_refundable
       ) do
    sel_ids = MapSet.new(Enum.map(selected_rooms, & &1.id))

    cash_in_sel =
      Enum.reduce(selected_rooms, 0, fn r, acc -> acc + (r.cash_paid_cents || 0) end)

    usages = Repo.all(from u in CreditUsage, where: u.group_db_id == ^group.id)

    usage_lots =
      if usages == [] do
        []
      else
        lot_ids = usages |> Enum.map(& &1.credit_lot_id) |> Enum.uniq()
        Repo.all(from l in CreditLot, where: l.id in ^lot_ids)
      end

    lot_by_id = Map.new(usage_lots, fn l -> {l.id, l} end)

    # Credit fundings for selected rooms only; need per-funding rows to know
    # which lot amounts return.
    fundings =
      if selected_rooms == [] do
        []
      else
        room_ids = Enum.map(selected_rooms, & &1.id)

        Repo.all(
          from f in RoomFunding,
            where:
              f.group_db_id == ^group.id and f.room_db_id in ^room_ids and
                f.kind in ["credit", "legacy_credit"]
        )
      end

    {refunded, retained, credit_issued, converted_cash} =
      cond do
        is_refundable and refund_method == "cash" ->
          {cash_in_sel, 0, 0, 0}

        is_refundable and refund_method == "hotel_credit" ->
          bonus = credit_bonus(cash_in_sel)
          issued = if cash_in_sel > 0, do: cash_in_sel + bonus, else: 0
          {0, 0, issued, cash_in_sel}

        true ->
          {0, cash_in_sel, 0, 0}
      end

    %{
      selected: selected_rooms,
      sel_ids: sel_ids,
      refunded: refunded,
      retained: retained,
      credit_issued: credit_issued,
      converted_cash: converted_cash,
      usages: usages,
      lot_by_id: lot_by_id,
      credit_fundings: fundings,
      refund_method: refund_method,
      is_refundable: is_refundable,
      occurred_on: occurred_on,
      cancel_op_id: cancel_op_id,
      group: group
    }
  end

  # Applies a settlement computed by settle_rooms: updates rooms, group
  # aggregates, credit lots/usages, and creates new lot for conversions.
  # `close_group?` marks group cancelled when no active rooms remain.
  # Returns {refunded, retained, credit_issued}.
  defp apply_settlement(group, settle, new_revision, _close_group?) do
    %{selected: selected, occurred_on: occurred_on, cancel_op_id: cancel_op_id} = settle

    # 1. Handle credit usages: refundable -> restore to lots (with shortfall
    # absorption before expiry, plus expiry rule); non-refundable -> consumed.
    # Restoration returns credit to its ORIGINAL lot and expiry and never
    # receives a second bonus. If that expiry is already past on the
    # cancellation date, the restored amount expires immediately: it reduces
    # the credit liability instead of becoming available again (i.e. it is
    # NOT added back to remaining).
    if settle.is_refundable do
      sel_funding_by_lot =
        Enum.group_by(settle.credit_fundings, & &1.credit_lot_id)

      Enum.each(sel_funding_by_lot, fn {lot_id, fundings} ->
        sel_amount = Enum.reduce(fundings, 0, fn f, acc -> acc + f.amount_cents end)

        lot = Map.fetch!(settle.lot_by_id, lot_id)
        stored = Repo.get!(CreditLot, lot.id)
        expired? = Date.compare(occurred_on, lot.expires_on) != :lt

        # A lot's current shortfall is the lesser of its unrecovered clawback
        # and credit from that lot still applied to active groups; restoring
        # credit that is still applied therefore first extinguishes
        # unrecovered clawback. This absorption happens before the expiry
        # check; only an excess then becomes available or expires.
        unrec = stored.unrecovered_clawback_cents || 0

        {absorbed, leftover} =
          if unrec > 0 do
            a = min(unrec, sel_amount)
            {a, sel_amount - a}
          else
            {0, sel_amount}
          end

        stored =
          if absorbed > 0 do
            stored
            |> CreditLot.changeset(%{unrecovered_clawback_cents: unrec - absorbed})
            |> Repo.update!()
          else
            stored
          end

        if leftover > 0 and not expired? do
          stored
          |> CreditLot.changeset(%{remaining_cents: stored.remaining_cents + leftover})
          |> Repo.update!()
        end

        # when expired?, leftover simply vanishes (liability decreases).
      end)

      # CreditUsage rows are per (lot, group); reduce them by the restored
      # total per lot (refunding removes the "applied" state).
      Enum.each(sel_funding_by_lot, fn {lot_id, fundings} ->
        sel_amount = Enum.reduce(fundings, 0, fn f, acc -> acc + f.amount_cents end)
        reduce_usages_for_lot(group.id, lot_id, sel_amount)
      end)
    else
      # non-refundable: applied credit in selected rooms is consumed; remove
      # funding rows and shrink usages. Consumed applied credit is no longer
      # applied, so any shortfall on those lots shrinks automatically
      # (shortfall only counts credit still applied to active groups).
      sel_by_lot = Enum.group_by(settle.credit_fundings, & &1.credit_lot_id)

      Enum.each(sel_by_lot, fn {lot_id, fundings} ->
        sel_amount = Enum.reduce(fundings, 0, fn f, acc -> acc + f.amount_cents end)
        reduce_usages_for_lot(group.id, lot_id, sel_amount)
      end)
    end

    # 2. Delete funding rows for selected rooms (both cash and credit).
    sel_ids = Enum.map(selected, & &1.id)

    if sel_ids != [] do
      Repo.delete_all(
        from f in RoomFunding, where: f.group_db_id == ^group.id and f.room_db_id in ^sel_ids
      )
    end

    # 3. Create new credit lot for converted cash (bonus computed once on
    # combined cash).
    if settle.converted_cash > 0 do
      bonus = credit_bonus(settle.converted_cash)
      issued = settle.converted_cash + bonus
      expires_on = Date.add(occurred_on, @credit_valid_days + 1)

      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: cancel_op_id,
        issued_cents: issued,
        remaining_cents: issued,
        converted_cash_cents: settle.converted_cash,
        expires_on: expires_on
      })
      |> Repo.insert!()
    end

    # 4. Update rooms: cancelled status, zero their paid counters. Group
    # lodging/due/paid describe active rooms only; for a full cancel the
    # group becomes cancelled and outstanding is 0 (deposit_due stays as the
    # historical requirement, matching earlier releases).
    due_freed = Enum.reduce(selected, 0, fn r, acc -> acc + (r.deposit_due_cents || 0) end)
    cash_freed = Enum.reduce(selected, 0, fn r, acc -> acc + (r.cash_paid_cents || 0) end)
    credit_freed = Enum.reduce(selected, 0, fn r, acc -> acc + (r.credit_paid_cents || 0) end)

    Enum.each(selected, fn r ->
      r
      |> Room.changeset(%{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
      |> Repo.update!()
    end)

    remaining_active =
      Repo.aggregate(
        from(r in Room, where: r.group_db_id == ^group.id and r.status != "cancelled"),
        :count,
        :id
      ) || 0

    # Group aggregates: existing tests expect deposit_due to stay constant for
    # full cancel; for partial cancel shrink due/paid to active rooms.
    full_cancel? = remaining_active == 0

    new_due =
      if full_cancel?, do: group.deposit_due_cents, else: group.deposit_due_cents - due_freed

    new_cash = (effective_cash_paid(group) - cash_freed) |> max(0)
    new_credit = (effective_credit_paid(group) - credit_freed) |> max(0)
    new_paid = new_cash + new_credit

    # outstanding for active rooms
    new_outstanding =
      if full_cancel?, do: 0, else: max(new_due - new_paid, 0)

    # lodging totals: active rooms only
    active_rooms_now =
      Repo.all(from r in Room, where: r.group_db_id == ^group.id and r.status != "cancelled")

    new_lodging = Enum.reduce(active_rooms_now, 0, fn r, acc -> acc + (r.lodging_cents || 0) end)

    new_status = if full_cancel?, do: "cancelled", else: "active"

    # accumulate refunded/retained across successive partial cancels
    total_refunded = (group.refunded_cents || 0) + settle.refunded
    total_retained = (group.retained_cents || 0) + settle.retained

    group
    |> Group.changeset(%{
      status: new_status,
      revision: new_revision,
      lodging_total_cents: if(full_cancel?, do: group.lodging_total_cents, else: new_lodging),
      deposit_due_cents: new_due,
      deposit_paid_cents: new_paid,
      cash_paid_cents: new_cash,
      credit_paid_cents: new_credit,
      refunded_cents: total_refunded,
      retained_cents: total_retained
    })
    |> Repo.update!()

    _ = new_outstanding
    {settle.refunded, settle.retained, settle.credit_issued}
  end

  defp reduce_usages_for_lot(group_db_id, lot_id, amount) do
    usages =
      Repo.all(
        from u in CreditUsage,
          where: u.group_db_id == ^group_db_id and u.credit_lot_id == ^lot_id,
          order_by: u.id
      )

    Enum.reduce_while(usages, amount, fn u, left ->
      if left <= 0 do
        {:halt, left}
      else
        if u.amount_cents <= left do
          Repo.delete!(u)
          {:cont, left - u.amount_cents}
        else
          u |> CreditUsage.changeset(%{amount_cents: u.amount_cents - left}) |> Repo.update!()
          {:halt, 0}
        end
      end
    end)
  end

  # ---- cancel_rooms ----
  defp apply_cancel_rooms(op, operation_id) do
    group_id = Map.get(op, "group_id") || Map.get(op, :group_id)
    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)

    if not is_binary(group_id) or group_id == "" do
      %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
    else
      case parse_date(occurred_raw) do
        :error ->
          %{
            "operation_id" => operation_id,
            "status" => "rejected",
            "code" => "invalid_operation",
            "group_id" => group_id
          }

        {:ok, occurred_on} ->
          case fetch_group(group_id) do
            :not_found ->
              %{
                "operation_id" => operation_id,
                "status" => "rejected",
                "code" => "group_not_found",
                "group_id" => group_id
              }

            {:ok, group} ->
              case check_expected_revision(op, group) do
                {:stale, exp, actual} ->
                  stale_result(operation_id, group_id, exp, actual)

                :invalid_expected ->
                  %{
                    "operation_id" => operation_id,
                    "status" => "rejected",
                    "code" => "invalid_operation",
                    "group_id" => group_id
                  }

                :ok ->
                  if group.status != "active" do
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "group_not_active",
                      "group_id" => group_id
                    }
                  else
                    case refund_method_of(op) do
                      :invalid ->
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "invalid_operation",
                          "group_id" => group_id
                        }

                      {:ok, refund_method} ->
                        {group2, _} = ensure_room_accounting(group)
                        rooms_all = group_rooms(group2.id)

                        room_ids_raw = Map.get(op, "room_ids") || Map.get(op, :room_ids)

                        with {:ids, ids} when is_list(ids) <- {:ids, room_ids_raw},
                             true <- ids != [] and Enum.all?(ids, &is_binary/1),
                             true <- length(Enum.uniq(ids)) == length(ids) do
                          by_room_id = Map.new(rooms_all, fn r -> {r.room_id, r} end)

                          valid? =
                            Enum.all?(ids, fn rid ->
                              case Map.get(by_room_id, rid) do
                                %{} = r -> r.status != "cancelled"
                                _ -> false
                              end
                            end)

                          if not valid? do
                            %{
                              "operation_id" => operation_id,
                              "status" => "rejected",
                              "code" => "invalid_rooms",
                              "group_id" => group_id
                            }
                          else
                            is_refundable = refundable?(group2, occurred_on)

                            if refund_method == "hotel_credit" and not is_refundable do
                              %{
                                "operation_id" => operation_id,
                                "status" => "rejected",
                                "code" => "refund_method_not_available",
                                "group_id" => group_id
                              }
                            else
                              # order cancelled ids in group's original room order
                              selected =
                                rooms_all
                                |> Enum.filter(fn r -> r.room_id in ids end)

                              ordered_ids = Enum.map(selected, & &1.room_id)

                              settle =
                                settle_rooms(
                                  group2,
                                  selected,
                                  occurred_on,
                                  operation_id,
                                  refund_method,
                                  is_refundable
                                )

                              new_revision = group2.revision + 1

                              Repo.transaction(fn ->
                                apply_settlement(group2, settle, new_revision, true)
                              end)

                              %{
                                "operation_id" => operation_id,
                                "status" => "applied",
                                "group_id" => group_id,
                                "cancelled_room_ids" => ordered_ids,
                                "refunded_cents" => settle.refunded,
                                "retained_cents" => settle.retained,
                                "credit_issued_cents" => settle.credit_issued,
                                "revision" => new_revision
                              }
                            end
                          end
                        else
                          _ ->
                            %{
                              "operation_id" => operation_id,
                              "status" => "rejected",
                              "code" => "invalid_rooms",
                              "group_id" => group_id
                            }
                        end
                    end
                  end
              end
          end
      end
    end
  end

  # ---- payment disposition helpers ----
  # Cash funded by a specific payment op still held on active rooms.
  defp held_cash_for_payment(group_db_id, payment_op_id) do
    Repo.aggregate(
      from(f in RoomFunding,
        join: r in Room,
        on: r.id == f.room_db_id,
        where:
          f.group_db_id == ^group_db_id and f.source_operation_id == ^payment_op_id and
            f.kind in ["cash", "legacy_cash"] and r.status != "cancelled"
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp fetch_payment_target(payment_op_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_op_id) do
      nil ->
        {:error, :not_found}

      %OperationRecord{operation_type: type, result_json: json, payload_json: payload} ->
        with "record_cash_payment" <- type,
             {:ok, result} <- Jason.decode(json),
             %{"status" => "applied", "group_id" => gid, "amount_cents" => amt} <- result,
             {:ok, payload_map} <- Jason.decode(payload),
             %{"group_id" => pgid} when pgid == gid <- payload_map,
             true <- is_integer(amt) and amt > 0 do
          {:ok, %{group_id: gid, recorded: amt, result: result}}
        else
          _ -> {:error, :not_reducible}
        end
    end
  end

  # Remove `amount` of held cash for payment_op_id in reverse fill order (highest
  # seq first). Updates room + group aggregates. Assumes inside transaction.
  defp remove_held_cash(group, payment_op_id, amount) do
    fundings =
      Repo.all(
        from f in RoomFunding,
          join: r in Room,
          on: r.id == f.room_db_id,
          where:
            f.group_db_id == ^group.id and f.source_operation_id == ^payment_op_id and
              f.kind in ["cash", "legacy_cash"] and r.status != "cancelled",
          order_by: [desc: f.seq],
          select: f
      )

    remaining =
      Enum.reduce_while(fundings, amount, fn f, left ->
        if left <= 0 do
          {:halt, left}
        else
          room = Repo.get!(Room, f.room_db_id)

          if f.amount_cents <= left do
            Repo.delete!(f)

            room
            |> Room.changeset(%{cash_paid_cents: (room.cash_paid_cents || 0) - f.amount_cents})
            |> Repo.update!()

            {:cont, left - f.amount_cents}
          else
            f |> RoomFunding.changeset(%{amount_cents: f.amount_cents - left}) |> Repo.update!()

            room
            |> Room.changeset(%{cash_paid_cents: (room.cash_paid_cents || 0) - left})
            |> Repo.update!()

            {:halt, 0}
          end
        end
      end)

    remaining
  end

  defp payment_reduced_total(payment_op_id) do
    Repo.all(from r in OperationRecord, where: r.operation_type == "reduce_cash_payment")
    |> Enum.reduce(0, fn rec, acc ->
      case Jason.decode(rec.payload_json) do
        {:ok, %{"payment_operation_id" => pid}} when pid == payment_op_id ->
          case Jason.decode(rec.result_json) do
            {:ok, %{"status" => "applied", "amount_cents" => a}} when is_integer(a) -> acc + a
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp payment_charged_back?(payment_op_id) do
    Repo.all(from r in OperationRecord, where: r.operation_type == "charge_back_payment")
    |> Enum.any?(fn rec ->
      case Jason.decode(rec.payload_json) do
        {:ok, %{"payment_operation_id" => pid}} when pid == payment_op_id ->
          case Jason.decode(rec.result_json) do
            {:ok, %{"status" => "applied"}} -> true
            _ -> false
          end

        _ ->
          false
      end
    end)
  end

  # ---- reduce_cash_payment ----
  defp apply_reduce_cash(op, operation_id) do
    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)
    payment_op_id = Map.get(op, "payment_operation_id") || Map.get(op, :payment_operation_id)

    cond do
      not is_binary(payment_op_id) or payment_op_id == "" ->
        %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}

      true ->
        case parse_date(occurred_raw) do
          :error ->
            base = %{
              "operation_id" => operation_id,
              "status" => "rejected",
              "code" => "invalid_operation"
            }

            case Repo.get_by(OperationRecord, operation_id: payment_op_id) do
              %OperationRecord{result_json: json} ->
                case Jason.decode(json) do
                  {:ok, %{"group_id" => g}} -> Map.put(base, "group_id", g)
                  _ -> Map.put(base, "payment_operation_id", payment_op_id)
                end

              _ ->
                Map.put(base, "payment_operation_id", payment_op_id)
            end

          {:ok, _occurred} ->
            case Repo.get_by(OperationRecord, operation_id: payment_op_id) do
              nil ->
                %{
                  "operation_id" => operation_id,
                  "status" => "rejected",
                  "code" => "operation_not_found",
                  "payment_operation_id" => payment_op_id
                }

              _rec ->
                case fetch_payment_target(payment_op_id) do
                  {:error, :not_found} ->
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "operation_not_found",
                      "payment_operation_id" => payment_op_id
                    }

                  {:error, :not_reducible} ->
                    gid = extract_group_id(%{"payment_operation_id" => payment_op_id})

                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "payment_not_reducible",
                      "payment_operation_id" => payment_op_id
                    }
                    |> then(fn m -> if gid, do: Map.put(m, "group_id", gid), else: m end)

                  {:ok, %{group_id: gid}} ->
                    case fetch_group(gid) do
                      :not_found ->
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "group_not_found",
                          "group_id" => gid
                        }

                      {:ok, group} ->
                        case check_expected_revision(op, group) do
                          {:stale, exp, actual} ->
                            stale_result(operation_id, gid, exp, actual)

                          :invalid_expected ->
                            %{
                              "operation_id" => operation_id,
                              "status" => "rejected",
                              "code" => "invalid_operation",
                              "group_id" => gid
                            }

                          :ok ->
                            {group2, _} = ensure_room_accounting(group)
                            amount = Map.get(op, "amount_cents") || Map.get(op, :amount_cents)

                            cond do
                              not is_integer(amount) or amount <= 0 ->
                                %{
                                  "operation_id" => operation_id,
                                  "status" => "rejected",
                                  "code" => "invalid_amount",
                                  "payment_operation_id" => payment_op_id,
                                  "group_id" => gid
                                }

                              true ->
                                held = held_cash_for_payment(group2.id, payment_op_id)

                                cond do
                                  held <= 0 ->
                                    %{
                                      "operation_id" => operation_id,
                                      "status" => "rejected",
                                      "code" => "payment_not_reducible",
                                      "payment_operation_id" => payment_op_id,
                                      "group_id" => gid
                                    }

                                  amount > held ->
                                    %{
                                      "operation_id" => operation_id,
                                      "status" => "rejected",
                                      "code" => "reduction_exceeds_held_cash",
                                      "payment_operation_id" => payment_op_id,
                                      "group_id" => gid
                                    }

                                  true ->
                                    new_revision = group2.revision + 1

                                    Repo.transaction(fn ->
                                      remove_held_cash(group2, payment_op_id, amount)

                                      g = Repo.get!(Group, group2.id)

                                      g
                                      |> Group.changeset(%{
                                        deposit_paid_cents: g.deposit_paid_cents - amount,
                                        cash_paid_cents: effective_cash_paid(g) - amount,
                                        cash_reduced_cents:
                                          try do
                                            g.cash_reduced_cents || 0
                                          rescue
                                            _ -> 0
                                          end + amount,
                                        revision: new_revision
                                      })
                                      |> Repo.update!()
                                    end)

                                    g2 = Repo.get_by!(Group, group_id: gid)

                                    %{
                                      "operation_id" => operation_id,
                                      "status" => "applied",
                                      "payment_operation_id" => payment_op_id,
                                      "group_id" => gid,
                                      "amount_cents" => amount,
                                      "outstanding_deposit_cents" =>
                                        max(g2.deposit_due_cents - g2.deposit_paid_cents, 0),
                                      "revision" => new_revision
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
  end

  # ---- charge_back_payment ----
  defp apply_charge_back(op, operation_id) do
    occurred_raw = Map.get(op, "occurred_on") || Map.get(op, :occurred_on)
    payment_op_id = Map.get(op, "payment_operation_id") || Map.get(op, :payment_operation_id)

    cond do
      not is_binary(payment_op_id) or payment_op_id == "" ->
        %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}

      true ->
        case parse_date(occurred_raw) do
          :error ->
            %{
              "operation_id" => operation_id,
              "status" => "rejected",
              "code" => "invalid_operation",
              "payment_operation_id" => payment_op_id
            }

          {:ok, _occurred} ->
            case Repo.get_by(OperationRecord, operation_id: payment_op_id) do
              nil ->
                %{
                  "operation_id" => operation_id,
                  "status" => "rejected",
                  "code" => "operation_not_found",
                  "payment_operation_id" => payment_op_id
                }

              _rec ->
                case fetch_payment_target(payment_op_id) do
                  {:error, _} ->
                    %{
                      "operation_id" => operation_id,
                      "status" => "rejected",
                      "code" => "payment_not_chargeable",
                      "payment_operation_id" => payment_op_id
                    }

                  {:ok, %{group_id: gid, recorded: recorded}} ->
                    reduced = payment_reduced_total(payment_op_id)
                    already_cb? = payment_charged_back?(payment_op_id)

                    cond do
                      already_cb? or reduced >= recorded ->
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "payment_not_chargeable",
                          "payment_operation_id" => payment_op_id,
                          "group_id" => gid
                        }

                      true ->
                        case fetch_group(gid) do
                          :not_found ->
                            %{
                              "operation_id" => operation_id,
                              "status" => "rejected",
                              "code" => "group_not_found",
                              "group_id" => gid
                            }

                          {:ok, group} ->
                            case check_expected_revision(op, group) do
                              {:stale, exp, actual} ->
                                stale_result(operation_id, gid, exp, actual)

                              :invalid_expected ->
                                %{
                                  "operation_id" => operation_id,
                                  "status" => "rejected",
                                  "code" => "invalid_operation",
                                  "group_id" => gid
                                }

                              :ok ->
                                {group2, _} = ensure_room_accounting(group)

                                do_charge_back(
                                  operation_id,
                                  payment_op_id,
                                  group2,
                                  recorded,
                                  reduced
                                )
                            end
                        end
                    end
                end
            end
        end
    end
  end

  defp do_charge_back(operation_id, payment_op_id, group, recorded, reduced_already) do
    new_revision = group.revision + 1

    result =
      Repo.transaction(fn ->
        g = Repo.get!(Group, group.id)

        # 1. Remove held allocations in reverse fill order, reopen outstanding.
        held = held_cash_for_payment(g.id, payment_op_id)
        if held > 0, do: remove_held_cash(g, payment_op_id, held)
        g = Repo.get!(Group, g.id)

        # 2. Attribute settled (refunded/retained/converted) cash of this
        # payment in funding order: unattributed senior block first, then
        # durable-record commit order. Settled cash is consumed from the
        # funding-order queue, so the target payment's settled portions are
        # exactly its share of each cancel settlement.
        {refunded_p, retained_p, converted_p} = attribute_settled_cash(g, payment_op_id)

        # For converted cash, also record which lots the payment contributed
        # to (needed to revoke the right entitlement and to keep the payment
        # statement exact). The per-lot principal shares telescope to the
        # issued lots; store them keyed by lot id in the chargeback result?
        # No — durable results must stay stable, so instead the revocation
        # below recomputes shares deterministically from funding order.
        _ = converted_p

        # Reduce group refunded/retained by those portions (move to charged
        # back; the guest refund / hotel retention itself is NOT reversed).
        g =
          g
          |> Group.changeset(%{
            refunded_cents: max((g.refunded_cents || 0) - refunded_p, 0),
            retained_cents: max((g.retained_cents || 0) - retained_p, 0)
          })
          |> Repo.update!()

        charge_delta = held + refunded_p + retained_p + converted_p

        # 3. Converted principal -> charged back; revoke entitlement from lots
        # that this payment contributed to (remaining first, remainder becomes
        # unrecovered clawback on the lot). The converted_cash_cents principal
        # on the lot stays as history; available balance is what shrinks.
        if converted_p > 0 do
          revoke_credit_entitlement(g, payment_op_id)
        end

        # 4. Update group aggregates for held removal + chargeback totals.
        # held removal already decremented room/group cash via remove_held_cash;
        # need to refresh g and adjust deposit_paid + charged back total.
        g = Repo.get!(Group, g.id)

        charged_total =
          try do
            g.cash_charged_back_cents || 0
          rescue
            _ -> 0
          end + charge_delta

        g
        |> Group.changeset(%{
          deposit_paid_cents: max(g.deposit_paid_cents - held, 0),
          cash_charged_back_cents: charged_total,
          revision: new_revision
        })
        |> Repo.update!()

        g2 = Repo.get_by!(Group, group_id: g.group_id)

        %{
          "operation_id" => operation_id,
          "status" => "applied",
          "payment_operation_id" => payment_op_id,
          "group_id" => g.group_id,
          "charged_back_cents" => recorded - reduced_already,
          "outstanding_deposit_cents" =>
            if(g2.status == "cancelled",
              do: 0,
              else: max(g2.deposit_due_cents - g2.deposit_paid_cents, 0)
            ),
          "revision" => new_revision
        }
      end)

    case result do
      {:ok, map} -> map
      {:error, reason} -> raise "chargeback failed: #{inspect(reason)}"
    end
  end

  # Attribute settled (refunded/retained/converted) cash of a group to a
  # specific cash payment, in funding order (senior block first, then durable
  # commit order). We replay: collect cash funding events in order and settled
  # cash amounts in cancel-commit order.
  defp attribute_settled_cash(group, payment_op_id) do
    # Total cash funded per payment op (including settled portions), in order.
    cash_by_payment = cash_funded_totals(group)

    # Total settled cash per cancel (refunded+retained+converted) in commit order
    cancels = cancel_settlements_for_group(group)

    # Walk cancels in order, consuming funding-order cash; track how much of
    # target payment was refunded / retained / converted.
    {r, t, c} = apportion_settlements(cash_by_payment, cancels, payment_op_id)
    {r, t, c}
  end

  defp cash_funded_totals(group) do
    # All cash ever funded to this group in funding order: the unattributed
    # senior block (legacy cash, if any) first, then durable cash payments in
    # durable-record commit order. Legacy size = current legacy held + settled
    # legacy cash; settled legacy cash is exactly the settled cash not covered
    # by durable payments (reductions/chargebacks only ever touch durable
    # payments, so settled durable cash is exactly durable totals minus held
    # durable cash).
    pay_ops =
      Repo.all(from r in OperationRecord, where: r.operation_type == "record_cash_payment")
      |> Enum.filter(fn rec ->
        case Jason.decode(rec.payload_json) do
          {:ok, %{"group_id" => gid}} -> gid == group.group_id
          _ -> false
        end
      end)
      |> Enum.filter(fn rec ->
        case Jason.decode(rec.result_json) do
          {:ok, %{"status" => "applied"}} -> true
          _ -> false
        end
      end)

    totals =
      Enum.map(pay_ops, fn rec ->
        amt =
          case Jason.decode(rec.result_json) do
            {:ok, %{"amount_cents" => a}} -> a
            _ -> 0
          end

        {rec.operation_id, amt, rec.id}
      end)

    durable_total = Enum.reduce(totals, 0, fn {_, a, _}, acc -> acc + a end)

    held_legacy =
      Repo.aggregate(
        from(f in RoomFunding,
          where: f.group_db_id == ^group.id and f.kind == "legacy_cash"
        ),
        :sum,
        :amount_cents
      ) || 0

    settled_total =
      cancel_settlements_for_group(group)
      |> Enum.reduce(0, fn {rf, rt, cv}, acc -> acc + rf + rt + cv end)

    held_durable =
      Repo.aggregate(
        from(f in RoomFunding,
          where: f.group_db_id == ^group.id and f.kind == "cash"
        ),
        :sum,
        :amount_cents
      ) || 0

    settled_durable = max(durable_total - held_durable, 0)
    settled_legacy = max(settled_total - settled_durable, 0)
    legacy_initial = held_legacy + settled_legacy

    entries =
      if legacy_initial > 0 do
        [{nil, legacy_initial, 0} | Enum.map(totals, fn {op, a, id} -> {op, a, id} end)]
      else
        Enum.map(totals, fn {op, a, id} -> {op, a, id} end)
      end

    # sort durable by commit order (id), legacy first
    Enum.sort_by(entries, fn
      {nil, _, _} -> 0
      {_, _, id} -> id
    end)
  end

  defp cancel_settlements_for_group(group) do
    Repo.all(
      from r in OperationRecord,
        where: r.operation_type in ["cancel_group", "cancel_rooms"],
        order_by: r.id
    )
    |> Enum.filter(fn rec ->
      case Jason.decode(rec.payload_json) do
        {:ok, %{"group_id" => gid}} -> gid == group.group_id
        _ -> false
      end
    end)
    |> Enum.flat_map(fn rec ->
      case Jason.decode(rec.result_json) do
        {:ok, %{"status" => "applied"} = res} ->
          with {:ok, payload} <- Jason.decode(rec.payload_json) do
            refunded = Map.get(res, "refunded_cents", 0) || 0
            retained = Map.get(res, "retained_cents", 0) || 0
            issued = Map.get(res, "credit_issued_cents", 0) || 0
            method = Map.get(payload, "refund_method", "cash")

            converted =
              if method == "hotel_credit" and issued > 0 do
                # converted principal = issued - bonus; recover bonus by
                # inverting rounding? We stored converted_cash in the created
                # lot (source_operation_id = cancel op id).
                case Repo.get_by(CreditLot, source_operation_id: rec.operation_id) do
                  %CreditLot{converted_cash_cents: cc} -> cc
                  _ -> 0
                end
              else
                0
              end

            [{refunded, retained, converted}]
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp apportion_settlements(cash_by_payment, cancels, target_op) do
    # cash_by_payment: [{op_id|nil, amount, _}] in funding order.
    queue = Enum.map(cash_by_payment, fn {op, amt, _} -> {op, amt} end)

    # consume each settlement's refunded, retained, converted in order from queue
    {_, ref_map, ret_map, conv_map} =
      Enum.reduce(cancels, {queue, %{}, %{}, %{}}, fn {rf, rt, cv}, {q, refm, retm, convm} ->
        {q1, refm1} = consume_from_queue(q, rf, refm)
        {q2, retm1} = consume_from_queue(q1, rt, retm)
        {q3, convm1} = consume_from_queue(q2, cv, convm)
        {q3, refm1, retm1, convm1}
      end)

    {Map.get(ref_map, target_op, 0), Map.get(ret_map, target_op, 0),
     Map.get(conv_map, target_op, 0)}
  end

  defp consume_from_queue(queue, amount, acc_map) do
    {q2, taken} =
      Enum.map_reduce(queue, amount, fn {op, rem}, left ->
        if left <= 0 or rem <= 0 do
          {{op, rem}, left}
        else
          take = min(rem, left)
          {{op, rem - take}, left - take}
        end
      end)

    consumed = amount - taken

    # attribute consumed amounts back to ops in queue order
    {_, new_map} =
      Enum.reduce(queue, {consumed, acc_map}, fn {op, rem}, {left, m} ->
        if left <= 0 or rem <= 0 do
          {left, m}
        else
          take = min(rem, left)
          {left - take, Map.update(m, op, take, &(&1 + take))}
        end
      end)

    {q2, new_map}
  end

  # Revoke credit entitlement created by converted cash of a payment.
  # Entitlement per lot computed per spec: funding-order assignment with
  # telescoping 10%-bonus values, half-up rounding on running totals.
  # Credit within a lot is fungible: remove the entitlement from the lot's
  # remaining balance first; anything that cannot be removed becomes that
  # lot's unrecovered clawback.
  defp revoke_credit_entitlement(group, payment_op_id) do
    # Find lots this payment contributed to: lots created by cancels of this
    # group, in commit order; payment's share of each lot's converted cash in
    # funding order.
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^group.guest_id,
          order_by: l.id
      )
      |> Enum.filter(fn lot ->
        # lot created by a cancel of this group?
        case Repo.get_by(OperationRecord, operation_id: lot.source_operation_id) do
          %OperationRecord{payload_json: p} ->
            case Jason.decode(p) do
              {:ok, %{"group_id" => gid}} -> gid == group.group_id
              _ -> false
            end

          _ ->
            false
        end
      end)

    Enum.each(lots, fn lot ->
      entitlement = lot_entitlement_for_share(lot, group, payment_op_id)

      if entitlement > 0 do
        stored = Repo.get!(CreditLot, lot.id)
        remaining = stored.remaining_cents || 0
        remove = min(entitlement, remaining)
        unrec_add = entitlement - remove

        stored
        |> CreditLot.changeset(%{
          remaining_cents: remaining - remove,
          unrecovered_clawback_cents: (stored.unrecovered_clawback_cents || 0) + unrec_add
        })
        |> Repo.update!()
      end
    end)
  end

  defp lot_contributors(group, lot) do
    # Funding-order cash present at the time of the lot's creating cancel:
    # unattributed senior block first, then durable cash payments committed
    # before the cancel (recorded minus reductions committed before it).
    cancel_rec = Repo.get_by(OperationRecord, operation_id: lot.source_operation_id)
    cancel_id = cancel_rec && cancel_rec.id

    pay_ops =
      Repo.all(
        from r in OperationRecord,
          where: r.operation_type == "record_cash_payment" and r.id < ^cancel_id,
          order_by: r.id
      )
      |> Enum.filter(fn rec ->
        case Jason.decode(rec.payload_json) do
          {:ok, %{"group_id" => gid}} -> gid == group.group_id
          _ -> false
        end
      end)
      |> Enum.filter(fn rec ->
        case Jason.decode(rec.result_json) do
          {:ok, %{"status" => "applied"}} -> true
          _ -> false
        end
      end)

    contribs =
      Enum.map(pay_ops, fn rec ->
        amt =
          case Jason.decode(rec.result_json) do
            {:ok, %{"amount_cents" => a}} -> a
            _ -> 0
          end

        red_before =
          Repo.all(
            from r in OperationRecord,
              where: r.operation_type == "reduce_cash_payment" and r.id < ^cancel_id
          )
          |> Enum.reduce(0, fn rrec, acc ->
            with {:ok, %{"payment_operation_id" => pid}} <- Jason.decode(rrec.payload_json),
                 true <- pid == rec.operation_id,
                 {:ok, %{"status" => "applied", "amount_cents" => a}} <-
                   Jason.decode(rrec.result_json) do
              acc + a
            else
              _ -> acc
            end
          end)

        {rec.operation_id, max(amt - red_before, 0)}
      end)
      |> Enum.filter(fn {_, a} -> a > 0 end)

    # Senior block at cancel time: legacy cash is never reduced (it has no
    # durable identity), so its size then == its size now + settled legacy
    # cash from cancels committed before this one.
    legacy_now =
      Repo.aggregate(
        from(f in RoomFunding,
          where: f.group_db_id == ^group.id and f.kind == "legacy_cash"
        ),
        :sum,
        :amount_cents
      ) || 0

    earlier_settled =
      cancel_settlements_for_group(group)
      |> Enum.take_while(fn _ -> true end)

    # cancels before this one:
    cancel_ids =
      Repo.all(
        from r in OperationRecord,
          where: r.operation_type in ["cancel_group", "cancel_rooms"] and r.id < ^cancel_id,
          order_by: r.id,
          select: r.operation_id
      )
      |> MapSet.new()

    earlier_settled_total =
      Repo.all(
        from r in OperationRecord,
          where: r.operation_type in ["cancel_group", "cancel_rooms"] and r.id < ^cancel_id,
          order_by: r.id
      )
      |> Enum.filter(fn rec ->
        case Jason.decode(rec.payload_json) do
          {:ok, %{"group_id" => gid}} -> gid == group.group_id
          _ -> false
        end
      end)
      |> Enum.reduce(0, fn rec, acc ->
        case Jason.decode(rec.result_json) do
          {:ok, %{"status" => "applied"} = res} ->
            with {:ok, payload} <- Jason.decode(rec.payload_json) do
              rf = Map.get(res, "refunded_cents", 0) || 0
              rt = Map.get(res, "retained_cents", 0) || 0
              issued = Map.get(res, "credit_issued_cents", 0) || 0
              method = Map.get(payload, "refund_method", "cash")

              cv =
                if method == "hotel_credit" and issued > 0 do
                  case Repo.get_by(CreditLot, source_operation_id: rec.operation_id) do
                    %CreditLot{converted_cash_cents: cc} -> cc
                    _ -> 0
                  end
                else
                  0
                end

              acc + rf + rt + cv
            else
              _ -> acc
            end

          _ ->
            acc
        end
      end)

    _ = earlier_settled
    _ = cancel_ids

    # Durable cash settled before this cancel == durable totals (before
    # cancel) minus durable cash still funded now that predates... we
    # approximate: durable payments before cancel minus durable held now
    # cannot exceed; use max(0, ...). Legacy settled = earlier settled minus
    # durable settled.
    durable_before =
      Enum.reduce(contribs, 0, fn {_, a}, acc -> acc + a end)

    held_durable_now =
      Repo.aggregate(
        from(f in RoomFunding,
          where: f.group_db_id == ^group.id and f.kind == "cash"
        ),
        :sum,
        :amount_cents
      ) || 0

    durable_settled_before = max(durable_before - held_durable_now, 0)
    legacy_settled_before = max(earlier_settled_total - durable_settled_before, 0)
    legacy_then = legacy_now + legacy_settled_before

    base = if legacy_then > 0, do: [{nil, legacy_then}], else: []

    # Determine how much of lot.converted_cash came from which contributor in
    # funding order: consume (legacy ++ contribs) in order up to converted total.
    full = base ++ contribs

    {ordered, _} =
      Enum.reduce(full, {[], lot.converted_cash_cents}, fn {op, amt}, {out, left} ->
        if left <= 0 do
          {out, left}
        else
          take = min(amt, left)
          {out ++ [{op, take}], left - take}
        end
      end)

    ordered
  end

  defp lot_entitlement_for_share(lot, group, payment_op_id) do
    telescoping_share(lot_contributors(group, lot), payment_op_id)
  end

  # Each payment's entitlement is the standard 10%-bonus value of settled cash
  # through that payment minus the bonus value through the preceding payment
  # (half-up rounding on both running totals). Entitlements telescope exactly
  # to the issued lot.
  defp telescoping_share(contribs, payment_op_id) do
    idx = Enum.find_index(contribs, fn {op, _} -> op == payment_op_id end)

    if is_nil(idx) do
      0
    else
      before = contribs |> Enum.take(idx) |> Enum.reduce(0, fn {_, a}, acc -> acc + a end)
      {_, amt} = Enum.at(contribs, idx)
      aft = before + amt
      aft + div(aft * 10 + 50, 100) - (before + div(before * 10 + 50, 100))
    end
  end

  # ---- reconcile single payment ----
  # Read-only: never writes. Every amount is the current disposition of cash
  # from that payment; the six disposition fields sum exactly to recorded.
  def payment_reconciliation(payment_op_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_op_id) do
      nil ->
        :not_found

      %OperationRecord{operation_type: type, result_json: json} ->
        case {type, Jason.decode(json)} do
          {"record_cash_payment",
           {:ok, %{"status" => "applied", "group_id" => gid, "amount_cents" => recorded}}} ->
            case Repo.get_by(Group, group_id: gid) do
              nil ->
                :not_found

              group ->
                held = held_cash_for_payment(group.id, payment_op_id)

                {refunded_p, retained_p, converted_p} =
                  attribute_settled_cash(group, payment_op_id)

                reduced = payment_reduced_total(payment_op_id)

                {refunded_p, retained_p, converted_p} =
                  if payment_charged_back?(payment_op_id) do
                    {0, 0, 0}
                  else
                    {refunded_p, retained_p, converted_p}
                  end

                charged = recorded - reduced - held - refunded_p - retained_p - converted_p

                {:ok,
                 %{
                   "payment_operation_id" => payment_op_id,
                   "original_group_id" => gid,
                   "recorded_cents" => recorded,
                   "held_cents" => held,
                   "refunded_cents" => refunded_p,
                   "retained_cents" => retained_p,
                   "converted_to_credit_cents" => converted_p,
                   "reduced_cents" => reduced,
                   "charged_back_cents" => charged
                 }}
            end

          _ ->
            :not_reconcilable
        end
    end
  end

  # ---- reads ----
  # Read-only enrichment of rooms for the group view. Never writes.
  # Computes per-room lodging/deposit from the stay length + rate plan, and
  # overlays current held cash/credit from room_fundings joined to active
  # rooms. Totals for active rooms only.
  defp enrich_rooms_view(group, rooms) do
    nights =
      try do
        Date.diff(group.departure_on, group.arrival_on)
      rescue
        _ -> 0
      end

    fundings =
      try do
        Repo.all(from f in RoomFunding, where: f.group_db_id == ^group.id)
      rescue
        _ -> []
      end

    by_room =
      Enum.group_by(fundings, & &1.room_db_id)

    Enum.map(rooms, fn r ->
      lodging =
        if (r.lodging_cents || 0) > 0,
          do: r.lodging_cents,
          else: nights * (r.nightly_rate_cents || 0)

      deposit =
        if (r.deposit_due_cents || 0) > 0,
          do: r.deposit_due_cents,
          else:
            if(group.rate_plan == "flexible",
              do: div(lodging * 20 + 50, 100),
              else: lodging
            )

      fs = Map.get(by_room, r.id, [])

      cash =
        fs
        |> Enum.filter(&(&1.kind in ["cash", "legacy_cash"]))
        |> Enum.reduce(0, fn f, acc -> acc + f.amount_cents end)

      credit =
        fs
        |> Enum.filter(&(&1.kind in ["credit", "legacy_credit"]))
        |> Enum.reduce(0, fn f, acc -> acc + f.amount_cents end)

      # Fall back to stored per-room counters when no funding rows exist
      # (e.g. groups funded before seeding ran inside a rolled-back read).
      {cash, credit} =
        if fs == [] do
          {r.cash_paid_cents || 0, r.credit_paid_cents || 0}
        else
          {cash, credit}
        end

      status = r.status || "active"

      %{
        r
        | lodging_cents: lodging,
          deposit_due_cents: deposit,
          cash_paid_cents: cash,
          credit_paid_cents: credit,
          status: status
      }
    end)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :not_found

      group ->
        # NOTE: get_group must never write (reads are also used by the
        # payment-reconciliation endpoint, and "reading a statement never
        # changes state"). Derive room accounting in memory only.
        rooms =
          Repo.all(from r in Room, where: r.group_db_id == ^group.id, order_by: r.position)

        rooms = enrich_rooms_view(group, rooms)

        active_rooms = Enum.filter(rooms, &(&1.status != "cancelled"))

        lodging_active =
          Enum.reduce(active_rooms, 0, fn r, acc -> acc + (r.lodging_cents || 0) end)

        due_active =
          Enum.reduce(active_rooms, 0, fn r, acc -> acc + (r.deposit_due_cents || 0) end)

        lodging_total =
          if lodging_active == 0, do: group.lodging_total_cents, else: lodging_active

        deposit_due = if active_rooms == [], do: group.deposit_due_cents, else: due_active

        # Group paid/outstanding describe active rooms only.
        paid_active =
          Enum.reduce(active_rooms, 0, fn r, acc ->
            acc + (r.cash_paid_cents || 0) + (r.credit_paid_cents || 0)
          end)

        cash_active =
          Enum.reduce(active_rooms, 0, fn r, acc -> acc + (r.cash_paid_cents || 0) end)

        credit_active =
          Enum.reduce(active_rooms, 0, fn r, acc -> acc + (r.credit_paid_cents || 0) end)

        outstanding =
          if group.status == "cancelled" do
            0
          else
            max(deposit_due - paid_active, 0)
          end

        pv = policy_version_of(group)
        ru = refundable_until_of(group)

        {cash_paid, credit_paid, deposit_paid} =
          if group.status == "cancelled" and active_rooms != [] do
            # Partially cancelled group that later fully cancelled via
            # cancel_group keeps group-level aggregates as history.
            {effective_cash_paid(group), effective_credit_paid(group), group.deposit_paid_cents}
          else
            {cash_active, credit_active, cash_active + credit_active}
          end

        {cash_paid, credit_paid, deposit_paid} =
          if group.status == "cancelled" and active_rooms == [] and
               not room_accounting_used?(group) do
            # Legacy cancelled group (no room accounting): keep stored
            # aggregates verbatim.
            {effective_cash_paid(group), effective_credit_paid(group), group.deposit_paid_cents}
          else
            {cash_paid, credit_paid, deposit_paid}
          end

        with_policy? = has_column?(:groups, "policy_version")

        base = %{
          "group_id" => group.group_id,
          "guest_id" => group.guest_id,
          "property_id" => group.property_id,
          "revision" => group.revision,
          "booked_on" => Date.to_iso8601(group.booked_on),
          "arrival_on" => Date.to_iso8601(group.arrival_on),
          "departure_on" => Date.to_iso8601(group.departure_on),
          "rate_plan" => group.rate_plan,
          "status" => group.status,
          "rooms" =>
            Enum.map(rooms, fn r ->
              %{
                "room_id" => r.room_id,
                "nightly_rate_cents" => r.nightly_rate_cents,
                "status" => r.status || "active",
                "deposit_due_cents" => r.deposit_due_cents || 0,
                "cash_paid_cents" => r.cash_paid_cents || 0,
                "credit_paid_cents" => r.credit_paid_cents || 0
              }
            end),
          "lodging_total_cents" => lodging_total,
          "deposit_due_cents" => deposit_due,
          "deposit_paid_cents" => deposit_paid,
          "outstanding_deposit_cents" => outstanding
        }

        extra =
          if with_policy? do
            %{
              "cash_paid_cents" => cash_paid,
              "credit_paid_cents" => credit_paid,
              "policy_version" => pv,
              "refundable_until" => if(ru, do: Date.to_iso8601(ru), else: nil)
            }
          else
            %{}
          end

        {:ok, Map.merge(base, extra)}
    end
  end

  # Whether a group has any room-accounting rows (fundings or non-default
  # per-room state). Legacy groups predate the feature and keep stored
  # aggregates verbatim once cancelled.
  defp room_accounting_used?(group) do
    try do
      (Repo.aggregate(from(f in RoomFunding, where: f.group_db_id == ^group.id), :count, :id) || 0) >
        0 or
        (Repo.aggregate(
           from(r in Room,
             where:
               r.group_db_id == ^group.id and
                 (r.status == "cancelled" or r.cash_paid_cents > 0 or r.credit_paid_cents > 0)
           ),
           :count,
           :id
         ) || 0) > 0
    rescue
      _ -> false
    end
  end

  def ledger(as_of \\ Date.utc_today()) do
    held = cash_held()
    refunded = refunded_total()
    retained = retained_total()
    {reduced, charged} = reduced_and_charged_totals()
    converted = converted_total()
    liability = credit_liability(as_of)
    shortfall = credit_shortfall(as_of)

    base = %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained
    }

    if has_table?("credit_lots") do
      extra = %{
        "cash_converted_to_credit_cents" => converted,
        "credit_liability_cents" => liability
      }

      extra =
        if has_table?("room_fundings") and has_column?(:groups, "cash_reduced_cents") do
          Map.merge(extra, %{
            "cash_reduced_cents" => reduced,
            "cash_charged_back_cents" => charged,
            "credit_shortfall_cents" => shortfall
          })
        else
          extra
        end

      Map.merge(base, extra)
    else
      base
    end
  end

  # Recorded cash identity (holds while room_fundings exists):
  #   recorded = held + refunded + retained + converted + reduced + charged_back
  # where recorded = sum of applied record_cash_payment amounts and the other
  # five/six terms are the ledger totals below. cash_held derives from
  # per-room funding rows on active rooms so partial cancels, reductions and
  # chargebacks move it exactly.
  defp cash_held do
    if has_table?("room_fundings") do
      Repo.aggregate(
        from(f in RoomFunding,
          join: r in Room,
          on: r.id == f.room_db_id,
          join: g in Group,
          on: g.id == f.group_db_id,
          where:
            g.status == "active" and r.status != "cancelled" and
              f.kind in ["cash", "legacy_cash"]
        ),
        :sum,
        :amount_cents
      ) || 0
    else
      held_legacy()
    end
  end

  defp converted_total do
    if has_table?("credit_lots") do
      Repo.aggregate(from(l in CreditLot), :sum, :converted_cash_cents) || 0
    else
      0
    end
  end

  defp reduced_and_charged_totals do
    if has_table?("room_fundings") and has_column?(:groups, "cash_reduced_cents") do
      reduced = Repo.aggregate(from(g in Group), :sum, :cash_reduced_cents) || 0
      charged = Repo.aggregate(from(g in Group), :sum, :cash_charged_back_cents) || 0
      {reduced, charged}
    else
      {0, 0}
    end
  end

  defp held_legacy do
    if has_column?(:groups, "cash_paid_cents") do
      Repo.one(from(g in Group, where: g.status == "active", select: sum(g.cash_paid_cents))) || 0
    else
      Repo.one(from(g in Group, where: g.status == "active", select: sum(g.deposit_paid_cents))) ||
        0
    end
  end

  defp refunded_total do
    Repo.aggregate(from(g in Group, where: g.status == "cancelled"), :sum, :refunded_cents) || 0
  end

  defp retained_total do
    Repo.aggregate(from(g in Group, where: g.status == "cancelled"), :sum, :retained_cents) || 0
  end

  def credit_shortfall(_as_of) do
    if not has_table?("credit_lots") do
      0
    else
      lots =
        try do
          Repo.all(from(l in CreditLot))
        rescue
          _ -> []
        end

      Enum.reduce(lots, 0, fn lot, acc ->
        unrec =
          try do
            lot.unrecovered_clawback_cents || 0
          rescue
            _ -> 0
          end

        if unrec <= 0 do
          acc
        else
          applied =
            Repo.aggregate(
              from(u in CreditUsage,
                join: g in Group,
                on: g.id == u.group_db_id,
                where: u.credit_lot_id == ^lot.id and g.status == "active"
              ),
              :sum,
              :amount_cents
            ) || 0

          acc + min(unrec, applied)
        end
      end)
    end
  end

  def credit_liability(as_of) do
    # Liability includes both available credit and credit currently applied to
    # active groups (expiry is paused while funding), including credit covered
    # by a current shortfall. Lots count while unexpired. Shortfall-absorbed
    # restorations already reduced remaining, so no extra adjustment needed.
    # Expired lots never count, even if they still carry unrecovered clawback.
    remaining_sum =
      Repo.aggregate(
        from(l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on > ^as_of
        ),
        :sum,
        :remaining_cents
      ) || 0

    active_sum =
      Repo.aggregate(
        from(u in CreditUsage,
          join: g in Group,
          on: g.id == u.group_db_id,
          where: g.status == "active"
        ),
        :sum,
        :amount_cents
      ) || 0

    remaining_sum + active_sum
  end

  def guest_credit(guest_id, as_of) when is_binary(guest_id) do
    lots = available_lots(guest_id, as_of)
    available = Enum.reduce(lots, 0, fn l, acc -> acc + l.remaining_cents end)

    %{
      "guest_id" => guest_id,
      "available_cents" => available,
      "lots" =>
        Enum.map(lots, fn l ->
          %{
            "source_operation_id" => l.source_operation_id,
            "remaining_cents" => l.remaining_cents,
            "expires_on" => Date.to_iso8601(l.expires_on)
          }
        end)
    }
  end
end
