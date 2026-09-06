defmodule GroupStay.Batches do
  alias GroupStay.Repo
  alias GroupStay.Group
  alias GroupStay.Room
  alias GroupStay.CreditLot
  alias GroupStay.CreditUsage
  alias GroupStay.OperationRecord
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
    # Remaining was decremented at apply time, so the stored remainder is exactly
    # the free (unapplied, unexpired) balance. Lots are available strictly before
    # `expires_on` (available through the day before it).
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

    maybe_put_group_id(base, extract_group_id(op))
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

        _ ->
          %{"operation_id" => operation_id, "status" => "rejected", "code" => "invalid_operation"}
          |> maybe_put_group_id(extract_group_id(op))
      end
    end
  end

  defp extract_group_id(op) when is_map(op) do
    gid = Map.get(op, "group_id") || Map.get(op, :group_id)
    if is_binary(gid), do: gid, else: nil
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
          attrs.rooms
          |> Enum.with_index()
          |> Enum.each(fn {r, idx} ->
            {:ok, _} =
              %Room{}
              |> Room.changeset(%{
                group_db_id: group.id,
                room_id: r.room_id,
                nightly_rate_cents: r.nightly_rate_cents,
                position: idx
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
                      outstanding = group.deposit_due_cents - group.deposit_paid_cents

                      if amount > outstanding do
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "payment_exceeds_outstanding",
                          "group_id" => group_id
                        }
                      else
                        cash_paid = effective_cash_paid(group)
                        new_cash = cash_paid + amount
                        new_paid = group.deposit_paid_cents + amount
                        new_revision = group.revision + 1
                        new_outstanding = group.deposit_due_cents - new_paid

                        {:ok, _} =
                          Repo.transaction(fn ->
                            group
                            |> Group.changeset(%{
                              deposit_paid_cents: new_paid,
                              cash_paid_cents: new_cash,
                              revision: new_revision
                            })
                            |> Repo.update!()
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
                      outstanding = group.deposit_due_cents - group.deposit_paid_cents

                      if amount > outstanding do
                        %{
                          "operation_id" => operation_id,
                          "status" => "rejected",
                          "code" => "payment_exceeds_outstanding",
                          "group_id" => group_id
                        }
                      else
                        lots = available_lots(group.guest_id, occurred_on)
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
                          new_paid = group.deposit_paid_cents + amount
                          credit_paid = effective_credit_paid(group)
                          new_credit = credit_paid + amount
                          new_revision = group.revision + 1
                          new_outstanding = group.deposit_due_cents - new_paid

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
                                  group_db_id: group.id,
                                  amount_cents: take
                                })
                                |> Repo.insert!()
                              end)

                              group
                              |> Group.changeset(%{
                                deposit_paid_cents: new_paid,
                                credit_paid_cents: new_credit,
                                revision: new_revision
                              })
                              |> Repo.update!()
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
                        is_refundable = refundable?(group, occurred_on)
                        cash_paid = effective_cash_paid(group)

                        if refund_method_raw == "hotel_credit" and not is_refundable do
                          %{
                            "operation_id" => operation_id,
                            "status" => "rejected",
                            "code" => "refund_method_not_available",
                            "group_id" => group_id
                          }
                        else
                          usages =
                            Repo.all(from u in CreditUsage, where: u.group_db_id == ^group.id)

                          usage_lots =
                            if usages == [] do
                              []
                            else
                              lot_ids = Enum.map(usages, & &1.credit_lot_id) |> Enum.uniq()
                              Repo.all(from l in CreditLot, where: l.id in ^lot_ids)
                            end

                          lot_by_id = Map.new(usage_lots, fn l -> {l.id, l} end)

                          {refunded, retained, credit_issued, converted_cash} =
                            cond do
                              is_refundable and refund_method_raw == "cash" ->
                                {cash_paid, 0, 0, 0}

                              is_refundable and refund_method_raw == "hotel_credit" ->
                                bonus = credit_bonus(cash_paid)

                                issued =
                                  if cash_paid > 0, do: cash_paid + bonus, else: 0

                                {0, 0, issued, cash_paid}

                              true ->
                                {0, cash_paid, 0, 0}
                            end

                          new_revision = group.revision + 1

                          {:ok, _expired_restore_total} =
                            Repo.transaction(fn ->
                              expired_total =
                                if is_refundable do
                                  Enum.reduce(usages, 0, fn u, acc ->
                                    lot = Map.fetch!(lot_by_id, u.credit_lot_id)
                                    stored = Repo.get!(CreditLot, lot.id)

                                    expired? =
                                      Date.compare(occurred_on, lot.expires_on) != :lt

                                    new_remaining = stored.remaining_cents + u.amount_cents

                                    stored
                                    |> CreditLot.changeset(%{remaining_cents: new_remaining})
                                    |> Repo.update!()

                                    if expired?, do: acc + u.amount_cents, else: acc
                                  end)
                                else
                                  # non-refundable: applied credit is consumed; reduce remaining
                                  # lots were already decremented at apply time, nothing more to do.
                                  0
                                end

                              # For converted cash: create new credit lot
                              if converted_cash > 0 do
                                bonus = credit_bonus(converted_cash)
                                issued = converted_cash + bonus
                                expires_on = Date.add(occurred_on, @credit_valid_days + 1)

                                %CreditLot{}
                                |> CreditLot.changeset(%{
                                  guest_id: group.guest_id,
                                  source_operation_id: operation_id,
                                  issued_cents: issued,
                                  remaining_cents: issued,
                                  converted_cash_cents: converted_cash,
                                  expires_on: expires_on
                                })
                                |> Repo.insert!()
                              end

                              group
                              |> Group.changeset(%{
                                status: "cancelled",
                                revision: new_revision,
                                refunded_cents: refunded,
                                retained_cents: retained
                              })
                              |> Repo.update!()

                              expired_total
                            end)

                          base = %{
                            "operation_id" => operation_id,
                            "status" => "applied",
                            "group_id" => group_id,
                            "refunded_cents" => refunded,
                            "retained_cents" => retained,
                            "revision" => new_revision,
                            "credit_issued_cents" => credit_issued
                          }

                          base
                        end
                    end
                  end
              end
          end
      end
    end
  end

  # ---- reads ----
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :not_found

      group ->
        rooms =
          Repo.all(from r in Room, where: r.group_db_id == ^group.id, order_by: r.position)

        outstanding =
          if group.status == "cancelled" do
            0
          else
            max(group.deposit_due_cents - group.deposit_paid_cents, 0)
          end

        pv = policy_version_of(group)
        ru = refundable_until_of(group)
        cash_paid = effective_cash_paid(group)
        credit_paid = effective_credit_paid(group)
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
              %{"room_id" => r.room_id, "nightly_rate_cents" => r.nightly_rate_cents}
            end),
          "lodging_total_cents" => group.lodging_total_cents,
          "deposit_due_cents" => group.deposit_due_cents,
          "deposit_paid_cents" => group.deposit_paid_cents,
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

  def ledger(as_of \\ Date.utc_today()) do
    held =
      if has_column?(:groups, "cash_paid_cents") do
        Repo.one(from(g in Group, where: g.status == "active", select: sum(g.cash_paid_cents))) ||
          0
      else
        Repo.one(from(g in Group, where: g.status == "active", select: sum(g.deposit_paid_cents))) ||
          0
      end

    # sum refunded/retained across cancelled groups
    refunded =
      Repo.aggregate(
        from(g in Group, where: g.status == "cancelled"),
        :sum,
        :refunded_cents
      ) || 0

    retained =
      Repo.aggregate(
        from(g in Group, where: g.status == "cancelled"),
        :sum,
        :retained_cents
      ) || 0

    base = %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained
    }

    if has_table?("credit_lots") do
      converted =
        Repo.aggregate(from(l in CreditLot), :sum, :converted_cash_cents) || 0

      liability = credit_liability(as_of)

      Map.merge(base, %{
        "cash_converted_to_credit_cents" => converted,
        "credit_liability_cents" => liability
      })
    else
      base
    end
  end

  def credit_liability(as_of) do
    # Liability includes both available credit and credit currently applied to
    # active groups (expiry is paused while funding). Applying/restoring therefore
    # leaves it unchanged unless a restored lot has already expired. Remaining was
    # decremented at apply time, so add active usages back. Lots count while
    # unexpired (strictly before `expires_on`).
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
