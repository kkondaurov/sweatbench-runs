defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerFixtures

  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Finance.CashEntry
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  describe "fixed cancellation policies" do
    for {booked_on, plan, version, deadline} <- [
          {"2026-12-31", "flexible", "flex-14", "2027-05-18"},
          {"2027-01-01", "flexible", "flex-30", "2027-05-02"},
          {"2027-01-02", "flexible", "flex-30", "2027-05-02"},
          {"2026-12-31", "advance_purchase", "advance-nonrefundable", nil},
          {"2027-01-01", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      test "#{plan} booked #{booked_on} keeps #{version} through rescheduling", %{conn: conn} do
        submit(conn, [
          open_group(%{
            "occurred_on" => unquote(booked_on),
            "rate_plan" => unquote(plan),
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-04"
          })
        ])

        assert %{"policy_version" => unquote(version), "refundable_until" => unquote(deadline)} =
                 group(conn)

        moved_deadline =
          case unquote(version) do
            "flex-14" -> "2028-02-16"
            "flex-30" -> "2028-01-31"
            "advance-nonrefundable" -> nil
          end

        assert [
                 %{
                   "revision" => 2,
                   "policy_version" => unquote(version),
                   "refundable_until" => ^moved_deadline,
                   "new_arrival_on" => "2028-03-01",
                   "new_departure_on" => "2028-03-04"
                 }
               ] =
                 submit(conn, [
                   operation("reschedule_group", %{
                     "occurred_on" => "2028-01-02",
                     "new_arrival_on" => "2028-03-01"
                   })
                 ])

        assert group(conn)["refundable_until"] == moved_deadline
        assert group(conn)["booked_on"] == unquote(booked_on)
      end
    end

    for {booked_on, cancelled_on, refunded} <- [
          {"2026-12-31", "2027-05-17", 5000},
          {"2026-12-31", "2027-05-18", 5000},
          {"2026-12-31", "2027-05-19", 0},
          {"2027-01-01", "2027-05-01", 5000},
          {"2027-01-01", "2027-05-02", 5000},
          {"2027-01-01", "2027-05-03", 0}
        ] do
      test "booking #{booked_on} settles cash on #{cancelled_on}", %{conn: conn} do
        assert [_, _, result] =
                 submit(conn, [
                   open_group(%{
                     "occurred_on" => unquote(booked_on),
                     "arrival_on" => "2027-06-01",
                     "departure_on" => "2027-06-04"
                   }),
                   operation("record_cash_payment", %{"amount_cents" => 5000}),
                   operation("cancel_group", %{"occurred_on" => unquote(cancelled_on)})
                 ])

        assert result["refunded_cents"] == unquote(refunded)
        assert result["retained_cents"] == 5000 - unquote(refunded)
        assert result["credit_issued_cents"] == 0
        assert result["revision"] == 3
      end
    end
  end

  describe "issuing hotel credit" do
    test "an unrepresentable credit expiry rejects atomically and cash remains refundable", %{
      conn: conn
    } do
      submit(conn, [
        open_group(%{
          "occurred_on" => "9999-01-01",
          "arrival_on" => "9999-12-20",
          "departure_on" => "9999-12-23"
        }),
        operation("record_cash_payment", %{"amount_cents" => 100, "occurred_on" => "9999-01-01"})
      ])

      before = snapshot()

      assert [%{"code" => "invalid_operation"}] =
               submit(conn, [
                 operation("cancel_group", %{
                   "refund_method" => "hotel_credit",
                   "occurred_on" => "9999-01-01"
                 })
               ])

      assert snapshot() == before

      assert [%{"refunded_cents" => 100, "revision" => 3}] =
               submit(conn, [operation("cancel_group", %{"occurred_on" => "9999-01-01"})])
    end

    for {cash, issued} <- [{4, 4}, {5, 6}, {6, 7}, {14, 15}, {15, 17}, {5000, 5500}] do
      test "#{cash} cents of cash earns #{issued} cents of credit with half-up rounding", %{
        conn: conn
      } do
        result = issue_credit(conn, " Cancel-É 17 ", unquote(cash), ~D[2027-05-03])

        assert %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => unquote(issued),
                 "revision" => 3
               } = result

        assert credit(conn, "2028-05-02") == %{
                 "guest_id" => "guest-22",
                 "available_cents" => unquote(issued),
                 "lots" => [
                   %{
                     "source_operation_id" => " Cancel-É 17 ",
                     "remaining_cents" => unquote(issued),
                     "expires_on" => "2028-05-02"
                   }
                 ]
               }

        assert ledger(conn, "2028-05-02") == %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => unquote(cash),
                 "credit_liability_cents" => unquote(issued)
               }

        assert credit(conn, "2028-05-03")["lots"] == []
        assert ledger(conn, "2028-05-03")["credit_liability_cents"] == 0
        assert ledger(conn, "2028-05-03")["cash_converted_to_credit_cents"] == unquote(cash)
      end
    end

    test "an unfunded refundable cancellation creates no lot or finance entry", %{conn: conn} do
      assert [_, %{"credit_issued_cents" => 0, "revision" => 2}] =
               submit(conn, [
                 open_group(),
                 operation("cancel_group", %{"refund_method" => "hotel_credit"})
               ])

      assert Repo.all(Lot) == []
      assert Repo.all(CashEntry) == []
    end

    for {plan, booked_on, cancelled_on} <- [
          {"flexible", "2026-12-31", "2027-05-19"},
          {"flexible", "2027-01-01", "2027-05-03"},
          {"advance_purchase", "2027-01-01", "2027-01-02"}
        ] do
      test "credit cannot bypass #{plan} policy booked #{booked_on}", %{conn: conn} do
        submit(conn, [
          open_group(%{
            "rate_plan" => unquote(plan),
            "occurred_on" => unquote(booked_on),
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-04"
          }),
          operation("record_cash_payment", %{"amount_cents" => 100})
        ])

        before = snapshot()

        assert [%{"code" => "refund_method_not_available"}] =
                 submit(conn, [
                   operation("cancel_group", %{
                     "occurred_on" => unquote(cancelled_on),
                     "refund_method" => "hotel_credit",
                     "expected_revision" => 2
                   })
                 ])

        assert snapshot() == before
        assert group(conn)["status"] == "active"
      end
    end

    test "invalid refund methods reject atomically", %{conn: conn} do
      submit(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 100})])
      before = snapshot()

      for method <- ["voucher", "", nil, 1, true, [], %{}] do
        assert [%{"code" => "invalid_operation"}] =
                 submit(conn, [operation("cancel_group", %{"refund_method" => method})])

        assert snapshot() == before
      end
    end
  end

  describe "applying and restoring lots" do
    test "one ordered batch can issue, spend, restore, and spend credit across a rejection", %{
      conn: conn
    } do
      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"revision" => 3, "credit_issued_cents" => 110},
               %{"revision" => 1},
               %{"code" => "insufficient_credit"},
               %{"revision" => 2},
               %{"revision" => 3, "credit_issued_cents" => 0},
               %{"revision" => 1},
               %{"revision" => 2, "outstanding_deposit_cents" => 19_390}
             ] =
               submit(conn, [
                 open_group(),
                 operation("record_cash_payment", %{"amount_cents" => 100}),
                 operation("cancel_group", %{"refund_method" => "hotel_credit"}),
                 open_group(%{"group_id" => "second"}),
                 operation("apply_hotel_credit", %{"group_id" => "second", "amount_cents" => 111}),
                 operation("apply_hotel_credit", %{
                   "group_id" => "second",
                   "amount_cents" => 110,
                   "expected_revision" => 1
                 }),
                 operation("cancel_group", %{"group_id" => "second", "expected_revision" => 2}),
                 open_group(%{"group_id" => "third"}),
                 operation("apply_hotel_credit", %{"group_id" => "third", "amount_cents" => 110})
               ])

      assert credit(conn)["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 110
      assert Repo.aggregate(Lot, :count) == 1

      assert %{"credit_paid_cents" => 110, "cash_paid_cents" => 0} =
               data(conn, ~p"/api/v1/groups/third")
    end

    test "lots are ordered by expiry, then source identifier, and can fund another property", %{
      conn: conn
    } do
      issue_credit(conn, "b", 100, ~D[2026-10-02])
      issue_credit(conn, "a", 200, ~D[2026-10-02])
      issue_credit(conn, "earliest", 50, ~D[2026-10-01])
      issue_credit(conn, "latest", 300, ~D[2026-10-03])
      issue_credit(conn, "expired", 1000, ~D[2025-01-01])

      assert Enum.map(credit(conn)["lots"], & &1["source_operation_id"]) ==
               ["earliest", "a", "b", "latest"]

      assert [_, %{"amount_cents" => 300, "outstanding_deposit_cents" => 19_200, "revision" => 2}] =
               submit(conn, [
                 open_group(%{"property_id" => "paris"}),
                 operation("apply_hotel_credit", %{
                   "amount_cents" => 300,
                   "expected_revision" => 1
                 })
               ])

      assert credit(conn)["lots"] == [
               %{
                 "source_operation_id" => "b",
                 "remaining_cents" => 85,
                 "expires_on" => "2027-10-02"
               },
               %{
                 "source_operation_id" => "latest",
                 "remaining_cents" => 330,
                 "expires_on" => "2027-10-03"
               }
             ]

      assert %{"cash_paid_cents" => 0, "credit_paid_cents" => 300, "deposit_paid_cents" => 300} =
               group(conn)

      assert ledger(conn)["credit_liability_cents"] == 715
      assert ledger(conn)["cash_held_cents"] == 0

      submit(conn, [operation("cancel_group")])
      assert credit(conn)["available_cents"] == 715
      assert Enum.map(credit(conn)["lots"], & &1["remaining_cents"]) == [55, 220, 110, 330]
      assert ledger(conn)["credit_liability_cents"] == 715
      assert Repo.aggregate(Lot, :count) == 5
    end

    test "credit funds the outstanding deposit alongside cash and sees earlier batch results", %{
      conn: conn
    } do
      issue_credit(conn, "source", 1000, ~D[2026-10-03])

      assert [
               %{"revision" => 1},
               %{"revision" => 2, "outstanding_deposit_cents" => 500},
               %{"code" => "payment_exceeds_outstanding"},
               %{"revision" => 3, "outstanding_deposit_cents" => 0},
               %{"code" => "payment_exceeds_outstanding"},
               %{"code" => "payment_exceeds_outstanding"}
             ] =
               submit(conn, [
                 open_group(),
                 operation("record_cash_payment", %{"amount_cents" => 19_000}),
                 operation("apply_hotel_credit", %{
                   "amount_cents" => 501,
                   "expected_revision" => 2
                 }),
                 operation("apply_hotel_credit", %{
                   "amount_cents" => 500,
                   "expected_revision" => 2
                 }),
                 operation("record_cash_payment", %{"amount_cents" => 1}),
                 operation("apply_hotel_credit", %{"amount_cents" => 1})
               ])

      assert %{
               "deposit_paid_cents" => 19_500,
               "cash_paid_cents" => 19_000,
               "credit_paid_cents" => 500,
               "revision" => 3
             } = group(conn)

      assert credit(conn)["available_cents"] == 600
      assert ledger(conn)["cash_held_cents"] == 19_000
      assert ledger(conn)["credit_liability_cents"] == 1100
    end

    for method <- ["cash", "hotel_credit"] do
      test "mixed funding settled as #{method} restores credit without another bonus", %{
        conn: conn
      } do
        issue_credit(conn, "original", 1000, ~D[2026-10-01])

        submit(conn, [
          open_group(),
          operation("apply_hotel_credit", %{"amount_cents" => 400}),
          operation("apply_hotel_credit", %{"amount_cents" => 700}),
          operation("record_cash_payment", %{"amount_cents" => 505})
        ])

        assert credit(conn)["lots"] == []

        assert [%{"revision" => 5, "retained_cents" => 0} = result] =
                 submit(conn, [
                   operation("cancel_group", %{
                     "operation_id" => "second-cancellation",
                     "refund_method" => unquote(method),
                     "expected_revision" => 4
                   })
                 ])

        issued = if unquote(method) == "hotel_credit", do: 556, else: 0
        refunded = if unquote(method) == "cash", do: 505, else: 0
        assert result["credit_issued_cents"] == issued
        assert result["refunded_cents"] == refunded
        assert credit(conn)["available_cents"] == 1100 + issued
        assert hd(credit(conn)["lots"])["source_operation_id"] == "original"
        assert hd(credit(conn)["lots"])["remaining_cents"] == 1100
        assert hd(credit(conn)["lots"])["expires_on"] == "2027-10-01"

        assert ledger(conn) == %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => refunded,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 1505 - refunded,
                 "credit_liability_cents" => 1100 + issued
               }

        assert %{
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "deposit_due_cents" => 0,
                 "status" => "cancelled"
               } = group(conn)
      end
    end

    test "restored credit can be reused repeatedly without extending expiry or earning bonuses",
         %{
           conn: conn
         } do
      issue_credit(conn, "original", 100, ~D[2026-10-03])

      for id <- ["first", "second"] do
        assert [_, _, %{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
                 submit(conn, [
                   open_group(%{"group_id" => id}),
                   operation("apply_hotel_credit", %{"group_id" => id, "amount_cents" => 110}),
                   operation("cancel_group", %{
                     "group_id" => id,
                     "refund_method" => "hotel_credit"
                   })
                 ])

        assert credit(conn)["available_cents"] == 110
        assert Repo.aggregate(Lot, :count) == 1
      end
    end

    for plan <- ["flexible", "advance_purchase"] do
      test "non-refundable #{plan} cancellation consumes applied credit and retains only cash", %{
        conn: conn
      } do
        issue_credit(conn, "source", 1000, ~D[2026-10-03])

        submit(conn, [
          open_group(%{"rate_plan" => unquote(plan)}),
          operation("apply_hotel_credit", %{"amount_cents" => 700}),
          operation("record_cash_payment", %{"amount_cents" => 123})
        ])

        before = snapshot()

        assert [%{"code" => "refund_method_not_available"}] =
                 submit(conn, [
                   operation("cancel_group", %{
                     "occurred_on" => "2026-12-01",
                     "refund_method" => "hotel_credit"
                   })
                 ])

        assert snapshot() == before

        assert [%{"retained_cents" => 123, "refunded_cents" => 0, "credit_issued_cents" => 0}] =
                 submit(conn, [operation("cancel_group", %{"occurred_on" => "2026-12-01"})])

        assert ledger(conn)["credit_liability_cents"] == 400
        assert ledger(conn)["cash_retained_cents"] == 123
        assert credit(conn)["available_cents"] == 400
        assert [%Allocation{status: :consumed}] = Repo.all(Allocation)
      end
    end
  end

  describe "expiry and liability" do
    test "large credit liabilities and conversions remain exact across lots and applications", %{
      conn: conn
    } do
      maximum = 9_223_372_036_854_775_807
      cash = div(maximum * 20 + 50, 100)
      issued = cash + div(cash + 5, 10)

      for number <- 1..6 do
        issue_credit(conn, "large-#{number}", cash, ~D[2026-10-03], %{
          "departure_on" => "2026-12-03",
          "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
        })
      end

      assert credit(conn)["available_cents"] == issued * 6
      assert ledger(conn)["credit_liability_cents"] == issued * 6
      assert ledger(conn)["cash_converted_to_credit_cents"] == cash * 6
      assert issued * 6 > maximum
      assert cash * 6 > maximum

      assert [_, %{"outstanding_deposit_cents" => 0}] =
               submit(conn, [
                 open_group(%{
                   "rate_plan" => "advance_purchase",
                   "departure_on" => "2026-12-11",
                   "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
                 }),
                 operation("apply_hotel_credit", %{"amount_cents" => maximum})
               ])

      assert ledger(conn)["credit_liability_cents"] == issued * 6
      assert credit(conn)["available_cents"] == issued * 6 - maximum
      submit(conn, [operation("cancel_group")])
      assert ledger(conn)["credit_liability_cents"] == issued * 6 - maximum
      assert ledger(conn)["cash_retained_cents"] == 0
    end

    for {cancelled_on, available} <- [
          {"2027-10-02", 2200},
          {"2027-10-03", 2200},
          {"2027-10-04", 1100}
        ] do
      test "credit restored on #{cancelled_on} observes its original inclusive expiry", %{
        conn: conn
      } do
        issue_credit(conn, "old", 1000, ~D[2026-10-03])
        issue_credit(conn, "new", 1000, ~D[2026-11-03])

        submit(conn, [
          open_group(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-04"}),
          operation("apply_hotel_credit", %{"amount_cents" => 1500, "occurred_on" => "2026-11-03"})
        ])

        # 1100 from the old lot is protected while applied; only unallocated
        # credit expires. Reads do not prematurely erase it or mutate records.
        before = snapshot()
        assert ledger(conn, "2027-10-04")["credit_liability_cents"] == 2200
        assert credit(conn, "2027-10-04")["available_cents"] == 700
        assert snapshot() == before

        assert [%{"refunded_cents" => 0, "credit_issued_cents" => 0, "revision" => 3}] =
                 submit(conn, [
                   operation("cancel_group", %{"occurred_on" => unquote(cancelled_on)})
                 ])

        assert credit(conn, unquote(cancelled_on))["available_cents"] == unquote(available)
        assert ledger(conn, unquote(cancelled_on))["credit_liability_cents"] == unquote(available)
        assert Enum.all?(Repo.all(Allocation), &(&1.status != :applied))
      end
    end

    test "expiry is paused only for applied credit and restored expired amounts stay forfeited",
         %{
           conn: conn
         } do
      issue_credit(conn, "source", 1000, ~D[2026-10-03])

      submit(conn, [
        open_group(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-04"}),
        operation("apply_hotel_credit", %{"amount_cents" => 600})
      ])

      assert ledger(conn, "2027-10-03")["credit_liability_cents"] == 1100
      assert ledger(conn, "2027-10-04")["credit_liability_cents"] == 600
      assert credit(conn, "2027-10-04")["available_cents"] == 0
      submit(conn, [operation("cancel_group", %{"occurred_on" => "2027-10-04"})])
      assert ledger(conn, "2027-10-04")["credit_liability_cents"] == 0
      assert [%Allocation{status: :expired}] = Repo.all(Allocation)
      assert [%Lot{remaining_cents: 500}] = Repo.all(Lot)
    end

    test "application uses occurred_on and accepts the last day but not the following day", %{
      conn: conn
    } do
      issue_credit(conn, "source", 1000, ~D[2026-10-03])
      submit(conn, [open_group()])

      assert [%{"revision" => 2}] =
               submit(conn, [
                 operation("apply_hotel_credit", %{
                   "amount_cents" => 600,
                   "occurred_on" => "2027-10-03"
                 })
               ])

      before = snapshot()

      assert [%{"code" => "insufficient_credit"}] =
               submit(conn, [
                 operation("apply_hotel_credit", %{
                   "amount_cents" => 1,
                   "occurred_on" => "2027-10-04"
                 })
               ])

      assert snapshot() == before
    end

    test "reads default to the UTC date and preserve guest identifiers", %{conn: conn} do
      today = Date.utc_today()
      guest_id = " Guest-É 22 "
      issue_credit(conn, "expires-today", 100, Date.add(today, -365), %{"guest_id" => guest_id})
      issue_credit(conn, "expired", 200, Date.add(today, -366), %{"guest_id" => guest_id})

      default_credit = data(conn, ~p"/api/v1/guests/#{guest_id}/credit")
      assert default_credit == credit(conn, Date.to_iso8601(today), guest_id)
      assert default_credit["guest_id"] == guest_id
      assert default_credit["available_cents"] == 110
      assert data(conn, ~p"/api/v1/ledger") == ledger(conn, Date.to_iso8601(today))
      assert data(conn, ~p"/api/v1/ledger")["credit_liability_cents"] == 110

      assert credit(conn, Date.to_iso8601(today), "unknown") == %{
               "guest_id" => "unknown",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "malformed query dates return a structured error without side effects", %{conn: conn} do
      for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"],
          query <- ["on=tomorrow", "on=2027-02-29", "on=", "on[]=2027-01-01"] do
        response = conn |> recycle() |> get(path <> "?" <> query) |> json_response(422)
        assert response == %{"error" => %{"code" => "invalid_date"}}
      end
    end
  end

  describe "validation, revision precedence, and atomic rejection" do
    test "insufficient credit leaves all lots intact and the next operation can use them", %{
      conn: conn
    } do
      issue_credit(conn, "first", 100, ~D[2026-10-01])
      issue_credit(conn, "second", 100, ~D[2026-10-02])
      submit(conn, [open_group()])
      before = snapshot()

      assert [%{"code" => "insufficient_credit"}] =
               submit(conn, [operation("apply_hotel_credit", %{"amount_cents" => 221})])

      assert snapshot() == before

      assert [%{"revision" => 2, "outstanding_deposit_cents" => 19_280}] =
               submit(conn, [
                 operation("apply_hotel_credit", %{
                   "amount_cents" => 220,
                   "expected_revision" => 1
                 })
               ])
    end

    test "a guest cannot spend another guest's credit", %{conn: conn} do
      issue_credit(conn, "source", 1000, ~D[2026-10-03])
      submit(conn, [open_group(%{"guest_id" => "other-guest"})])
      before = snapshot()

      assert [%{"code" => "insufficient_credit"}] =
               submit(conn, [operation("apply_hotel_credit", %{"amount_cents" => 1})])

      assert snapshot() == before
    end

    test "credit uses the payment validation errors and does not mutate on rejection", %{
      conn: conn
    } do
      issue_credit(conn, "source", 1000, ~D[2026-10-03])
      submit(conn, [open_group()])
      before = snapshot()

      for amount <- [0, -1, 1.0, "100", nil, true, [], %{}] do
        assert [%{"code" => "invalid_amount"}] =
                 submit(conn, [operation("apply_hotel_credit", %{"amount_cents" => amount})])

        assert snapshot() == before
      end

      assert [%{"code" => "invalid_operation"}] = submit(conn, [operation("apply_hotel_credit")])
      assert snapshot() == before
    end

    test "revision checks precede credit and refund method validation", %{conn: conn} do
      submit(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 100})])
      before = snapshot()

      for op <- [
            operation("apply_hotel_credit"),
            operation("apply_hotel_credit", %{"amount_cents" => 100}),
            operation("apply_hotel_credit", %{"amount_cents" => -1}),
            operation("apply_hotel_credit", %{"amount_cents" => 100_000}),
            operation("cancel_group", %{"refund_method" => nil}),
            operation("cancel_group", %{
              "refund_method" => "hotel_credit",
              "occurred_on" => "2026-12-01"
            })
          ] do
        assert [
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2,
                   "group_id" => "group-81"
                 }
               ] = submit(conn, [Map.put(op, "expected_revision", 1)])

        assert snapshot() == before
      end
    end

    test "missing and inactive groups take precedence, after revision checks for existing groups",
         %{
           conn: conn
         } do
      assert [%{"code" => "group_not_found"}] =
               submit(conn, [operation("apply_hotel_credit", %{"expected_revision" => 1})])

      submit(conn, [open_group(), operation("cancel_group")])
      before = snapshot()

      assert [
               %{"code" => "stale_revision", "actual_revision" => 2},
               %{"code" => "group_not_active"}
             ] =
               submit(conn, [
                 operation("apply_hotel_credit", %{"expected_revision" => 1}),
                 operation("apply_hotel_credit", %{"expected_revision" => 2})
               ])

      assert snapshot() == before
    end
  end

  defp issue_credit(conn, source_id, cash, on, overrides \\ %{}) do
    group_id = "source-#{System.unique_integer([:positive])}"
    date = Date.to_iso8601(on)

    results =
      submit(conn, [
        open_group(
          Map.merge(
            %{
              "group_id" => group_id,
              "occurred_on" => date,
              "arrival_on" => Date.to_iso8601(Date.add(on, 60)),
              "departure_on" => Date.to_iso8601(Date.add(on, 63))
            },
            overrides
          )
        ),
        operation("record_cash_payment", %{
          "group_id" => group_id,
          "occurred_on" => date,
          "amount_cents" => cash
        }),
        operation("cancel_group", %{
          "group_id" => group_id,
          "operation_id" => source_id,
          "occurred_on" => date,
          "refund_method" => "hotel_credit"
        })
      ])

    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    List.last(results)
  end

  defp submit(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp data(conn, path),
    do: conn |> recycle() |> get(path) |> json_response(200) |> Map.fetch!("data")

  defp group(conn), do: data(conn, ~p"/api/v1/groups/group-81")
  defp ledger(conn, on \\ "2026-10-03"), do: data(conn, ~p"/api/v1/ledger?on=#{on}")

  defp credit(conn, on \\ "2026-10-03", guest_id \\ "guest-22"),
    do: data(conn, ~p"/api/v1/guests/#{guest_id}/credit?on=#{on}")

  defp snapshot do
    for schema <- [Group, Room, CashEntry, Lot, Allocation],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
