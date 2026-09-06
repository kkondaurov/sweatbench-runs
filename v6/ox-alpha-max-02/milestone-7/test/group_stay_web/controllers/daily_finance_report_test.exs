defmodule GroupStayWeb.Controllers.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  @issued_on ~D[2026-11-26]

  defp start_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-11-01"
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount, occurred_on \\ "2026-11-02") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-" <> group_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp fetch_report(conn, date) do
    response = get(conn, "/api/v1/finance/daily-report?date=#{date}")
    {response.status, json_response(response, response.status)}
  end

  defp fetch_report!(conn, date) do
    {status, body} = fetch_report(conn, date)
    assert status == 200
    body["data"]
  end

  defp fetch_ledger_as_of(conn, date) do
    assert %{"data" => ledger} =
             get(conn, "/api/v1/ledger?on=#{date}") |> json_response(200)

    ledger
  end

  defp zero_cash_movements do
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

  defp cash_entry(property_id, opening, closing, movements_override \\ %{}) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), movements_override),
      "closing_held_cents" => closing
    }
  end

  defp credit_section(opening, closing, movements_override \\ %{}) do
    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(zero_credit_movements(), movements_override),
      "closing_liability_cents" => closing
    }
  end

  defp late_adjustments_block(cash \\ [], credit_movements_override \\ %{}) do
    %{
      "cash" => cash,
      "credit" => Map.merge(zero_credit_movements(), credit_movements_override)
    }
  end

  describe "starting finance reporting" do
    test "the applied result contains exactly the operation identifier, status, and date", %{
      conn: conn
    } do
      assert [%{"operation_id" => "op-start", "status" => "applied", "starts_on" => "2026-11-01"}] =
               run_batch(conn, [start_operation()])
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      results =
        run_batch(conn, [
          start_operation(%{"operation_id" => "s-missing", "starts_on" => nil})
          |> Map.delete("starts_on"),
          start_operation(%{"operation_id" => "s-garbage", "starts_on" => "not-a-date"}),
          start_operation(%{"operation_id" => "s-impossible", "starts_on" => "2026-02-30"}),
          start_operation(%{"operation_id" => "s-number", "starts_on" => 20_261_101})
        ])

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.uniq(Enum.map(results, & &1["code"])) == ["invalid_reporting_date"]

      assert Enum.map(results, & &1["operation_id"]) ==
               ~w(s-missing s-garbage s-impossible s-number)
    end

    test "a different start is rejected once reporting has started", %{conn: conn} do
      run_batch(conn, [start_operation()])

      assert [
               %{
                 "operation_id" => "op-start-later",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ] =
               run_batch(conn, [start_operation(%{"operation_id" => "op-start-later"})])
    end

    test "a retry of the original start replays its stored result and a changed payload conflicts",
         %{
           conn: conn
         } do
      run_batch(conn, [start_operation()])

      assert [%{"operation_id" => "op-start", "status" => "applied", "starts_on" => "2026-11-01"}] =
               run_batch(conn, [start_operation()])

      assert [
               %{
                 "operation_id" => "op-start",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] =
               run_batch(conn, [start_operation(%{"starts_on" => "2026-12-01"})])
    end
  end

  describe "reading one day" do
    test "returns 404 before reporting has started and for dates before starts_on", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert fetch_report(conn, "2026-11-01") ==
               {404, %{"error" => %{"code" => "report_not_available"}}}

      run_batch(conn, [start_operation(%{"starts_on" => "2026-11-05"})])

      assert fetch_report(conn, "2026-11-04") ==
               {404, %{"error" => %{"code" => "report_not_available"}}}

      assert fetch_report!(conn, "2026-11-05")["status"] == "open"
    end

    test "rejects a missing or invalid date with invalid_reporting_date", %{conn: conn} do
      run_batch(conn, [start_operation()])

      missing = get(conn, "/api/v1/finance/daily-report")
      assert missing.status == 422
      assert json_response(missing, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      for bad <- ["not-a-date", "2026-13-01", "", "2026-2-1"] do
        assert fetch_report(conn, bad) ==
                 {422, %{"error" => %{"code" => "invalid_reporting_date"}}}
      end
    end

    test "an empty first report has exactly the documented shape", %{conn: conn} do
      run_batch(conn, [start_operation()])

      assert fetch_report!(conn, "2026-11-01") == %{
               "date" => "2026-11-01",
               "status" => "open",
               "cash" => [],
               "credit" => credit_section(0, 0),
               "late_adjustments" => late_adjustments_block()
             }
    end
  end

  describe "cash movements" do
    test "reports received cash at the paying property with the exact entry shape", %{conn: conn} do
      run_batch(conn, [start_operation(), open_operation(), payment("p1", "group-81", 10_000)])

      assert fetch_report!(conn, "2026-11-02")["cash"] == [
               cash_entry("ams-canal", 0, 10_000, %{"received_cents" => 10_000})
             ]

      assert fetch_report!(conn, "2026-11-02")["credit"] == credit_section(0, 0)
    end

    test "carries the opening position forward across days", %{conn: conn} do
      run_batch(conn, [start_operation(), open_operation(), payment("p1", "group-81", 10_000)])

      assert fetch_report!(conn, "2026-11-03")["cash"] == [
               cash_entry("ams-canal", 10_000, 10_000)
             ]
    end

    test "operations already committed form the opening position even when they occurred after starts_on",
         %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        payment("p1", "group-81", 10_000, "2026-11-20"),
        start_operation()
      ])

      assert fetch_report!(conn, "2026-11-01")["cash"] == [
               cash_entry("ams-canal", 10_000, 10_000)
             ]

      assert fetch_report!(conn, "2026-11-20")["cash"] == [
               cash_entry("ams-canal", 10_000, 10_000)
             ]
    end

    test "in one batch, operations before the start feed the opening and operations after it move",
         %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        payment("early", "group-81", 3_000, "2026-11-03"),
        start_operation(),
        payment("late", "group-81", 2_000, "2026-11-04")
      ])

      assert fetch_report!(conn, "2026-11-01")["cash"] == [cash_entry("ams-canal", 3_000, 3_000)]
      assert fetch_report!(conn, "2026-11-03")["cash"] == [cash_entry("ams-canal", 3_000, 3_000)]

      assert fetch_report!(conn, "2026-11-04")["cash"] == [
               cash_entry("ams-canal", 3_000, 5_000, %{"received_cents" => 2_000})
             ]
    end

    test "a refundable cancellation reports refunded cash", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 12_000),
        cancel("group-81", "2026-11-26")
      ])

      assert fetch_report!(conn, "2026-11-26")["cash"] == [
               cash_entry("ams-canal", 12_000, 0, %{"refunded_cents" => 12_000})
             ]
    end

    test "a non-refundable cancellation reports retained cash", %{conn: conn} do
      run_batch(conn, [
        start_operation(%{"starts_on" => "2026-09-15"}),
        open_operation(%{
          "operation_id" => "op-open-adv",
          "group_id" => "g-adv",
          "rate_plan" => "advance_purchase"
        }),
        payment("p1", "g-adv", 5_000, "2026-09-20"),
        cancel("g-adv", "2026-10-04")
      ])

      assert fetch_report!(conn, "2026-10-04")["cash"] == [
               cash_entry("ams-canal", 5_000, 0, %{"retained_cents" => 5_000})
             ]
    end

    test "a reduction reports reduced cash where it was held", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 8_000),
        %{
          "operation_id" => "red-1",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-11-04",
          "payment_operation_id" => "p1",
          "amount_cents" => 3_000
        }
      ])

      assert fetch_report!(conn, "2026-11-04")["cash"] == [
               cash_entry("ams-canal", 8_000, 5_000, %{"reduced_cents" => 3_000})
             ]
    end
  end

  describe "deposit transfers" do
    test "transfer movements use source and destination properties and stay equal company-wide",
         %{
           conn: conn
         } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000),
        open_operation(%{
          "operation_id" => "op-open-rtm",
          "group_id" => "g-rtm",
          "property_id" => "rtm-haven"
        }),
        %{
          "operation_id" => "t1",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-11-03",
          "source_group_id" => "group-81",
          "destination_group_id" => "g-rtm",
          "amount_cents" => 4_000
        }
      ])

      assert fetch_report!(conn, "2026-11-03")["cash"] == [
               cash_entry("ams-canal", 10_000, 6_000, %{"transferred_out_cents" => 4_000}),
               cash_entry("rtm-haven", 0, 4_000, %{"transferred_in_cents" => 4_000})
             ]
    end

    test "settlement and corrections follow the affected cash to the property where it moved", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000),
        open_operation(%{
          "operation_id" => "op-open-rtm",
          "group_id" => "g-rtm",
          "property_id" => "rtm-haven",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-26"
        }),
        %{
          "operation_id" => "t1",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-11-03",
          "source_group_id" => "group-81",
          "destination_group_id" => "g-rtm",
          "amount_cents" => 4_000
        },
        cancel("g-rtm", "2026-12-10")
      ])

      # The transferred cash refunds at the destination property. The transfer
      # itself is prior history by now and shows up only in the openings.
      assert fetch_report!(conn, "2026-12-10")["cash"] == [
               cash_entry("ams-canal", 6_000, 6_000),
               cash_entry("rtm-haven", 4_000, 0, %{"refunded_cents" => 4_000})
             ]

      # The chargeback splits across both: held cash reverses where it is still
      # held, the settled refund reverses where it was settled.
      run_batch(conn, [
        %{
          "operation_id" => "cb-1",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-01-05",
          "payment_operation_id" => "p1"
        }
      ])

      assert fetch_report!(conn, "2027-01-05")["cash"] == [
               cash_entry("ams-canal", 6_000, 0, %{"charged_back_cents" => 6_000}),
               cash_entry("rtm-haven", 0, 0, %{
                 "charged_back_cents" => 4_000,
                 "refunded_cents" => -4_000
               })
             ]
    end
  end

  describe "chargebacks reversing settled history" do
    test "reversing an earlier refund reports negative refunded together with positive charged back",
         %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 6_000),
        cancel("group-81", "2026-11-26"),
        %{
          "operation_id" => "cb-1",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-12-15",
          "payment_operation_id" => "p1"
        }
      ])

      assert fetch_report!(conn, "2026-12-15")["cash"] == [
               cash_entry("ams-canal", 0, 0, %{
                 "refunded_cents" => -6_000,
                 "charged_back_cents" => 6_000
               })
             ]
    end

    test "charging back a conversion revokes the bonus entitlement from the liability", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000),
        cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
        %{
          "operation_id" => "cb-1",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-12-01",
          "payment_operation_id" => "p1"
        }
      ])

      assert fetch_report!(conn, "2026-11-26")["credit"] ==
               credit_section(0, 11_000, %{"issued_cents" => 11_000})

      # Reversing the earlier conversion reports it as a negative conversion
      # alongside the positive charged-back amount.
      assert fetch_report!(conn, "2026-12-01")["cash"] == [
               cash_entry("ams-canal", 0, 0, %{
                 "charged_back_cents" => 10_000,
                 "converted_to_credit_cents" => -10_000
               })
             ]

      assert fetch_report!(conn, "2026-12-01")["credit"] ==
               credit_section(11_000, 10_000, %{"revoked_cents" => 1_000})
    end

    test "restored credit absorbed by a clawback reports absorbed liability", %{conn: conn} do
      # 10_000 cash converts into an 11_000 lot. Applying 10_800 leaves 200
      # unused, so the payment's 1_000 entitlement is mostly unrecoverable when
      # the chargeback arrives; the refundable restoration then absorbs it.
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000),
        cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
        open_operation(%{
          "operation_id" => "op-open-two",
          "group_id" => "g-two",
          "guest_id" => "guest-22",
          "property_id" => "rtm-haven",
          "booked_on" => "2026-11-10",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-27"
        }),
        %{
          "operation_id" => "apply-1",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-12-01",
          "group_id" => "g-two",
          "amount_cents" => 10_800
        },
        %{
          "operation_id" => "cb-1",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-12-02",
          "payment_operation_id" => "p1"
        },
        cancel("g-two", "2026-12-10")
      ])

      assert fetch_report!(conn, "2026-11-26")["credit"] ==
               credit_section(0, 11_000, %{"issued_cents" => 11_000})

      # Applying credit changes no liability.
      assert fetch_report!(conn, "2026-12-01")["credit"] == credit_section(11_000, 11_000)

      # The chargeback revokes only what still lives in the lot; the remaining
      # 800 cents of entitlement become unrecovered clawback - not a movement
      # until something absorbs it.
      assert fetch_report!(conn, "2026-12-02")["credit"] ==
               credit_section(11_000, 10_800, %{"revoked_cents" => 200})

      # The refundable settlement restores the applied credit; the clawback
      # absorbs its first 800 cents.
      assert fetch_report!(conn, "2026-12-10")["credit"] ==
               credit_section(10_800, 10_000, %{"absorbed_cents" => 800})

      assert fetch_ledger(conn)["credit_shortfall_cents"] == 0
    end
  end

  describe "hotel credit" do
    test "applying credit moves nothing and consuming it happens on non-refundable settlement", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000),
        cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
        open_operation(%{
          "operation_id" => "op-open-two",
          "group_id" => "g-two",
          "property_id" => "rtm-haven",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        }),
        %{
          "operation_id" => "apply-1",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-12-01",
          "group_id" => "g-two",
          "amount_cents" => 4_000
        },
        cancel("g-two", "2026-12-02")
      ])

      # Applying credit changes no liability and has no movement column.
      assert fetch_report!(conn, "2026-12-01")["credit"] == credit_section(11_000, 11_000)
      # The unfunded destination property appears nowhere in the cash array.
      assert fetch_report!(conn, "2026-12-01")["cash"] == []

      assert fetch_report!(conn, "2026-12-02")["credit"] ==
               credit_section(11_000, 7_000, %{"consumed_cents" => 4_000})

      assert fetch_ledger(conn)["credit_liability_cents"] == 7_000
    end

    test "unused credit expires on the day after expires_on without any submitted operation", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000),
        cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      ])

      last_usable = Date.add(@issued_on, 366) |> Date.to_iso8601()
      expiry_day = Date.add(@issued_on, 367) |> Date.to_iso8601()

      assert fetch_report!(conn, last_usable)["credit"] == credit_section(11_000, 11_000)

      assert fetch_report!(conn, expiry_day)["credit"] ==
               credit_section(11_000, 0, %{"expired_cents" => 11_000})

      # The ledger read as of the expiry day reconciles with the report.
      assert fetch_ledger_as_of(conn, expiry_day)["credit_liability_cents"] == 0
    end
  end

  describe "posting dates" do
    test "an operation processed after reporting starts posts at the later of its date and starts_on",
         %{conn: conn} do
      run_batch(conn, [start_operation(%{"starts_on" => "2026-11-05"})])
      run_batch(conn, [open_operation(), payment("early", "group-81", 2_000, "2026-10-20")])

      assert fetch_report!(conn, "2026-11-05")["cash"] == [
               cash_entry("ams-canal", 0, 2_000, %{"received_cents" => 2_000})
             ]
    end

    test "a later submission changes an earlier open report", %{conn: conn} do
      run_batch(conn, [start_operation(), open_operation()])
      run_batch(conn, [payment("later", "group-81", 5_000, "2026-11-08")])

      assert fetch_report!(conn, "2026-11-06")["cash"] == []

      run_batch(conn, [payment("backdated", "group-81", 1_500, "2026-11-06")])

      assert fetch_report!(conn, "2026-11-06")["cash"] == [
               cash_entry("ams-canal", 0, 1_500, %{"received_cents" => 1_500})
             ]

      assert fetch_report!(conn, "2026-11-06") == fetch_report!(conn, "2026-11-06")

      # Earlier days are untouched by the submission that posted later.
      assert fetch_report!(conn, "2026-11-05")["cash"] == []
    end
  end

  describe "durability and rejection" do
    test "rejected operations leave no reporting movement", %{conn: conn} do
      results =
        run_batch(conn, [
          start_operation(),
          open_operation(),
          payment("ok-1", "group-81", 2_000, "2026-11-02"),
          payment("too-much", "group-81", 999_999, "2026-11-03"),
          payment("missing-group", "ghost", 100, "2026-11-03"),
          payment("ok-2", "group-81", 3_000, "2026-11-04")
        ])

      assert Enum.at(results, 3)["code"] == "payment_exceeds_outstanding"
      assert Enum.at(results, 4)["code"] == "group_not_found"

      assert fetch_report!(conn, "2026-11-03")["cash"] == [cash_entry("ams-canal", 2_000, 2_000)]

      assert fetch_report!(conn, "2026-11-04")["cash"] == [
               cash_entry("ams-canal", 2_000, 5_000, %{"received_cents" => 3_000})
             ]
    end

    test "a durable retry returns the stored result and never reports a movement twice", %{
      conn: conn
    } do
      batch = [start_operation(), open_operation(), payment("p1", "group-81", 1_000)]

      first = run_batch(conn, batch)
      assert run_batch(conn, batch) == first

      assert fetch_report!(conn, "2026-11-02")["cash"] == [
               cash_entry("ams-canal", 0, 1_000, %{"received_cents" => 1_000})
             ]
    end

    test "equivalent batches and sequential submissions produce equivalent reports", %{conn: conn} do
      start = start_operation()
      open = open_operation()
      pay_a = payment("p1", "group-81", 2_500)
      pay_b = payment("p2", "group-81", 1_500, "2026-11-04")

      sequential_conn = build_conn()
      run_batch(sequential_conn, [start, open])
      run_batch(sequential_conn, [pay_a])
      run_batch(sequential_conn, [Map.put(pay_b, "operation_id", "p2-seq")])

      single_conn = build_conn()

      run_batch(single_conn, [
        Map.put(start, "operation_id", "op-start-single"),
        Map.put(open, "operation_id", "op-open-single"),
        Map.put(pay_a, "operation_id", "p1-one"),
        Map.put(pay_b, "operation_id", "p2-two")
      ])

      for date <- ["2026-11-01", "2026-11-02", "2026-11-04"] do
        assert fetch_report!(single_conn, date) == fetch_report!(sequential_conn, date)
      end
    end
  end

  describe "report shape and stability" do
    test "cash entries are ordered by property_id and all-zero properties are omitted", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 1_000),
        open_operation(%{
          "operation_id" => "op-open-rtm",
          "group_id" => "g-rtm",
          "property_id" => "rtm-haven"
        }),
        payment("p2", "g-rtm", 2_000),
        open_operation(%{
          "operation_id" => "op-open-bru",
          "group_id" => "g-bru",
          "property_id" => "bru-delta"
        })
      ])

      assert fetch_report!(conn, "2026-11-02")["cash"] == [
               cash_entry("ams-canal", 0, 1_000, %{"received_cents" => 1_000}),
               cash_entry("rtm-haven", 0, 2_000, %{"received_cents" => 2_000})
             ]
    end

    test "reading reports repeatedly and in any order never changes them or domain state", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 4_000, "2026-11-02")
      ])

      first = fetch_report!(conn, "2026-11-02")
      assert first == fetch_report!(conn, "2026-11-02")
      assert fetch_report!(conn, "2026-11-09")["cash"] == [cash_entry("ams-canal", 4_000, 4_000)]
      assert first == fetch_report!(conn, "2026-11-02")

      run_batch(conn, [payment("p2", "group-81", 500, "2026-11-09")])
      assert first == fetch_report!(conn, "2026-11-02")

      ledger_after = fetch_ledger(conn)
      assert fetch_report!(conn, "2026-11-02") == first
      assert fetch_ledger(conn) == ledger_after
    end

    test "report closings reconcile with the current ledger views", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000, "2026-11-02"),
        cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
        open_operation(%{
          "operation_id" => "op-open-two",
          "group_id" => "g-two",
          "property_id" => "rtm-haven",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        }),
        %{
          "operation_id" => "apply-1",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-12-01",
          "group_id" => "g-two",
          "amount_cents" => 4_000
        },
        cancel("g-two", "2026-12-02")
      ])

      report = fetch_report!(conn, "2026-12-02")
      ledger = fetch_ledger_as_of(conn, "2026-12-02")

      held_sum = Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"]))
      assert held_sum == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]

      expiry_day = Date.add(@issued_on, 367) |> Date.to_iso8601()
      expired_report = fetch_report!(conn, expiry_day)
      assert expired_report["credit"]["closing_liability_cents"] == 0
      assert fetch_ledger_as_of(conn, expiry_day)["credit_liability_cents"] == 0
    end
  end
end
