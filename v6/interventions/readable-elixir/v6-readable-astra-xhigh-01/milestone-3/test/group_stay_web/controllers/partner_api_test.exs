defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerFixtures

  alias GroupStay.Finance.CashEntry
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  describe "opening and reading groups" do
    test "persists the booking, exact identifiers, room order, price, and first revision", %{
      conn: conn
    } do
      booking =
        open_group(%{
          "operation_id" => "op-open_group",
          "group_id" => "Group-É 81",
          "guest_id" => " Guest-22 ",
          "expected_revision" => 99
        })

      assert [
               %{
                 "operation_id" => "op-open_group",
                 "status" => "applied",
                 "group_id" => "Group-É 81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ] = submit(conn, [booking])

      assert read_group(conn, "Group-É 81") == %{
               "group_id" => "Group-É 81",
               "guest_id" => " Guest-22 ",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "rooms" => booking["rooms"],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }

      assert ledger(conn) == empty_ledger()
      assert Repo.aggregate(Group, :count) == 1
      assert Repo.aggregate(Room, :count) == 2
    end

    test "rounds each room before summing and charges full lodging for advance purchase", %{
      conn: conn
    } do
      rooms = [
        %{"room_id" => "first", "nightly_rate_cents" => 3},
        %{"room_id" => "second", "nightly_rate_cents" => 3},
        %{"room_id" => "third", "nightly_rate_cents" => 2},
        %{"room_id" => "fourth", "nightly_rate_cents" => 3}
      ]

      booking = open_group(%{"departure_on" => "2026-12-11", "rooms" => rooms})

      # Rounding the combined lodging amount would incorrectly yield 2 cents.
      assert [%{"deposit_due_cents" => 3}, %{"deposit_due_cents" => 11}] =
               submit(conn, [
                 booking,
                 Map.merge(booking, %{
                   "operation_id" => "open-advance",
                   "group_id" => "advance",
                   "rate_plan" => "advance_purchase"
                 })
               ])

      assert read_group(conn)["lodging_total_cents"] == 11
      assert read_group(conn, "advance")["rate_plan"] == "advance_purchase"
    end

    test "allows a complimentary room and room identifiers reused in a different group", %{
      conn: conn
    } do
      booking = open_group(%{"rooms" => [%{"room_id" => "same-room", "nightly_rate_cents" => 0}]})

      assert [%{"deposit_due_cents" => 0}, %{"deposit_due_cents" => 0}] =
               submit(conn, [
                 booking,
                 Map.merge(booking, %{"operation_id" => "open-another", "group_id" => "another"})
               ])
    end

    test "rejects a duplicate group without overwriting it", %{conn: conn} do
      submit(conn, [open_group()])
      before = domain_snapshot()

      assert [%{"code" => "group_already_exists"}] =
               submit(conn, [open_group(%{"guest_id" => "replacement"})])

      assert domain_snapshot() == before
    end

    test "returns a structured 404 for a missing group", %{conn: conn} do
      assert conn |> get(~p"/api/v1/groups/missing") |> json_response(404) ==
               %{"error" => %{"code" => "group_not_found"}}
    end

    for {label, attrs, code} <- [
          {"zero nights", %{"departure_on" => "2026-12-10"}, "invalid_stay"},
          {"negative nights", %{"departure_on" => "2026-12-09"}, "invalid_stay"},
          {"impossible date", %{"arrival_on" => "2026-02-30"}, "invalid_stay"},
          {"non-date", %{"departure_on" => 42}, "invalid_stay"},
          {"unknown plan", %{"rate_plan" => "refundable"}, "invalid_rate_plan"},
          {"null plan", %{"rate_plan" => nil}, "invalid_rate_plan"},
          {"no rooms", %{"rooms" => []}, "invalid_rooms"},
          {"null rooms", %{"rooms" => nil}, "invalid_rooms"},
          {"room object", %{"rooms" => %{}}, "invalid_rooms"},
          {"non-object room", %{"rooms" => [nil]}, "invalid_rooms"},
          {"incomplete room", %{"rooms" => [%{"room_id" => "a"}]}, "invalid_rooms"},
          {"empty room id", %{"rooms" => [%{"room_id" => "", "nightly_rate_cents" => 1}]},
           "invalid_rooms"},
          {"negative rate", %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]},
           "invalid_rooms"},
          {"float rate", %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1.5}]},
           "invalid_rooms"},
          {"string rate", %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => "100"}]},
           "invalid_rooms"},
          {"duplicate rooms",
           %{
             "rooms" => [
               %{"room_id" => "a", "nightly_rate_cents" => 1},
               %{"room_id" => "a", "nightly_rate_cents" => 2}
             ]
           }, "invalid_rooms"},
          {"unrepresentable total",
           %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 9_223_372_036_854_775_807}]},
           "invalid_rooms"}
        ] do
      test "rejects #{label} atomically and continues the batch", %{conn: conn} do
        attrs = unquote(Macro.escape(attrs))
        code = unquote(code)

        assert [%{"status" => "rejected", "code" => ^code}, %{"status" => "applied"}] =
                 submit(conn, [open_group(attrs), open_group()])

        assert Repo.aggregate(Group, :count) == 1
        assert Repo.aggregate(Room, :count) == 2
        assert ledger(conn) == empty_ledger()
      end
    end
  end

  describe "payments and ordered batches" do
    test "later operations see earlier balances and revisions across a rejection", %{conn: conn} do
      assert [
               %{"revision" => 1},
               %{"amount_cents" => 5000, "outstanding_deposit_cents" => 14_500, "revision" => 2},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"amount_cents" => 14_500, "outstanding_deposit_cents" => 0, "revision" => 3}
             ] =
               submit(conn, [
                 open_group(),
                 operation("record_cash_payment", %{
                   "amount_cents" => 5000,
                   "expected_revision" => 1
                 }),
                 operation("record_cash_payment", %{
                   "amount_cents" => 14_501,
                   "expected_revision" => 2
                 }),
                 operation("record_cash_payment", %{
                   "amount_cents" => 14_500,
                   "expected_revision" => 2
                 })
               ])

      assert %{"deposit_paid_cents" => 19_500, "outstanding_deposit_cents" => 0, "revision" => 3} =
               read_group(conn)

      assert ledger(conn) == Map.put(empty_ledger(), "cash_held_cents", 19_500)
      assert Repo.aggregate(CashEntry, :count) == 2
    end

    for amount <- [0, -1, 1.0, "100", nil, true, [], %{}] do
      test "rejects invalid payment #{inspect(amount)} without changing domain record", %{
        conn: conn
      } do
        submit(conn, [open_group()])
        before = domain_snapshot()

        assert [%{"code" => "invalid_amount"}] =
                 submit(conn, [
                   operation("record_cash_payment", %{
                     "amount_cents" => unquote(Macro.escape(amount))
                   })
                 ])

        assert domain_snapshot() == before
      end
    end

    test "cannot pay a fully funded group", %{conn: conn} do
      submit(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 19_500})])
      before = domain_snapshot()

      assert [%{"code" => "payment_exceeds_outstanding"}] =
               submit(conn, [operation("record_cash_payment", %{"amount_cents" => 1})])

      assert domain_snapshot() == before
    end
  end

  describe "rescheduling" do
    test "shifts departure across a leap day without repricing or changing cash", %{conn: conn} do
      submit(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 1234})])
      original = read_group(conn)
      original_ledger = ledger(conn)

      assert [
               %{
                 "new_arrival_on" => "2028-02-28",
                 "new_departure_on" => "2028-03-02",
                 "revision" => 3
               }
             ] =
               submit(conn, [
                 operation("reschedule_group", %{
                   "new_arrival_on" => "2028-02-28",
                   "expected_revision" => 2
                 })
               ])

      assert read_group(conn) ==
               Map.merge(original, %{
                 "arrival_on" => "2028-02-28",
                 "departure_on" => "2028-03-02",
                 "refundable_until" => "2028-02-14",
                 "revision" => 3
               })

      assert ledger(conn) == original_ledger

      assert [%{"revision" => 4}] =
               submit(conn, [
                 operation("reschedule_group", %{
                   "new_arrival_on" => "2028-02-28",
                   "expected_revision" => 3
                 })
               ])
    end

    test "can move earlier while keeping arrival after the operation date", %{conn: conn} do
      assert [
               %{"revision" => 1},
               %{"new_arrival_on" => "2026-10-04", "new_departure_on" => "2026-10-07"}
             ] =
               submit(conn, [
                 open_group(),
                 operation("reschedule_group", %{"new_arrival_on" => "2026-10-04"})
               ])
    end

    for date <- ["2026-10-03", "2026-10-02", "2026-02-30", "9999-12-30", "tomorrow", nil, 123] do
      test "rejects unusable arrival #{inspect(date)} atomically", %{conn: conn} do
        submit(conn, [open_group()])
        before = domain_snapshot()

        assert [%{"code" => "invalid_stay"}] =
                 submit(conn, [
                   operation("reschedule_group", %{"new_arrival_on" => unquote(date)})
                 ])

        assert domain_snapshot() == before
      end
    end
  end

  describe "cancellation and finance" do
    for {plan, date, refunded, retained} <- [
          {"flexible", "2026-11-25", 5000, 0},
          {"flexible", "2026-11-26", 5000, 0},
          {"flexible", "2026-11-27", 0, 5000},
          {"flexible", "2026-12-10", 0, 5000},
          {"advance_purchase", "2026-10-04", 0, 5000}
        ] do
      test "settles #{plan} cash on #{date}", %{conn: conn} do
        submit(conn, [
          open_group(%{"rate_plan" => unquote(plan)}),
          operation("record_cash_payment", %{"amount_cents" => 5000})
        ])

        assert [
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => unquote(refunded),
                   "retained_cents" => unquote(retained),
                   "revision" => 3
                 }
               ] =
                 submit(conn, [
                   operation("cancel_group", %{
                     "occurred_on" => unquote(date),
                     "expected_revision" => 2
                   })
                 ])

        assert %{
                 "status" => "cancelled",
                 "revision" => 3,
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               } = read_group(conn)

        assert ledger(conn) == %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => unquote(refunded),
                 "cash_retained_cents" => unquote(retained),
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }

        assert Repo.aggregate(CashEntry, :count) == 2
      end
    end

    test "cancelling an unfunded group clears the requirement without creating cash", %{
      conn: conn
    } do
      assert [
               %{"revision" => 1},
               %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}
             ] =
               submit(conn, [open_group(), operation("cancel_group")])

      assert read_group(conn)["outstanding_deposit_cents"] == 0
      assert ledger(conn) == empty_ledger()
      assert Repo.aggregate(CashEntry, :count) == 0
    end

    test "refund policy uses the rescheduled arrival", %{conn: conn} do
      assert [_, _, _, %{"refunded_cents" => 0, "retained_cents" => 5000, "revision" => 4}] =
               submit(conn, [
                 open_group(),
                 operation("record_cash_payment", %{"amount_cents" => 5000}),
                 operation("reschedule_group", %{"new_arrival_on" => "2026-10-10"}),
                 operation("cancel_group", %{"occurred_on" => "2026-10-04"})
               ])
    end

    test "aggregates held and settled cash across properties and rate plans", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_group(%{"group_id" => "refunded", "property_id" => "paris"}),
        open_group(%{"group_id" => "retained", "rate_plan" => "advance_purchase"}),
        operation("record_cash_payment", %{"amount_cents" => 111}),
        operation("record_cash_payment", %{"group_id" => "refunded", "amount_cents" => 222}),
        operation("record_cash_payment", %{"group_id" => "retained", "amount_cents" => 333}),
        operation("cancel_group", %{
          "operation_id" => "op-cancel_group",
          "group_id" => "refunded"
        }),
        operation("cancel_group", %{"group_id" => "retained"})
      ])

      assert ledger(conn) == %{
               "cash_held_cents" => 111,
               "cash_refunded_cents" => 222,
               "cash_retained_cents" => 333,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }

      assert %CashEntry{
               group_id: "refunded",
               operation_id: "op-cancel_group",
               occurred_on: ~D[2026-10-03],
               kind: :refund,
               amount_cents: 222
             } =
               Repo.get_by!(CashEntry, group_id: "refunded", kind: :refund)
    end

    test "keeps large monetary totals exact across bookings and settlements", %{conn: conn} do
      maximum = 9_223_372_036_854_775_807

      booking =
        open_group(%{
          "rate_plan" => "advance_purchase",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
        })

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ] =
               submit(conn, [
                 booking,
                 Map.merge(booking, %{"operation_id" => "open-second", "group_id" => "second"}),
                 operation("record_cash_payment", %{"amount_cents" => maximum}),
                 operation("record_cash_payment", %{
                   "group_id" => "second",
                   "amount_cents" => maximum
                 })
               ])

      assert ledger(conn)["cash_held_cents"] == maximum * 2

      submit(conn, [
        operation("cancel_group"),
        operation("cancel_group", %{"group_id" => "second"})
      ])

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => maximum * 2,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "rejects all later mutations and reopening of a cancelled group", %{conn: conn} do
      submit(conn, [
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("cancel_group")
      ])

      before = domain_snapshot()

      assert [
               %{"code" => "group_not_active"},
               %{"code" => "group_not_active"},
               %{"code" => "group_not_active"},
               %{"code" => "group_already_exists"}
             ] =
               submit(conn, [
                 operation("record_cash_payment", %{"amount_cents" => 1, "expected_revision" => 3}),
                 operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
                 operation("cancel_group"),
                 open_group()
               ])

      assert domain_snapshot() == before
    end
  end

  describe "revision precedence" do
    test "stale revisions precede payment and stay validation without changing domain records", %{
      conn: conn
    } do
      submit(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 100})])
      before = domain_snapshot()

      for op <- [
            operation("record_cash_payment", %{"amount_cents" => -1}),
            operation("record_cash_payment", %{"amount_cents" => 99_999}),
            operation("record_cash_payment"),
            operation("reschedule_group", %{"new_arrival_on" => "invalid"}),
            operation("cancel_group", %{"occurred_on" => "invalid"})
          ] do
        assert submit(conn, [Map.put(op, "expected_revision", 1)]) == [
                 %{
                   "operation_id" => op["operation_id"],
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]

        assert domain_snapshot() == before
      end
    end

    test "stale revisions precede inactive group validation", %{conn: conn} do
      submit(conn, [open_group(), operation("cancel_group")])
      before = domain_snapshot()

      for type <- ~w(record_cash_payment reschedule_group cancel_group) do
        assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
                 submit(conn, [operation(type, %{"expected_revision" => 1})])
      end

      assert domain_snapshot() == before
    end

    test "missing groups are resolved before revisions and domain rules", %{conn: conn} do
      for type <- ~w(record_cash_payment reschedule_group cancel_group) do
        assert [%{"code" => "group_not_found"}] =
                 submit(conn, [operation(type, %{"expected_revision" => 1})])
      end

      assert domain_snapshot() == %{groups: [], rooms: [], cash_entries: []}
    end

    test "expected revisions must match without numeric or string coercion", %{conn: conn} do
      submit(conn, [open_group()])

      for revision <- [0, -1, 1.0, "1", nil, true, %{}, []] do
        assert [
                 %{
                   "code" => "stale_revision",
                   "actual_revision" => 1,
                   "expected_revision" => ^revision
                 }
               ] =
                 submit(conn, [operation("cancel_group", %{"expected_revision" => revision})])
      end

      assert read_group(conn)["revision"] == 1
    end
  end

  describe "batch and operation validation" do
    test "requires an operations array", %{conn: conn} do
      for body <- [
            %{},
            %{"operations" => nil},
            %{"operations" => %{}},
            %{"operations" => "bad"},
            [],
            nil,
            true,
            123,
            "bad"
          ] do
        response =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> post(~p"/api/v1/partner-batches", Jason.encode!(body))

        assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end

      assert submit(conn, []) == []
    end

    test "does not accept operations supplied only in the query string", %{conn: conn} do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches?operations[]=bad", "{}")

      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects malformed operations individually and continues", %{conn: conn} do
      malformed = [
        nil,
        true,
        123,
        "bad",
        [],
        %{},
        operation("unknown"),
        operation("cancel_group", %{"group_id" => 123})
      ]

      results = submit(conn, malformed ++ [open_group()])

      assert Enum.all?(
               Enum.drop(results, -1),
               &match?(%{"status" => "rejected", "code" => "invalid_operation"}, &1)
             )

      assert List.last(results)["status"] == "applied"
      assert length(results) == length(malformed) + 1
    end

    test "requires all opening fields without leaking groups or rooms", %{conn: conn} do
      for field <-
            ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms) do
        assert [%{"code" => "invalid_operation"}] =
                 submit(conn, [Map.delete(open_group(), field)])

        assert domain_snapshot() == %{groups: [], rooms: [], cash_entries: []}
      end
    end

    test "rejects invalid common fields and missing update data without a mutation", %{conn: conn} do
      submit(conn, [open_group()])
      before = domain_snapshot()

      for op <- [
            operation("record_cash_payment"),
            operation("reschedule_group"),
            operation("cancel_group", %{"operation_id" => ""}),
            operation("cancel_group", %{"occurred_on" => "2026-02-30"}),
            operation("cancel_group", %{"occurred_on" => nil}),
            operation("cancel_group", %{"occurred_on" => 100})
          ] do
        assert [%{"code" => "invalid_operation"}] = submit(conn, [op])
        assert domain_snapshot() == before
      end
    end
  end

  defp submit(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read_group(conn, group_id \\ "group-81") do
    conn
    |> recycle()
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> recycle() |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp empty_ledger do
    %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 0,
      "credit_liability_cents" => 0
    }
  end

  defp domain_snapshot do
    %{groups: Repo.all(Group), rooms: Repo.all(Room), cash_entries: Repo.all(CashEntry)}
  end
end
