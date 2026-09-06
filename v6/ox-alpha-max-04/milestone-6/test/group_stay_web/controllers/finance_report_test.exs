defmodule GroupStayWeb.Controllers.FinanceReportTest do
  use GroupStayWeb.ConnCase, async: true

  @starts_on "2026-06-01"

  describe "start_finance_reporting operation" do
    test "applies with exactly operation_id, status, and starts_on", %{conn: conn} do
      conn = post_operations(conn, [start_operation()])

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "rep-start",
               "status" => "applied",
               "starts_on" => @starts_on
             }
    end

    test "retrying the original operation replays the stored result", %{conn: conn} do
      conn = post_operations(conn, [start_operation()])
      assert %{"results" => [first]} = json_response(conn, 200)

      conn = post_operations(conn, [start_operation()])
      assert %{"results" => [second]} = json_response(conn, 200)

      assert second == first
    end

    test "a different start operation is rejected with reporting_already_started", %{conn: conn} do
      conn =
        post_operations(conn, [
          start_operation(),
          start_operation(%{"operation_id" => "rep-again"})
        ])

      assert %{"results" => [_, second]} = json_response(conn, 200)

      assert second == %{
               "operation_id" => "rep-again",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }
    end

    test "reusing the identifier with a different payload is a conflict", %{conn: conn} do
      conn =
        post_operations(conn, [
          start_operation(),
          start_operation(%{"starts_on" => "2026-07-01"})
        ])

      assert %{"results" => [_, second]} = json_response(conn, 200)

      assert second == %{
               "operation_id" => "rep-start",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
    end

    test "rejects an invalid or missing starts_on with invalid_reporting_date", %{conn: conn} do
      conn = post_operations(conn, [start_operation(%{"starts_on" => nil})])
      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "invalid_reporting_date"

      conn =
        post_operations(conn, [
          start_operation(%{"operation_id" => "rep-2", "starts_on" => "junk"})
        ])

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "invalid_reporting_date"

      conn =
        post_operations(conn, [
          start_operation(%{"operation_id" => "rep-3", "starts_on" => "2026-13-40"})
        ])

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "invalid_reporting_date"

      # No rejected start enabled reporting.
      assert json_response(get(conn, "/api/v1/finance/daily-report?date=#{@starts_on}"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "a retry of a rejected start returns the original rejection", %{conn: conn} do
      conn = post_operations(conn, [start_operation(%{"starts_on" => "junk"})])
      assert %{"results" => [rejected]} = json_response(conn, 200)

      conn = post_operations(conn, [start_operation(%{"starts_on" => "junk"})])
      assert %{"results" => [retried]} = json_response(conn, 200)

      assert retried == rejected
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "returns report_not_available before reporting has started", %{conn: conn} do
      _conn = post_operations(conn, [open_group_operation()])

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=#{@starts_on}"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "a missing or invalid date returns 422 as invalid_reporting_date", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/finance/daily-report"), 422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=junk"), 422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "returns 404 for a date before starts_on", %{conn: conn} do
      _conn = post_operations(conn, [open_group_operation(), start_operation()])

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-05-31"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end
  end

  describe "cash movements" do
    test "reports the opening position and post-start movements per property", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          payment_operation(),
          start_operation()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "occurred_on" => "2026-06-01",
            "amount_cents" => 3_000
          })
        ])

      assert report(conn, "2026-06-01") == %{
               "date" => "2026-06-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 5_000,
                   "movements" => %{zero_movements() | "received_cents" => 3_000},
                   "closing_held_cents" => 8_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               }
             }
    end

    test "omits properties whose opening, closing, and movements are all zero", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          start_operation()
        ])

      assert report(conn, "2026-06-01")["cash"] == []

      conn = post_operations(conn, [payment_operation(%{"occurred_on" => "2026-06-05"})])

      assert report(conn, "2026-06-01")["cash"] == []

      assert report(conn, "2026-06-05")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{zero_movements() | "received_cents" => 5_000},
                 "closing_held_cents" => 5_000
               }
             ]
    end

    test "the opening position includes committed operations even when occurred_on follows starts_on",
         %{
           conn: conn
         } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"occurred_on" => "2026-06-15"}),
          start_operation()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-01")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => zero_movements(),
                 "closing_held_cents" => 5_000
               }
             ]
    end

    test "a backdated payment submitted after the start posts on starts_on", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), start_operation()])

      conn = post_operations(conn, [payment_operation(%{"occurred_on" => "2026-05-15"})])

      assert report(conn, "2026-06-01")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{zero_movements() | "received_cents" => 5_000},
                 "closing_held_cents" => 5_000
               }
             ]
    end

    test "later submissions change an earlier open report, and reading never changes it", %{
      conn: conn
    } do
      conn = post_operations(conn, [open_group_operation(), start_operation()])
      assert report(conn, "2026-06-03")["cash"] == []

      conn = post_operations(conn, [payment_operation(%{"occurred_on" => "2026-06-02"})])

      first = report(conn, "2026-06-02")
      assert List.first(first["cash"])["movements"]["received_cents"] == 5_000

      assert report(conn, "2026-06-03")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => zero_movements(),
                 "closing_held_cents" => 5_000
               }
             ]

      assert report(conn, "2026-06-02") == first
      assert report(conn, "2026-06-02") == first
    end

    test "a refundable cancellation settles on the property where the cash was held", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-03"})
        ])

      assert %{"results" => [_, _, _, %{"refunded_cents" => 5_000}]} = json_response(conn, 200)

      assert report(conn, "2026-06-03")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => %{zero_movements() | "refunded_cents" => 5_000},
                 "closing_held_cents" => 0
               }
             ]
    end

    test "transfers move between the groups' properties and reductions follow the held cash", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          payment_operation(),
          start_operation(),
          transfer_operation(%{"occurred_on" => "2026-06-02"}),
          reduce_operation(%{"occurred_on" => "2026-06-04", "amount_cents" => 2_000})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-02")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => %{zero_movements() | "transferred_out_cents" => 3_000},
                 "closing_held_cents" => 2_000
               },
               %{
                 "property_id" => "bru-grand",
                 "opening_held_cents" => 0,
                 "movements" => %{zero_movements() | "transferred_in_cents" => 3_000},
                 "closing_held_cents" => 3_000
               }
             ]

      assert report(conn, "2026-06-04")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 2_000,
                 "movements" => zero_movements(),
                 "closing_held_cents" => 2_000
               },
               %{
                 "property_id" => "bru-grand",
                 "opening_held_cents" => 3_000,
                 "movements" => %{zero_movements() | "reduced_cents" => 2_000},
                 "closing_held_cents" => 1_000
               }
             ]

      assert %{"cash_held_cents" => 3_000} = ledger(conn)
    end

    test "charging back a settled refund reverses it where it was settled", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-02"}),
          charge_back_operation(%{"occurred_on" => "2026-06-05"})
        ])

      assert %{"results" => [_, _, _, _, %{"charged_back_cents" => 5_000}]} =
               json_response(conn, 200)

      assert report(conn, "2026-06-02")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => %{zero_movements() | "refunded_cents" => 5_000},
                 "closing_held_cents" => 0
               }
             ]

      assert report(conn, "2026-06-05")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   zero_movements()
                   | "refunded_cents" => -5_000,
                     "charged_back_cents" => 5_000
                 },
                 "closing_held_cents" => 0
               }
             ]
    end

    test "charging back held cash follows the property where it is held", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          start_operation(),
          payment_operation(%{"occurred_on" => "2026-06-02"}),
          charge_back_operation(%{"occurred_on" => "2026-06-04"})
        ])

      assert %{"results" => [_, _, _, %{"charged_back_cents" => 5_000}]} =
               json_response(conn, 200)

      assert report(conn, "2026-06-02")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{zero_movements() | "received_cents" => 5_000},
                 "closing_held_cents" => 5_000
               }
             ]

      assert report(conn, "2026-06-04")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => %{
                   zero_movements()
                   | "charged_back_cents" => 5_000
                 },
                 "closing_held_cents" => 0
               }
             ]
    end

    test "charging back a refund settled before the start reverses it where it was settled", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(),
          cancel_operation(%{"occurred_on" => "2026-05-25"}),
          start_operation(),
          charge_back_operation(%{"occurred_on" => "2026-06-10"})
        ])

      assert %{"results" => [_, _, _, _, %{"charged_back_cents" => 5_000}]} =
               json_response(conn, 200)

      # The refund itself predates the timeline: only the reversal posts.
      assert report(conn, "2026-06-10")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   zero_movements()
                   | "refunded_cents" => -5_000,
                     "charged_back_cents" => 5_000
                 },
                 "closing_held_cents" => 0
               }
             ]

      assert %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 5_000} = ledger(conn)
    end
  end

  describe "credit movements" do
    test "issued credit expires on the day after its expires_on date without any operation", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"amount_cents" => 8_000}),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-02", "refund_method" => "hotel_credit"})
        ])

      assert %{"results" => [_, _, _, %{"credit_issued_cents" => 8_800}]} =
               json_response(conn, 200)

      assert report(conn, "2026-06-02")["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{zero_credit_movements() | "issued_cents" => 8_800},
               "closing_liability_cents" => 8_800
             }

      assert report(conn, "2026-06-02")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 8_000,
                 "movements" => %{zero_movements() | "converted_to_credit_cents" => 8_000},
                 "closing_held_cents" => 0
               }
             ]

      expiry_day = Date.add(~D[2026-06-02], 367) |> Date.to_iso8601()

      assert report(conn, expiry_day)["credit"] == %{
               "opening_liability_cents" => 8_800,
               "movements" => %{zero_credit_movements() | "expired_cents" => 8_800},
               "closing_liability_cents" => 0
             }
    end

    test "applying credit posts no movement and a non-refundable settlement consumes it", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"amount_cents" => 8_000}),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-02", "refund_method" => "hotel_credit"}),
          open_group_operation(%{
            "operation_id" => "op-open-92",
            "group_id" => "group-92",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 15_000}]
          }),
          apply_credit_operation(%{
            "occurred_on" => "2026-06-05",
            "group_id" => "group-92",
            "amount_cents" => 3_000
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-92",
            "group_id" => "group-92",
            "occurred_on" => "2026-06-06"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-05")["credit"] == %{
               "opening_liability_cents" => 8_800,
               "movements" => zero_credit_movements(),
               "closing_liability_cents" => 8_800
             }

      assert report(conn, "2026-06-06")["credit"] == %{
               "opening_liability_cents" => 8_800,
               "movements" => %{zero_credit_movements() | "consumed_cents" => 3_000},
               "closing_liability_cents" => 5_800
             }

      assert %{"credit_liability_cents" => 5_800} = ledger(conn)
    end

    test "a chargeback revokes the credit entitlement its converted cash created", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"amount_cents" => 8_000}),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-02", "refund_method" => "hotel_credit"}),
          charge_back_operation(%{"occurred_on" => "2026-06-10"})
        ])

      assert %{"results" => [_, _, _, _, %{"charged_back_cents" => 8_000}]} =
               json_response(conn, 200)

      # The payment's entitlement telescopes to the issued lot: the bonus value
      # of its settled cash, 8800, revokes the whole unused lot.
      assert report(conn, "2026-06-10")["credit"] == %{
               "opening_liability_cents" => 8_800,
               "movements" => %{zero_credit_movements() | "revoked_cents" => 8_800},
               "closing_liability_cents" => 0
             }

      assert %{"credit_liability_cents" => 0} = ledger(conn)
    end

    test "restoration to a shortfalled lot is absorbed before becoming available", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 3_000}),
          payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 3_000}),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-02", "refund_method" => "hotel_credit"}),
          open_destination_operation(),
          apply_credit_operation(%{
            "occurred_on" => "2026-06-03",
            "group_id" => "group-92",
            "amount_cents" => 6_600
          }),
          charge_back_operation(%{
            "operation_id" => "op-cb",
            "occurred_on" => "2026-06-04",
            "payment_operation_id" => "op-pay-1"
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-92",
            "group_id" => "group-92",
            "occurred_on" => "2026-06-05"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-05")["credit"] == %{
               "opening_liability_cents" => 6_600,
               "movements" => %{zero_credit_movements() | "absorbed_cents" => 3_300},
               "closing_liability_cents" => 3_300
             }

      assert %{"credit_liability_cents" => 3_300} = ledger(conn)
    end

    test "a refundable restoration posts no credit movement", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"amount_cents" => 8_000}),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-02", "refund_method" => "hotel_credit"}),
          open_destination_operation(),
          apply_credit_operation(%{
            "occurred_on" => "2026-06-03",
            "group_id" => "group-92",
            "amount_cents" => 3_000
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-92",
            "group_id" => "group-92",
            "occurred_on" => "2026-06-06"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-06")["credit"] == %{
               "opening_liability_cents" => 8_800,
               "movements" => zero_credit_movements(),
               "closing_liability_cents" => 8_800
             }
    end

    test "the opening liability carries credit issued before reporting started", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"amount_cents" => 8_000}),
          cancel_operation(%{"occurred_on" => "2026-05-20", "refund_method" => "hotel_credit"}),
          start_operation()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-01")["credit"] == %{
               "opening_liability_cents" => 8_800,
               "movements" => zero_credit_movements(),
               "closing_liability_cents" => 8_800
             }
    end

    test "credit already expired before starts_on is not in the opening liability", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "occurred_on" => "2020-05-19",
            "arrival_on" => "2020-12-10",
            "departure_on" => "2020-12-13"
          }),
          payment_operation(%{"occurred_on" => "2020-05-19", "amount_cents" => 8_000}),
          cancel_operation(%{"occurred_on" => "2020-05-20", "refund_method" => "hotel_credit"}),
          start_operation()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-01")["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => zero_credit_movements(),
               "closing_liability_cents" => 0
             }

      assert report(conn, "2026-06-01")["cash"] == []
    end
  end

  describe "durable rules and reconciliation" do
    test "in one batch, operations before the start contribute to the opening position and operations after it contribute movements",
         %{
           conn: conn
         } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"occurred_on" => "2026-06-15"}),
          start_operation(),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "occurred_on" => "2026-06-01",
            "amount_cents" => 3_000
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-01")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => %{zero_movements() | "received_cents" => 3_000},
                 "closing_held_cents" => 8_000
               }
             ]
    end

    test "rejected operations leave no reporting movement", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          start_operation(),
          payment_operation(%{
            "operation_id" => "op-pay-1",
            "occurred_on" => "2026-06-02",
            "amount_cents" => 2_000
          }),
          payment_operation(%{
            "operation_id" => "op-pay-bad",
            "occurred_on" => "2026-06-02",
            "amount_cents" => 999_999
          }),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "occurred_on" => "2026-06-03",
            "amount_cents" => 1_000
          })
        ])

      assert %{"results" => [_, _, _, %{"status" => "rejected"}, _]} = json_response(conn, 200)

      assert report(conn, "2026-06-02")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{zero_movements() | "received_cents" => 2_000},
                 "closing_held_cents" => 2_000
               }
             ]

      assert report(conn, "2026-06-03")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 2_000,
                 "movements" => %{zero_movements() | "received_cents" => 1_000},
                 "closing_held_cents" => 3_000
               }
             ]
    end

    test "a durable retry does not report a movement twice", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), start_operation()])

      conn = post_operations(conn, [payment_operation(%{"occurred_on" => "2026-06-02"})])
      assert %{"results" => [first]} = json_response(conn, 200)

      conn = post_operations(conn, [payment_operation(%{"occurred_on" => "2026-06-02"})])
      assert %{"results" => [second]} = json_response(conn, 200)
      assert first == second

      entry = List.first(report(conn, "2026-06-02")["cash"])
      assert entry["movements"]["received_cents"] == 5_000

      assert %{"cash_held_cents" => 5_000} = ledger(conn)
    end

    test "report movements reconcile with the current views", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          payment_operation(),
          start_operation(),
          transfer_operation(%{"occurred_on" => "2026-06-02"}),
          reduce_operation(%{"occurred_on" => "2026-06-04", "amount_cents" => 2_000}),
          cancel_operation(%{"occurred_on" => "2026-06-06"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "cash_held_cents" => cash_held,
               "cash_refunded_cents" => refunded,
               "cash_reduced_cents" => reduced,
               "credit_liability_cents" => liability
             } =
               ledger(conn)

      # Movements post on their own dates; the ledger totals are cumulative.
      transfer_report = report(conn, "2026-06-02")
      reduce_report = report(conn, "2026-06-04")
      cancel_report = report(conn, "2026-06-06")

      assert Enum.reduce(
               transfer_report["cash"],
               0,
               &(&1["movements"]["transferred_out_cents"] + &2)
             ) ==
               3_000

      assert Enum.reduce(reduce_report["cash"], 0, &(&1["movements"]["reduced_cents"] + &2)) ==
               reduced

      assert Enum.reduce(cancel_report["cash"], 0, &(&1["movements"]["refunded_cents"] + &2)) ==
               refunded

      assert Enum.reduce(cancel_report["cash"], 0, &(&1["closing_held_cents"] + &2)) == cash_held

      assert cancel_report["credit"]["closing_liability_cents"] == liability
    end
  end

  defp start_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "rep-start",
        "type" => "start_finance_reporting",
        "occurred_on" => @starts_on,
        "starts_on" => @starts_on
      },
      overrides
    )
  end

  defp open_destination_operation(overrides \\ %{}) do
    open_group_operation(
      Map.merge(
        %{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "property_id" => "bru-grand",
          "rooms" => [
            %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-d", "nightly_rate_cents" => 8_333}
          ]
        },
        overrides
      )
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-05-20",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-06-03",
        "group_id" => "group-92",
        "amount_cents" => 3_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-06-02",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp transfer_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-06-02",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 3_000
      },
      overrides
    )
  end

  defp reduce_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-06-04",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cb",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-06-05",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp report(conn, date) do
    assert %{"data" => data} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=#{date}"), 200)

    data
  end

  defp ledger(conn) do
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger"), 200)
    data
  end

  defp zero_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end
end
