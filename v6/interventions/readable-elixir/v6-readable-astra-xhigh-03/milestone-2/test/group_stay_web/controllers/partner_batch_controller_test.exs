defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashEntry, Group}

  describe "batch contract" do
    test "requires an operations array", %{conn: conn} do
      for body <- [
            nil,
            42,
            "invalid",
            true,
            %{},
            %{"operations" => nil},
            %{"operations" => %{}},
            %{"operations" => "bad"},
            []
          ] do
        response = post_json(conn, body)
        assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end

      assert submit(conn, []) == []
    end

    test "query parameters cannot supply a missing operations array", %{conn: conn} do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches?operations[]=query-operation", "{}")

      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "returns one ordered result per input and continues after malformed operations", %{
      conn: conn
    } do
      invalid = [
        nil,
        [],
        17,
        "operation",
        true,
        %{},
        %{"type" => "unknown", "operation_id" => "unknown"}
      ]

      results = submit(conn, invalid ++ [open_group(), payment()])

      assert Enum.map(Enum.take(results, length(invalid)), & &1["code"]) ==
               List.duplicate("invalid_operation", length(invalid))

      assert Enum.at(results, 6)["operation_id"] == "unknown"
      assert Enum.at(results, 7)["status"] == "applied"
      assert Enum.at(results, 8)["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 5_000
    end

    test "missing fields are invalid operations and do not prevent a subsequent valid operation",
         %{conn: conn} do
      operations =
        for field <- Map.keys(open_group()) do
          Map.delete(open_group(), field)
        end

      results = submit(conn, operations ++ [open_group()])
      assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))
      assert List.last(results)["revision"] == 1

      for operation <- [payment(), reschedule(), cancellation()],
          field <- Map.keys(operation) do
        assert [%{"code" => "invalid_operation"}] = submit(conn, [Map.delete(operation, field)])
      end

      assert group(conn)["revision"] == 1
    end

    test "unusable common fields are rejected without coercion", %{conn: conn} do
      for field <- ~w(operation_id group_id guest_id property_id),
          value <- [nil, "", "  ", 123, %{}] do
        assert [%{"code" => "invalid_operation"}] = submit(conn, [open_group(%{field => value})])
      end

      for value <- [nil, "2026-02-30", 12, %{}] do
        assert [%{"code" => "invalid_operation"}] =
                 submit(conn, [open_group(%{"occurred_on" => value})])
      end

      assert Repo.all(Group) == []
      assert Repo.all(CashEntry) == []
    end

    test "a rejection leaves all stored records unchanged", %{conn: conn} do
      submit(conn, [open_group(), payment()])
      snapshot = snapshot()

      operations = [
        open_group(),
        payment(%{"amount_cents" => 99_999}),
        payment(%{"amount_cents" => -1}),
        reschedule(%{"new_arrival_on" => "2026-11-01"}),
        cancellation(%{"expected_revision" => 1}),
        cancellation(%{"group_id" => "missing"}),
        %{"type" => "unknown", "operation_id" => "unknown"}
      ]

      for operation <- operations do
        assert [%{"status" => "rejected"}] = submit(conn, [operation])
        assert snapshot() == snapshot
      end

      assert [%{"status" => "applied", "revision" => 3}] = submit(conn, [payment()])
    end
  end

  describe "opening groups" do
    test "returns a complete group and preserves partner identifiers and room order", %{
      conn: conn
    } do
      operation =
        open_group(%{
          "group_id" => "Group-Ä_001",
          "guest_id" => " Guest-022 ",
          "expected_revision" => -5
        })

      assert submit(conn, [operation]) == [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "Group-Ä_001",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]

      assert group(conn, "Group-Ä_001") == %{
               "group_id" => "Group-Ä_001",
               "guest_id" => " Guest-022 ",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "rooms" => operation["rooms"],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }

      assert ledger(conn) == %{
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "rounds each flexible room deposit independently using integer cents", %{conn: conn} do
      rooms = [
        %{"room_id" => "a", "nightly_rate_cents" => 2},
        %{"room_id" => "b", "nightly_rate_cents" => 2},
        %{"room_id" => "c", "nightly_rate_cents" => 3},
        %{"room_id" => "d", "nightly_rate_cents" => 3}
      ]

      submit(conn, [open_group(%{"rooms" => rooms, "departure_on" => "2026-12-11"})])
      assert group(conn)["lodging_total_cents"] == 10
      assert group(conn)["deposit_due_cents"] == 2

      # Rounding the group total would give 1; each 0.4-cent room rounds to 0.
      assert [%{"deposit_due_cents" => 0}] =
               submit(conn, [
                 open_group(%{
                   "group_id" => "round-down",
                   "rooms" => Enum.take(rooms, 2),
                   "departure_on" => "2026-12-11"
                 })
               ])

      # Each 0.6-cent room rounds up to 1; rounding the total would give 1.
      assert [%{"deposit_due_cents" => 2}] =
               submit(conn, [
                 open_group(%{
                   "group_id" => "round-up",
                   "rooms" => Enum.drop(rooms, 2),
                   "departure_on" => "2026-12-11"
                 })
               ])
    end

    test "advance purchase requires the full lodging amount and handles leap-day stays", %{
      conn: conn
    } do
      assert [%{"deposit_due_cents" => 65_000}] =
               submit(conn, [
                 open_group(%{
                   "rate_plan" => "advance_purchase",
                   "arrival_on" => "2028-02-28",
                   "departure_on" => "2028-03-01"
                 })
               ])

      assert group(conn)["lodging_total_cents"] == 65_000
    end

    test "supports complimentary rooms without inventing cash", %{conn: conn} do
      submit(conn, [open_group(%{"rooms" => [%{"room_id" => "free", "nightly_rate_cents" => 0}]})])

      assert group(conn)["outstanding_deposit_cents"] == 0

      assert [%{"code" => "payment_exceeds_outstanding"}] =
               submit(conn, [payment(%{"amount_cents" => 1})])

      assert [%{"refunded_cents" => 0, "retained_cents" => 0}] = submit(conn, [cancellation()])
      assert Repo.all(CashEntry) == []
    end

    test "duplicate groups do not replace the original booking", %{conn: conn} do
      assert [%{"revision" => 1}, %{"code" => "group_already_exists"}] =
               submit(conn, [open_group(), open_group(%{"guest_id" => "replacement"})])

      assert group(conn)["guest_id"] == "guest-22"
    end

    test "rejects invalid stays and rate plans without creating groups", %{conn: conn} do
      for fields <- [
            %{"arrival_on" => "2026-12-13"},
            %{"arrival_on" => "2026-12-14"},
            %{"arrival_on" => "2026-02-30"},
            %{"arrival_on" => nil},
            %{"departure_on" => 20_261_213},
            %{"departure_on" => "not-a-date"}
          ] do
        assert [%{"code" => "invalid_stay"}] = submit(conn, [open_group(fields)])
      end

      for rate_plan <- ["unknown", nil, 1, "FLEXIBLE"] do
        assert [%{"code" => "invalid_rate_plan"}] =
                 submit(conn, [open_group(%{"rate_plan" => rate_plan})])
      end

      assert Repo.all(Group) == []
    end

    test "rejects empty, duplicate, malformed, negative, fractional, and overflowing rooms", %{
      conn: conn
    } do
      room = %{"room_id" => "one", "nightly_rate_cents" => 100}

      invalid_rooms = [
        [],
        nil,
        %{},
        [room, room],
        [nil],
        [1],
        [%{}],
        [%{"room_id" => "", "nightly_rate_cents" => 100}],
        [%{"room_id" => 1, "nightly_rate_cents" => 100}]
      ]

      invalid_rooms =
        invalid_rooms ++
          for rate <- [-1, 1.5, "100", nil, true, 9_223_372_036_854_775_808],
              do: [Map.put(room, "nightly_rate_cents", rate)]

      for rooms <- invalid_rooms do
        assert [%{"code" => "invalid_rooms"}] = submit(conn, [open_group(%{"rooms" => rooms})])
      end

      assert [%{"code" => "invalid_rooms"}] =
               submit(conn, [
                 open_group(%{
                   "rooms" => [Map.put(room, "nightly_rate_cents", 9_223_372_036_854_775_807)]
                 })
               ])

      assert Repo.all(Group) == []
    end
  end

  describe "cash payments" do
    test "keeps large cent amounts exact when the combined ledger exceeds a database integer", %{
      conn: conn
    } do
      amount = 9_223_372_036_854_775_807

      for group_id <- ["large-a", "large-b"] do
        assert [%{"deposit_due_cents" => ^amount}, %{"outstanding_deposit_cents" => 0}] =
                 submit(conn, [
                   open_group(%{
                     "group_id" => group_id,
                     "rate_plan" => "advance_purchase",
                     "departure_on" => "2026-12-11",
                     "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => amount}]
                   }),
                   payment(%{"group_id" => group_id, "amount_cents" => amount})
                 ])
      end

      assert ledger(conn)["cash_held_cents"] == 2 * amount
      submit(conn, [cancellation(%{"group_id" => "large-a"})])
      assert ledger(conn)["cash_held_cents"] == amount
      assert ledger(conn)["cash_retained_cents"] == amount
    end

    test "funds the deposit in order, permits exact funding, and records accounting facts", %{
      conn: conn
    } do
      assert [
               %{"revision" => 1},
               %{"amount_cents" => 5_000, "outstanding_deposit_cents" => 14_500, "revision" => 2},
               %{"amount_cents" => 14_500, "outstanding_deposit_cents" => 0, "revision" => 3},
               %{"code" => "payment_exceeds_outstanding"}
             ] =
               submit(conn, [
                 open_group(),
                 payment(),
                 payment(%{"operation_id" => "pay-rest", "amount_cents" => 14_500}),
                 payment(%{"amount_cents" => 1})
               ])

      assert group(conn)["deposit_paid_cents"] == 19_500
      assert group(conn)["revision"] == 3
      assert ledger(conn)["cash_held_cents"] == 19_500

      entries = Repo.all(from entry in CashEntry, order_by: entry.id)
      assert Enum.map(entries, & &1.amount_cents) == [5_000, 14_500]

      assert Enum.all?(
               entries,
               &(&1.kind == :payment and &1.group_id == "group-81" and
                   &1.occurred_on == ~D[2026-11-01])
             )

      assert Enum.map(entries, & &1.operation_id) == ["record_cash_payment-1", "pay-rest"]
    end

    test "only positive integer cents are usable payments", %{conn: conn} do
      submit(conn, [open_group()])

      for amount <- [0, -1, 1.0, "100", nil, true, %{}, 9_223_372_036_854_775_808] do
        assert [%{"code" => "invalid_amount"}] =
                 submit(conn, [payment(%{"amount_cents" => amount})])
      end

      assert group(conn)["revision"] == 1
      assert Repo.all(CashEntry) == []
    end
  end

  describe "rescheduling" do
    test "shifts departure over a year boundary without changing prices or cash", %{conn: conn} do
      submit(conn, [open_group(), payment()])
      before = group(conn)

      assert [
               %{
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-01-02",
                 "new_departure_on" => "2027-01-05",
                 "revision" => 3
               }
             ] = submit(conn, [reschedule()])

      after_move = group(conn)
      assert after_move["arrival_on"] == "2027-01-02"
      assert after_move["departure_on"] == "2027-01-05"
      assert after_move["refundable_until"] == "2026-12-19"

      assert Map.drop(after_move, ~w(arrival_on departure_on refundable_until revision)) ==
               Map.drop(before, ~w(arrival_on departure_on refundable_until revision))

      assert ledger(conn)["cash_held_cents"] == 5_000
    end

    test "can move earlier, crosses leap day, and increments revision even for the same arrival",
         %{conn: conn} do
      submit(conn, [open_group(%{"arrival_on" => "2028-05-01", "departure_on" => "2028-05-04"})])

      assert [%{"new_departure_on" => "2028-03-02", "revision" => 2}, %{"revision" => 3}] =
               submit(conn, [
                 reschedule(%{"new_arrival_on" => "2028-02-28"}),
                 reschedule(%{"new_arrival_on" => "2028-02-28"})
               ])
    end

    test "rejects invalid dates and arrivals on or before the operation date", %{conn: conn} do
      submit(conn, [open_group()])

      for arrival <- [nil, 1, "2026-02-30", "2026-10-31", "2026-11-01", "9999-12-31"] do
        assert [%{"code" => "invalid_stay"}] =
                 submit(conn, [reschedule(%{"new_arrival_on" => arrival})])
      end

      assert group(conn)["revision"] == 1
    end
  end

  describe "cancellation and ledger" do
    test "refunds flexible cash at exactly 14 days and waives unpaid deposit", %{conn: conn} do
      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"refunded_cents" => 5_000, "retained_cents" => 0, "revision" => 3}
             ] =
               submit(conn, [
                 open_group(),
                 payment(),
                 cancellation(%{"occurred_on" => "2026-11-26"})
               ])

      assert ledger(conn) == %{
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }

      cancelled = group(conn)
      assert cancelled["status"] == "cancelled"
      assert cancelled["lodging_total_cents"] == 97_500
      assert cancelled["deposit_due_cents"] == 0
      assert cancelled["deposit_paid_cents"] == 0
      assert cancelled["outstanding_deposit_cents"] == 0

      snapshot = snapshot()

      for operation <- [payment(), reschedule(), cancellation()] do
        assert [%{"code" => "group_not_active"}] = submit(conn, [operation])
        assert snapshot() == snapshot
      end
    end

    test "retains flexible cash at 13 days, on arrival, or after arrival", %{conn: conn} do
      for {date, index} <- Enum.with_index(["2026-11-27", "2026-12-10", "2026-12-11"]) do
        id = "late-#{index}"

        assert [_, _, %{"refunded_cents" => 0, "retained_cents" => 5_000}] =
                 submit(conn, [
                   open_group(%{"group_id" => id}),
                   payment(%{"group_id" => id}),
                   cancellation(%{"group_id" => id, "occurred_on" => date})
                 ])
      end

      assert ledger(conn) == %{
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 15_000
             }
    end

    test "always retains advance-purchase cash even far before arrival", %{conn: conn} do
      assert [_, _, %{"refunded_cents" => 0, "retained_cents" => 97_500}] =
               submit(conn, [
                 open_group(%{"rate_plan" => "advance_purchase"}),
                 payment(%{"amount_cents" => 97_500}),
                 cancellation()
               ])

      assert ledger(conn)["cash_retained_cents"] == 97_500
    end

    test "cancellation without payment produces no cash movements", %{conn: conn} do
      for plan <- ["flexible", "advance_purchase"] do
        assert [_, %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}] =
                 submit(conn, [
                   open_group(%{"group_id" => plan, "rate_plan" => plan}),
                   cancellation(%{"group_id" => plan})
                 ])

        assert group(conn, plan)["outstanding_deposit_cents"] == 0
      end

      assert ledger(conn) == %{
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }

      assert Repo.all(CashEntry) == []
    end

    test "uses the rescheduled arrival to determine refundability", %{conn: conn} do
      assert [_, _, _, %{"refunded_cents" => 5_000, "retained_cents" => 0, "revision" => 4}] =
               submit(conn, [
                 open_group(),
                 payment(),
                 reschedule(),
                 cancellation(%{"occurred_on" => "2026-12-19"})
               ])

      assert [_, _, _, %{"refunded_cents" => 0, "retained_cents" => 5_000}] =
               submit(conn, [
                 open_group(%{"group_id" => "earlier"}),
                 payment(%{"group_id" => "earlier"}),
                 reschedule(%{"group_id" => "earlier", "new_arrival_on" => "2026-11-10"}),
                 cancellation(%{"group_id" => "earlier"})
               ])
    end

    test "aggregates held, refunded and retained cash across properties", %{conn: conn} do
      submit(conn, [open_group(), payment()])

      submit(conn, [
        open_group(%{"group_id" => "refunded", "property_id" => "london"}),
        payment(%{"group_id" => "refunded", "amount_cents" => 1_500}),
        cancellation(%{"group_id" => "refunded"})
      ])

      submit(conn, [
        open_group(%{
          "group_id" => "retained",
          "rate_plan" => "advance_purchase",
          "property_id" => "paris"
        }),
        payment(%{"group_id" => "retained", "amount_cents" => 2_500}),
        cancellation(%{"group_id" => "retained"})
      ])

      assert ledger(conn) == %{
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_held_cents" => 5_000,
               "cash_refunded_cents" => 1_500,
               "cash_retained_cents" => 2_500
             }
    end
  end

  describe "optimistic revisions" do
    test "sees earlier updates in the batch and leaves stale attempts unchanged", %{conn: conn} do
      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{
                 "operation_id" => "stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               },
               %{"revision" => 3},
               %{"refunded_cents" => 5_000, "revision" => 4}
             ] =
               submit(conn, [
                 open_group(),
                 payment(%{"expected_revision" => 1}),
                 payment(%{"operation_id" => "stale", "expected_revision" => 1}),
                 reschedule(%{"expected_revision" => 2}),
                 cancellation(%{"expected_revision" => 3})
               ])

      assert group(conn)["revision"] == 4
      assert ledger(conn)["cash_refunded_cents"] == 5_000
    end

    test "stale revisions precede amount, date, missing payload, and inactive-group validation",
         %{conn: conn} do
      submit(conn, [open_group(), payment()])

      for operation <- [
            payment(%{"amount_cents" => -1}),
            reschedule(%{"new_arrival_on" => "bad"}),
            Map.delete(payment(), "amount_cents"),
            cancellation(%{"occurred_on" => "bad"})
          ] do
        snapshot = snapshot()

        assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
                 submit(conn, [Map.put(operation, "expected_revision", 1)])

        assert snapshot() == snapshot
      end

      submit(conn, [cancellation()])

      for operation <- [payment(), reschedule(), cancellation()] do
        assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
                 submit(conn, [Map.put(operation, "expected_revision", 2)])

        assert [%{"code" => "group_not_active"}] =
                 submit(conn, [Map.put(operation, "expected_revision", 3)])
      end
    end

    test "resolves group existence before revision and payload checks", %{conn: conn} do
      for operation <- [
            payment(%{"amount_cents" => -1}),
            reschedule(%{"new_arrival_on" => "bad"}),
            cancellation()
          ] do
        assert [%{"code" => "group_not_found"}] =
                 submit(conn, [Map.put(operation, "expected_revision", 55)])
      end
    end

    test "requires an exact integer revision when supplied", %{conn: conn} do
      submit(conn, [open_group()])

      for expected <- [0, -1, 2, 1.0, "1", nil, true, %{}] do
        assert [
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => ^expected,
                   "actual_revision" => 1
                 }
               ] = submit(conn, [payment(%{"expected_revision" => expected})])
      end

      assert group(conn)["revision"] == 1
    end
  end

  test "missing group reads return 404 and the initial ledger is zero", %{conn: conn} do
    assert conn |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert ledger(conn) == %{
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  defp submit(conn, operations) do
    conn
    |> post_json(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp group(conn, id \\ "group-81") do
    conn |> get("/api/v1/groups/#{URI.encode(id)}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp snapshot do
    {Repo.all(from group in Group, order_by: group.group_id),
     Repo.all(from entry in CashEntry, order_by: entry.id)}
  end
end
