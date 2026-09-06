defmodule GroupStay.Batches do
  alias GroupStay.Repo
  alias GroupStay.Group
  alias GroupStay.Room
  import Ecto.Query

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(op) when not is_map(op) do
    %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
  end

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

                    case insert_group(%{
                           group_id: group_id,
                           guest_id: guest_id,
                           property_id: property_id,
                           booked_on: occurred_on,
                           arrival_on: arrival_on,
                           departure_on: departure_on,
                           rate_plan: rate_plan,
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
          status: "active",
          revision: 1,
          lodging_total_cents: attrs.lodging_total_cents,
          deposit_due_cents: attrs.deposit_due_cents,
          deposit_paid_cents: 0,
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
                        new_paid = group.deposit_paid_cents + amount
                        new_revision = group.revision + 1
                        new_outstanding = group.deposit_due_cents - new_paid

                        {:ok, _} =
                          Repo.transaction(fn ->
                            group
                            |> Group.changeset(%{
                              deposit_paid_cents: new_paid,
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

                          %{
                            "operation_id" => operation_id,
                            "status" => "applied",
                            "group_id" => group_id,
                            "new_arrival_on" => Date.to_iso8601(new_arrival),
                            "new_departure_on" => Date.to_iso8601(new_departure),
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
                    paid = group.deposit_paid_cents

                    {refunded, retained} =
                      if group.rate_plan == "flexible" and
                           Date.diff(group.arrival_on, occurred_on) >= 14 do
                        {paid, 0}
                      else
                        {0, paid}
                      end

                    new_revision = group.revision + 1

                    {:ok, _} =
                      Repo.transaction(fn ->
                        group
                        |> Group.changeset(%{
                          status: "cancelled",
                          revision: new_revision,
                          refunded_cents: refunded,
                          retained_cents: retained
                        })
                        |> Repo.update!()
                      end)

                    %{
                      "operation_id" => operation_id,
                      "status" => "applied",
                      "group_id" => group_id,
                      "refunded_cents" => refunded,
                      "retained_cents" => retained,
                      "revision" => new_revision
                    }
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

        {:ok,
         %{
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
         }}
    end
  end

  def ledger do
    held =
      Repo.aggregate(
        from(g in Group, where: g.status == "active"),
        :sum,
        :deposit_paid_cents
      ) || 0

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

    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained
    }
  end
end
