defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "guest_id" => "guest-1",
        "property_id" => "prop-1",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 10_000},
          %{"room_id" => "r2", "nightly_rate_cents" => 10_000}
        ]
      },
      overrides
    )
  end

  defp pay(group_id, amount_cents, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(group_id, occurred_on, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extra
    )
  end

  defp apply_credit(group_id, amount_cents, occurred_on, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      extra
    )
  end

  defp read_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp guest_credit(conn, guest_id, query \\ "") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit#{query}")
    |> json_response(200)
  end

  defp ledger(conn, query \\ "") do
    conn
    |> get("/api/v1/ledger#{query}")
    |> json_response(200)
  end

  describe "policy versions" do
    test "flexible groups booked before 2027 keep the fourteen-day window", %{conn: conn} do
      submit_batch(conn, [open()])

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
             } = read_group(conn, "g-1")
    end

    test "flexible groups booked on or after 2027-01-01 use the thirty-day window", %{
      conn: conn
    } do
      op =
        open(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      submit_batch(conn, [op])

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-02-08"
               }
             } = read_group(conn, "g-1")
    end

    test "the policy window boundary is the booking date", %{conn: conn} do
      submit_batch(conn, [
        open(%{
          "operation_id" => "op-before",
          "group_id" => "before",
          "occurred_on" => "2026-12-31"
        }),
        open(%{
          "operation_id" => "op-after",
          "group_id" => "after",
          "occurred_on" => "2027-01-01"
        })
      ])

      assert %{"data" => %{"policy_version" => "flex-14"}} = read_group(conn, "before")
      assert %{"data" => %{"policy_version" => "flex-30"}} = read_group(conn, "after")
    end

    test "cancellation on the flex-30 refundable date is refundable", %{conn: conn} do
      op =
        open(%{
          "group_id" => "a",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      assert %{"results" => [_open, _pay, cancelled]} =
               submit_batch(conn, [
                 op,
                 pay("a", 5_000, "p-1"),
                 cancel("a", "2027-02-08", "c-1")
               ])

      assert cancelled["refunded_cents"] == 5_000
      assert cancelled["retained_cents"] == 0
    end

    test "cancellation the day after the flex-30 refundable date is retained", %{conn: conn} do
      op =
        open(%{
          "group_id" => "a",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      assert %{"results" => [_open, _pay, cancelled]} =
               submit_batch(conn, [
                 op,
                 pay("a", 5_000, "p-1"),
                 cancel("a", "2027-02-09", "c-1")
               ])

      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == 5_000
    end

    test "advance purchase groups are never refundable and have no refundable date", %{
      conn: conn
    } do
      submit_batch(conn, [open(%{"rate_plan" => "advance_purchase"})])

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = read_group(conn, "g-1")
    end

    test "rescheduling keeps the fixed policy and recomputes the refundable date", %{conn: conn} do
      booked =
        open(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      move = %{
        "operation_id" => "op-2",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "g-1",
        "new_arrival_on" => "2027-04-01"
      }

      assert %{"results" => [_, moved]} = submit_batch(conn, [booked, move])

      assert moved["policy_version"] == "flex-30"
      assert moved["refundable_until"] == "2027-03-02"

      assert %{
               "data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-03-02"}
             } = read_group(conn, "g-1")
    end
  end

  describe "issuing credit on cancellation" do
    test "converts refundable cash into a credit lot worth 110% when hotel_credit is selected",
         %{conn: conn} do
      assert %{"results" => [_open, _pay, cancelled]} =
               submit_batch(conn, [
                 open(),
                 pay("g-1", 10_000, "op-2"),
                 cancel("g-1", "2026-11-26", "op-3", %{"refund_method" => "hotel_credit"})
               ])

      assert cancelled == %{
               "operation_id" => "op-3",
               "status" => "applied",
               "group_id" => "g-1",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      assert ledger(conn) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 10_000,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 11_000,
                 "credit_shortfall_cents" => 0
               }
             }

      assert guest_credit(conn, "guest-1") == %{
               "data" => %{
                 "guest_id" => "guest-1",
                 "available_cents" => 11_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-3",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             }

      assert %{"data" => %{"status" => "cancelled"}} = read_group(conn, "g-1")
    end

    test "rounds the 10% bonus half up", %{conn: conn} do
      assert %{"results" => [_open, _pay, cancelled]} =
               submit_batch(conn, [
                 open(),
                 pay("g-1", 101, "op-2"),
                 cancel("g-1", "2026-11-26", "op-3", %{"refund_method" => "hotel_credit"})
               ])

      assert cancelled["credit_issued_cents"] == 111
      assert %{"data" => %{"available_cents" => 111}} = guest_credit(conn, "guest-1")
    end

    test "issues no lot when there is no cash to convert", %{conn: conn} do
      assert %{"results" => [_, cancelled]} =
               submit_batch(conn, [
                 open(),
                 cancel("g-1", "2026-11-26", "op-2", %{"refund_method" => "hotel_credit"})
               ])

      assert cancelled == %{
               "operation_id" => "op-2",
               "status" => "applied",
               "group_id" => "g-1",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 2
             }

      assert guest_credit(conn, "guest-1") == %{
               "data" => %{"guest_id" => "guest-1", "available_cents" => 0, "lots" => []}
             }

      assert %{"data" => %{"credit_liability_cents" => 0}} = ledger(conn)
    end

    test "rejects hotel_credit for a non-refundable cancellation and leaves the group active",
         %{conn: conn} do
      assert %{"results" => [_open, _pay, rejected]} =
               submit_batch(conn, [
                 open(),
                 pay("g-1", 5_000, "op-2"),
                 cancel("g-1", "2026-11-27", "op-3", %{"refund_method" => "hotel_credit"})
               ])

      assert rejected == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert %{"data" => %{"status" => "active", "revision" => 2}} = read_group(conn, "g-1")

      assert %{
               "data" => %{
                 "cash_held_cents" => 5_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = ledger(conn)

      assert guest_credit(conn, "guest-1")["data"]["available_cents"] == 0

      assert %{"results" => [settled]} =
               submit_batch(conn, [
                 cancel("g-1", "2026-11-27", "op-4")
               ])

      assert settled["retained_cents"] == 5_000
    end

    test "rejects hotel_credit for advance purchase reservations", %{conn: conn} do
      submit_batch(conn, [open(%{"rate_plan" => "advance_purchase"}), pay("g-1", 5_000, "op-2")])

      assert %{"results" => [rejected]} =
               submit_batch(conn, [
                 cancel("g-1", "2026-10-05", "op-3", %{"refund_method" => "hotel_credit"})
               ])

      assert rejected["code"] == "refund_method_not_available"

      assert %{"data" => %{"status" => "active"}} = read_group(conn, "g-1")
    end
  end

  describe "applying hotel credit" do
    defp seed_credit(conn, cancel_occurred_on, cancel_op_id) do
      result =
        submit_batch(conn, [
          open(),
          pay("g-1", 10_000, "op-2"),
          cancel("g-1", cancel_occurred_on, cancel_op_id, %{"refund_method" => "hotel_credit"})
        ])

      assert %{"results" => [_, _, %{"status" => "applied", "credit_issued_cents" => 11_000}]} =
               result

      :ok
    end

    test "applies available credit toward the outstanding deposit", %{conn: conn} do
      seed_credit(conn, "2026-11-26", "op-3")

      assert %{"results" => [_, _, _, _, applied]} =
               submit_batch(conn, [
                 open(),
                 pay("g-1", 10_000, "op-2"),
                 cancel("g-1", "2026-11-26", "op-3", %{"refund_method" => "hotel_credit"}),
                 open(%{"group_id" => "g-2", "operation_id" => "op-4"}),
                 apply_credit("g-2", 5_000, "2026-12-01", "op-5")
               ])

      assert applied == %{
               "operation_id" => "op-5",
               "status" => "applied",
               "group_id" => "g-2",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 7_000,
               "revision" => 2
             }

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 5_000,
                 "outstanding_deposit_cents" => 7_000
               }
             } = read_group(conn, "g-2")

      assert %{"data" => %{"available_cents" => 6_000}} = guest_credit(conn, "guest-1")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 11_000
               }
             } = ledger(conn)
    end

    test "consumes lots by earliest expiry first", %{conn: conn} do
      submit_batch(conn, [
        open(%{"group_id" => "a"}),
        pay("a", 10_000, "a-pay"),
        cancel("a", "2026-11-20", "c-early", %{"refund_method" => "hotel_credit"}),
        open(%{
          "group_id" => "b",
          "operation_id" => "b-open",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-13"
        }),
        pay("b", 10_000, "b-pay"),
        cancel("b", "2026-12-01", "c-late", %{"refund_method" => "hotel_credit"}),
        open(%{"group_id" => "c", "operation_id" => "c-open"}),
        apply_credit("c", 4_000, "2026-12-02", "c-apply")
      ])

      assert %{
               "data" => %{
                 "available_cents" => 18_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "c-early",
                     "remaining_cents" => 7_000,
                     "expires_on" => "2027-11-20"
                   },
                   %{
                     "source_operation_id" => "c-late",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-12-01"
                   }
                 ]
               }
             } = guest_credit(conn, "guest-1")
    end

    test "breaks ties between lots with the same expiry by source operation id", %{conn: conn} do
      submit_batch(conn, [
        open(%{"group_id" => "a"}),
        pay("a", 10_000, "a-pay"),
        cancel("a", "2026-11-26", "cg-z", %{"refund_method" => "hotel_credit"}),
        open(%{"group_id" => "b", "operation_id" => "b-open"}),
        pay("b", 10_000, "b-pay"),
        cancel("b", "2026-11-26", "cg-a", %{"refund_method" => "hotel_credit"}),
        open(%{"group_id" => "c", "operation_id" => "c-open"}),
        apply_credit("c", 1_000, "2026-12-01", "c-apply")
      ])

      assert %{
               "data" => %{
                 "lots" => [
                   %{"source_operation_id" => "cg-a", "remaining_cents" => 10_000},
                   %{"source_operation_id" => "cg-z", "remaining_cents" => 11_000}
                 ]
               }
             } = guest_credit(conn, "guest-1")
    end

    test "rejects amounts that are unusable or exceed the outstanding deposit", %{conn: conn} do
      seed_credit(conn, "2026-11-26", "op-3")

      for {amount, index} <- Enum.with_index([0, -5]) do
        assert %{"results" => [_, %{"status" => "rejected", "code" => "invalid_amount"}]} =
                 submit_batch(conn, [
                   open(%{"group_id" => "g-2", "operation_id" => "op-open-#{index}"}),
                   apply_credit("g-2", amount, "2026-12-01", "op-5-#{index}")
                 ])
      end

      assert %{"results" => [_, %{"code" => "payment_exceeds_outstanding"}]} =
               submit_batch(conn, [
                 open(%{"group_id" => "g-2", "operation_id" => "op-open-2"}),
                 apply_credit("g-2", 12_001, "2026-12-01", "op-5-2")
               ])

      assert %{"data" => %{"revision" => 1, "credit_paid_cents" => 0}} = read_group(conn, "g-2")
      assert %{"data" => %{"available_cents" => 11_000}} = guest_credit(conn, "guest-1")
    end

    test "rejects when the guest does not have enough unexpired credit", %{conn: conn} do
      seed_credit(conn, "2026-11-26", "op-3")

      assert %{"results" => [_, rejected]} =
               submit_batch(conn, [
                 open(%{"group_id" => "g-2", "operation_id" => "op-4"}),
                 apply_credit("g-2", 11_001, "2026-12-01", "op-5")
               ])

      assert rejected == %{
               "operation_id" => "op-5",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      assert %{"data" => %{"revision" => 1, "credit_paid_cents" => 0}} = read_group(conn, "g-2")
    end

    test "evaluates expiry using the operation's occurred_on date", %{conn: conn} do
      seed_credit(conn, "2026-11-26", "op-3")

      on_lot_expiry =
        submit_batch(conn, [
          open(%{"group_id" => "g-2", "operation_id" => "op-4"}),
          apply_credit("g-2", 1_000, "2027-11-26", "op-5")
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = on_lot_expiry

      after_lot_expiry =
        submit_batch(conn, [
          open(%{"group_id" => "g-3", "operation_id" => "op-6"}),
          apply_credit("g-3", 1_000, "2027-11-27", "op-7")
        ])

      assert %{"results" => [_, %{"status" => "rejected", "code" => "insufficient_credit"}]} =
               after_lot_expiry
    end

    test "rejects credit on an inactive group", %{conn: conn} do
      seed_credit(conn, "2026-11-26", "op-3")

      submit_batch(conn, [
        open(%{"group_id" => "g-2", "operation_id" => "op-4"}),
        cancel("g-2", "2026-11-26", "op-5")
      ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "group_not_active"}
               ]
             } =
               submit_batch(conn, [apply_credit("g-2", 1_000, "2026-12-01", "op-6")])
    end

    test "checks the revision before the credit rules", %{conn: conn} do
      submit_batch(conn, [open(%{"group_id" => "g-2", "operation_id" => "op-4"})])

      assert %{"results" => [stale]} =
               submit_batch(conn, [
                 apply_credit("g-2", 99_999, "2026-12-01", "op-5", %{
                   "expected_revision" => 9
                 })
               ])

      assert stale == %{
               "operation_id" => "op-5",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g-2",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               submit_batch(conn, [apply_credit("missing", 100, "2026-12-01", "op-6")])
    end
  end

  describe "settling credit-funded groups" do
    defp open_seeded(conn, seed_cancel_on, seed_cancel_op) do
      submit_batch(conn, [
        open(),
        pay("g-1", 10_000, "op-2"),
        cancel("g-1", seed_cancel_on, seed_cancel_op, %{"refund_method" => "hotel_credit"})
      ])

      :ok
    end

    test "refundable cancellation returns applied credit to its original lot, without a bonus",
         %{conn: conn} do
      open_seeded(conn, "2026-11-26", "op-3")

      assert %{"results" => [_, _, _, cancelled]} =
               submit_batch(conn, [
                 open(%{"group_id" => "g-2", "operation_id" => "op-4"}),
                 apply_credit("g-2", 5_000, "2026-10-20", "op-5"),
                 pay("g-2", 2_000, "op-6"),
                 cancel("g-2", "2026-11-20", "op-7")
               ])

      assert cancelled == %{
               "operation_id" => "op-7",
               "status" => "applied",
               "group_id" => "g-2",
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "revision" => 4
             }

      assert %{
               "data" => %{
                 "available_cents" => 11_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-3",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             } = guest_credit(conn, "guest-1")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 2_000,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 11_000
               }
             } = ledger(conn)
    end

    test "converts only the cash portion when hotel_credit is selected", %{conn: conn} do
      open_seeded(conn, "2026-11-26", "op-3")

      assert %{"results" => [_, _, _, cancelled]} =
               submit_batch(conn, [
                 open(%{"group_id" => "g-2", "operation_id" => "op-4"}),
                 apply_credit("g-2", 5_000, "2026-10-20", "op-5"),
                 pay("g-2", 2_000, "op-6"),
                 cancel("g-2", "2026-11-20", "op-7", %{"refund_method" => "hotel_credit"})
               ])

      assert cancelled == %{
               "operation_id" => "op-7",
               "status" => "applied",
               "group_id" => "g-2",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 2_200,
               "revision" => 4
             }

      assert %{
               "data" => %{
                 "available_cents" => 13_200,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-7",
                     "remaining_cents" => 2_200,
                     "expires_on" => "2027-11-20"
                   },
                   %{
                     "source_operation_id" => "op-3",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             } = guest_credit(conn, "guest-1")

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 12_000,
                 "credit_liability_cents" => 13_200
               }
             } = ledger(conn)
    end

    test "non-refundable cancellation consumes applied credit", %{conn: conn} do
      open_seeded(conn, "2026-11-26", "op-3")

      assert %{"results" => [_, _, cancelled]} =
               submit_batch(conn, [
                 open(%{"group_id" => "g-2", "operation_id" => "op-4"}),
                 apply_credit("g-2", 5_000, "2026-10-20", "op-5"),
                 cancel("g-2", "2026-11-27", "op-6")
               ])

      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == 0

      assert %{"data" => %{"available_cents" => 6_000}} = guest_credit(conn, "guest-1")
      assert %{"data" => %{"credit_liability_cents" => 6_000}} = ledger(conn)
    end

    test "restored credit whose expiry passed on the cancellation date expires immediately",
         %{conn: conn} do
      open_seeded(conn, "2026-11-26", "op-3")

      assert %{"results" => [_, _, cancelled]} =
               submit_batch(conn, [
                 open(%{
                   "group_id" => "g-2",
                   "operation_id" => "op-4",
                   "occurred_on" => "2027-06-01",
                   "arrival_on" => "2028-12-15",
                   "departure_on" => "2028-12-18"
                 }),
                 apply_credit("g-2", 5_000, "2027-10-01", "op-5"),
                 cancel("g-2", "2028-05-03", "op-6")
               ])

      assert cancelled == %{
               "operation_id" => "op-6",
               "status" => "applied",
               "group_id" => "g-2",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 3
             }

      assert %{"data" => %{"available_cents" => 6_000}} =
               guest_credit(conn, "guest-1", "?on=2027-10-02")

      assert %{"data" => %{"credit_liability_cents" => 6_000}} =
               ledger(conn, "?on=2027-10-02")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               guest_credit(conn, "guest-1", "?on=2028-05-03")

      assert %{"data" => %{"credit_liability_cents" => 0}} = ledger(conn, "?on=2028-05-03")
    end
  end

  describe "credit and ledger reads" do
    test "returns an empty credit balance for a guest with no credit", %{conn: conn} do
      assert guest_credit(conn, "nobody") == %{
               "data" => %{"guest_id" => "nobody", "available_cents" => 0, "lots" => []}
             }
    end

    test "the on parameter controls which lots count as available", %{conn: conn} do
      submit_batch(conn, [
        open(),
        pay("g-1", 10_000, "op-2"),
        cancel("g-1", "2026-11-26", "op-3", %{"refund_method" => "hotel_credit"})
      ])

      assert %{
               "data" => %{
                 "available_cents" => 11_000,
                 "lots" => [%{"expires_on" => "2027-11-26"}]
               }
             } =
               guest_credit(conn, "guest-1", "?on=2027-11-26")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               guest_credit(conn, "guest-1", "?on=2027-11-27")

      assert %{"data" => %{"credit_liability_cents" => 11_000}} = ledger(conn, "?on=2027-11-26")
      assert %{"data" => %{"credit_liability_cents" => 0}} = ledger(conn, "?on=2027-11-27")
    end
  end
end
