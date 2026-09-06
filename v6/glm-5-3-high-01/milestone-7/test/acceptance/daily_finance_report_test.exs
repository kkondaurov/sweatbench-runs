defmodule GroupStay.AcceptanceDailyFinanceReportTest do
  @moduledoc false

  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  describe "starting finance reporting" do
    test "the first applied start operation enables reporting" do
      results =
        apply_operations!(build_conn(), [
          start_reporting_operation(%{"operation_id" => "op-start"})
        ])

      # The applied result contains exactly these fields.
      assert results == [
               %{
                 "operation_id" => "op-start",
                 "status" => "applied",
                 "starts_on" => "2026-11-01"
               }
             ]

      conn = daily_report(build_conn(), "2026-11-01")

      assert json_response(conn, 200)["data"] == %{
               "date" => "2026-11-01",
               "status" => "open",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{"cash" => [], "credit" => zero_credit_movements()}
             }
    end

    test "an invalid or missing starts_on is rejected" do
      conn =
        submit(build_conn(), [
          start_reporting_operation(%{"operation_id" => "op-bad", "starts_on" => "not-a-date"}),
          start_reporting_operation(%{"operation_id" => "op-missing", "starts_on" => nil})
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_reporting_date"},
               %{"status" => "rejected", "code" => "invalid_reporting_date"}
             ] = json_response(conn, 200)["results"]

      conn = daily_report(build_conn(), "2026-11-01")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "a different start operation is rejected once reporting has started" do
      apply_operations!(build_conn(), [
        start_reporting_operation(%{"operation_id" => "op-start", "starts_on" => "2026-11-01"})
      ])

      conn =
        submit(build_conn(), [
          start_reporting_operation(%{
            "operation_id" => "op-start-2",
            "starts_on" => "2026-11-15"
          })
        ])

      assert [
               %{
                 "operation_id" => "op-start-2",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ] = json_response(conn, 200)["results"]

      # The original start date still governs the report.
      conn = daily_report(build_conn(), "2026-10-31")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      conn = daily_report(build_conn(), "2026-11-14")
      assert json_response(conn, 200)["data"]["date"] == "2026-11-14"
    end

    test "a second start operation in the same batch is also rejected" do
      conn =
        submit(build_conn(), [
          start_reporting_operation(%{"operation_id" => "op-start", "starts_on" => "2026-11-01"}),
          start_reporting_operation(%{
            "operation_id" => "op-start-2",
            "starts_on" => "2026-11-02"
          })
        ])

      assert [
               %{"status" => "applied", "starts_on" => "2026-11-01"},
               %{"status" => "rejected", "code" => "reporting_already_started"}
             ] = json_response(conn, 200)["results"]

      conn = daily_report(build_conn(), "2026-11-01")
      assert json_response(conn, 200)["data"]["date"] == "2026-11-01"
    end

    test "a retry of the original start replays its stored result" do
      results =
        apply_operations!(build_conn(), [
          start_reporting_operation(%{"operation_id" => "op-start", "starts_on" => "2026-11-01"})
        ])

      conn =
        submit(build_conn(), [
          start_reporting_operation(%{"operation_id" => "op-start", "starts_on" => "2026-11-01"})
        ])

      assert json_response(conn, 200)["results"] == results

      conn =
        submit(build_conn(), [
          start_reporting_operation(%{"operation_id" => "op-start", "starts_on" => "2026-11-02"})
        ])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               json_response(conn, 200)["results"]

      conn = daily_report(build_conn(), "2026-11-01")
      assert json_response(conn, 200)["data"]["date"] == "2026-11-01"
    end
  end

  describe "reading one day" do
    test "date validation and availability" do
      conn = daily_report(build_conn(), "2026-11-01")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      conn = get(build_conn(), "/api/v1/finance/daily-report")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = daily_report(build_conn(), "November 1")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      apply_operations!(build_conn(), [
        start_reporting_operation(%{"starts_on" => "2026-11-01"})
      ])

      conn = daily_report(build_conn(), "2026-10-31")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      conn = daily_report(build_conn(), "2026-11-01")
      assert json_response(conn, 200)["data"]["date"] == "2026-11-01"
    end

    test "the opening position is the state when reporting started" do
      # Every operation before the start contributes to the opening position,
      # including one whose occurred_on is after starts_on.
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-05"
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"})
      ])

      report = report_data(build_conn(), "2026-11-01")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 8000,
                 "movements" => zero_cash_movements(),
                 "closing_held_cents" => 8000
               }
             ]

      # The payment dated after starts_on never posts a movement.
      report = report_data(build_conn(), "2026-11-05")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"] == zero_cash_movements()
      assert entry["opening_held_cents"] == 8000
      assert entry["closing_held_cents"] == 8000
    end

    test "a batch splits at the start operation" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 2000})
      ])

      apply_operations!(build_conn(), [
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 3000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-3", "amount_cents" => 3000})
      ])

      report = report_data(build_conn(), "2026-11-01")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => cash_movements(%{"received_cents" => 3000}),
               "closing_held_cents" => 8000
             }

      # Reading repeatedly never changes the report.
      assert report_data(build_conn(), "2026-11-01") == report
    end

    test "a property with no balance and no movement is omitted" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"})
      ])

      report = report_data(build_conn(), "2026-11-01")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal"]
    end
  end

  describe "cash movements" do
    test "a full report across properties with transfers and settlements" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west",
          "occurred_on" => "2026-10-20"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 8000}),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-2",
          "amount_cents" => 4000
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-1",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-02"
        })
      ])

      report = report_data(build_conn(), "2026-11-02")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 8000,
                 "movements" => cash_movements(%{"transferred_out_cents" => 3000}),
                 "closing_held_cents" => 5000
               },
               %{
                 "property_id" => "lon-west",
                 "opening_held_cents" => 4000,
                 "movements" => cash_movements(%{"transferred_in_cents" => 3000}),
                 "closing_held_cents" => 7000
               }
             ]

      # Transferred-in equals transferred-out across all properties.
      totals =
        report["cash"]
        |> Enum.map(& &1["movements"])
        |> Enum.reduce(0, fn movements, total ->
          total + movements["transferred_in_cents"] - movements["transferred_out_cents"]
        end)

      assert totals == 0

      # The opening balance of the next day is the closing balance above.
      apply_operations!(build_conn(), [
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-10",
          "refund_method" => "cash"
        })
      ])

      report = report_data(build_conn(), "2026-11-10")

      assert cash_entry(report, "lon-west") == %{
               "property_id" => "lon-west",
               "opening_held_cents" => 7000,
               "movements" => cash_movements(%{"refunded_cents" => 7000}),
               "closing_held_cents" => 0
             }

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 5000
             }

      # The report reconciles to the current ledger view.
      ledger = ledger_data("2026-11-10")
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 5000
      assert ledger["cash_held_cents"] == 5000
      assert ledger["cash_refunded_cents"] == 7000
    end

    test "retention reports on a non-refundable settlement" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "rate_plan" => "advance_purchase",
          "occurred_on" => "2026-10-20"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 6000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        cancel_operation(%{"operation_id" => "op-cancel-1", "occurred_on" => "2026-11-10"})
      ])

      report = report_data(build_conn(), "2026-11-10")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 6000,
               "movements" => cash_movements(%{"retained_cents" => 6000}),
               "closing_held_cents" => 0
             }
    end

    test "settling selected rooms reports only their funding" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "occurred_on" => "2026-10-20",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        cancel_rooms_operation(%{
          "operation_id" => "op-cancel-rooms-1",
          "occurred_on" => "2026-11-10",
          "room_ids" => ["room-a"]
        })
      ])

      report = report_data(build_conn(), "2026-11-10")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 9000,
               "movements" => cash_movements(%{"refunded_cents" => 9000}),
               "closing_held_cents" => 0
             }
    end

    test "a reduction follows held cash to its property" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west",
          "occurred_on" => "2026-10-20"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-1",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-02"
        })
      ])

      # The transferred cash is held at lon-west, so the reduction reports
      # there and not at the payment's original property.
      apply_operations!(build_conn(), [
        reduce_cash_operation(%{
          "operation_id" => "op-reduce-1",
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-04",
          "amount_cents" => 2000
        })
      ])

      report = report_data(build_conn(), "2026-11-04")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 2000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 2000
             }

      assert cash_entry(report, "lon-west") == %{
               "property_id" => "lon-west",
               "opening_held_cents" => 3000,
               "movements" => cash_movements(%{"reduced_cents" => 2000}),
               "closing_held_cents" => 1000
             }

      assert ledger_data(nil)["cash_reduced_cents"] == 2000
    end

    test "a chargeback reverses a refund where it was settled" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west",
          "occurred_on" => "2026-10-20"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 4000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-1",
          "amount_cents" => 4000,
          "occurred_on" => "2026-11-02"
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-10",
          "refund_method" => "cash"
        })
      ])

      report = report_data(build_conn(), "2026-11-10")

      assert cash_entry(report, "lon-west")["movements"] ==
               cash_movements(%{"refunded_cents" => 4000})

      apply_operations!(build_conn(), [
        charge_back_operation(%{
          "operation_id" => "op-chargeback-1",
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-12"
        })
      ])

      # Reversing the earlier refund reports negative refunded cents
      # together with positive charged-back cents, at the property where the
      # cash was settled rather than the payment's original property.
      report = report_data(build_conn(), "2026-11-12")

      assert cash_entry(report, "lon-west") == %{
               "property_id" => "lon-west",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{"refunded_cents" => -4000, "charged_back_cents" => 4000}),
               "closing_held_cents" => 0
             }

      # ams-canal is omitted: nothing is held or moved there on that date.
      assert cash_entry(report, "ams-canal") == nil

      ledger = ledger_data("2026-11-12")
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 4000
    end

    test "a chargeback reports held cash at the properties where it is held" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west",
          "occurred_on" => "2026-10-20"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-1",
          "amount_cents" => 4000,
          "occurred_on" => "2026-11-02"
        }),
        charge_back_operation(%{
          "operation_id" => "op-chargeback-1",
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-04"
        })
      ])

      report = report_data(build_conn(), "2026-11-04")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => cash_movements(%{"charged_back_cents" => 5000}),
               "closing_held_cents" => 0
             }

      assert cash_entry(report, "lon-west") == %{
               "property_id" => "lon-west",
               "opening_held_cents" => 4000,
               "movements" => cash_movements(%{"charged_back_cents" => 4000}),
               "closing_held_cents" => 0
             }
    end
  end

  describe "credit movements" do
    test "conversion issues credit at the bonus value" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 2000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        })
      ])

      report = report_data(build_conn(), "2026-11-10")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 2000,
               "movements" => cash_movements(%{"converted_to_credit_cents" => 2000}),
               "closing_held_cents" => 0
             }

      assert report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{
                 "issued_cents" => 2200,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 2200
             }

      assert ledger_data("2026-11-10")["credit_liability_cents"] == 2200
    end

    test "applying and restoring credit has no movement column" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 2000}),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-21"
        }),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-22",
          "amount_cents" => 2200
        })
      ])

      report = report_data(build_conn(), "2026-11-22")

      assert report["credit"]["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      # The lot was issued before reporting started, so it is part of the
      # opening liability; applying it changes no balance.
      assert report["credit"]["opening_liability_cents"] == 2200
      assert report["credit"]["closing_liability_cents"] == 2200

      apply_operations!(build_conn(), [
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-25",
          "refund_method" => "cash"
        })
      ])

      report = report_data(build_conn(), "2026-11-25")

      assert report["credit"]["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert report["credit"]["closing_liability_cents"] == 2200
    end

    test "non-refundable settlement of applied credit consumes it" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 2000}),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "rate_plan" => "advance_purchase",
          "occurred_on" => "2026-11-21"
        }),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-22",
          "amount_cents" => 2200
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-25"
        })
      ])

      report = report_data(build_conn(), "2026-11-25")

      assert report["credit"] == %{
               "opening_liability_cents" => 2200,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 2200,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }

      assert ledger_data("2026-11-25")["credit_liability_cents"] == 0
    end

    test "unused credit expires the day after its expiry date, with no operation that day" do
      # A refundable cancellation on 2025-11-05 issues a lot expiring
      # 2026-11-05, before reporting starts on 2026-11-01... after it.
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-11-01",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        }),
        payment_operation(%{
          "operation_id" => "op-pay-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-11-01",
          "amount_cents" => 2000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-11-05",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"})
      ])

      # The lot is unexpired on 2026-11-05, so it is still liability.
      report = report_data(build_conn(), "2026-11-05")
      assert report["credit"]["closing_liability_cents"] == 2200
      assert report["credit"]["movements"]["expired_cents"] == 0

      # No operation is submitted on 2026-11-06; the credit still expires.
      report = report_data(build_conn(), "2026-11-06")

      assert report["credit"] == %{
               "opening_liability_cents" => 2200,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 2200,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }

      # Later reports carry the expiry forward as their opening balance.
      report = report_data(build_conn(), "2026-12-01")
      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 0

      assert ledger_data("2026-12-01")["credit_liability_cents"] == 0
    end

    test "credit that expired between starts_on and today still reports its expiry" do
      # The lot is issued on 2025-05-10 and expires on 2026-05-10; reporting
      # starts on 2026-01-01, submitted today.
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-05-01",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        }),
        payment_operation(%{
          "operation_id" => "op-pay-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-05-01",
          "amount_cents" => 2000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-05-10",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation(%{"starts_on" => "2026-01-01"})
      ])

      # The lot is unexpired on 2026-05-10 and part of the liability.
      assert report_data(build_conn(), "2026-05-10")["credit"]["closing_liability_cents"] == 2200

      # It expires the following day, and later reports carry that forward.
      report = report_data(build_conn(), "2026-05-11")

      assert report["credit"]["opening_liability_cents"] == 2200
      assert report["credit"]["movements"]["expired_cents"] == 2200
      assert report["credit"]["closing_liability_cents"] == 0

      today = Date.utc_today() |> Date.to_iso8601()
      assert report_data(build_conn(), today)["credit"]["opening_liability_cents"] == 0
      assert ledger_data(nil)["credit_liability_cents"] == 0
    end

    test "credit restored to an already expired lot expires immediately" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-11-01",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        }),
        payment_operation(%{
          "operation_id" => "op-pay-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-11-01",
          "amount_cents" => 2000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-x",
          "group_id" => "group-x",
          "occurred_on" => "2025-11-05",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-02"
        }),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 2200
        }),
        # The cancellation happens after the lot's 2026-11-05 expiry.
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-10",
          "refund_method" => "cash"
        })
      ])

      report = report_data(build_conn(), "2026-11-10")

      # The lot is fully applied on its expiry date, so nothing expires
      # naturally on 2026-11-06; the restored amount expires on the
      # settlement's posting date instead.
      report_1106 = report_data(build_conn(), "2026-11-06")
      assert report_1106["credit"]["movements"]["expired_cents"] == 0
      assert report_1106["credit"]["closing_liability_cents"] == 2200

      assert report["credit"] == %{
               "opening_liability_cents" => 2200,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 2200,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }

      assert ledger_data("2026-11-10")["credit_liability_cents"] == 0
    end

    test "a chargeback revokes unspent entitlement" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 2000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        }),
        charge_back_operation(%{
          "operation_id" => "op-chargeback-1",
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-12"
        })
      ])

      report = report_data(build_conn(), "2026-11-12")

      assert report["credit"] == %{
               "opening_liability_cents" => 2200,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 2200,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }

      assert ledger_data("2026-11-12")["credit_liability_cents"] == 0
    end

    test "a shortfall absorbs restored credit" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-1",
          "occurred_on" => "2026-10-20",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 3000}),
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 3000}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        # One settlement converts 6000 into a single 6600-cent lot with
        # entitlements of 3300 for each payment.
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-02",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-03"
        }),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 4400
        }),
        # Charging back op-pay-2 claws back 3300 from a lot holding 2200,
        # leaving an unrecovered shortfall of 1100.
        charge_back_operation(%{
          "operation_id" => "op-chargeback-2",
          "payment_operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-04"
        }),
        # A refundable settlement restores 4400, of which 1100 absorbs the
        # shortfall and only 3300 becomes available again.
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-05",
          "refund_method" => "cash"
        })
      ])

      report_1104 = report_data(build_conn(), "2026-11-04")
      assert report_1104["credit"]["movements"]["revoked_cents"] == 2200
      assert report_1104["credit"]["closing_liability_cents"] == 4400

      report = report_data(build_conn(), "2026-11-05")

      assert report["credit"] == %{
               "opening_liability_cents" => 4400,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 1100
               },
               "closing_liability_cents" => 3300
             }

      assert ledger_data("2026-11-05")["credit_liability_cents"] == 3300
      assert ledger_data("2026-11-05")["credit_shortfall_cents"] == 0
    end
  end

  describe "posting dates" do
    test "an operation posts on the later of occurred_on and starts_on" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-10-25"
        })
      ])

      report = report_data(build_conn(), "2026-11-01")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"received_cents" => 5000}),
               "closing_held_cents" => 5000
             }
    end

    test "a later submission changes an earlier open report" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-03"
        })
      ])

      report = report_data(build_conn(), "2026-11-03")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 5000

      apply_operations!(build_conn(), [
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        })
      ])

      report = report_data(build_conn(), "2026-11-03")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 7000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 7000
    end

    test "a durable retry does not report a movement twice" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-03"
        })
      ])

      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-pay-1",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-03"
          })
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      report = report_data(build_conn(), "2026-11-03")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 5000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 5000
    end

    test "rejected operations leave no movement and later batch results survive" do
      conn =
        submit(build_conn(), [
          open_group_operation(%{"occurred_on" => "2026-10-20"}),
          start_reporting_operation(%{"starts_on" => "2026-11-01"}),
          payment_operation(%{
            "operation_id" => "op-pay-1",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-03"
          }),
          reduce_cash_operation(%{
            "operation_id" => "op-reduce-1",
            "payment_operation_id" => "op-pay-1",
            "amount_cents" => 9000
          }),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "amount_cents" => 3000,
            "occurred_on" => "2026-11-03"
          })
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.at(results, 3)["status"] == "rejected"
      assert Enum.count(results, &(&1["status"] == "applied")) == 4

      report = report_data(build_conn(), "2026-11-03")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"received_cents" => 8000}),
               "closing_held_cents" => 8000
             }
    end
  end

  describe "reconciliation" do
    test "closing balances reconcile with the ledger after mixed activity" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west",
          "occurred_on" => "2026-10-20"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 8000}),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-2",
          "amount_cents" => 4000
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-1",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-02"
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-3",
          "occurred_on" => "2026-11-11"
        }),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "group_id" => "group-3",
          "occurred_on" => "2026-11-11",
          "amount_cents" => 6600
        }),
        # op-pay-2 still holds cash at lon-west, so the reduction reports
        # where that cash is held.
        reduce_cash_operation(%{
          "operation_id" => "op-reduce-1",
          "payment_operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-11",
          "amount_cents" => 500
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-12",
          "refund_method" => "cash"
        }),
        payment_operation(%{
          "operation_id" => "op-pay-3",
          "group_id" => "group-3",
          "occurred_on" => "2026-11-12",
          "amount_cents" => 2000
        })
      ])

      report = report_data(build_conn(), "2026-11-12")
      ledger = ledger_data("2026-11-12")

      held =
        report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

      assert held == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]

      # The reduction posts on its own date and follows the held cash to
      # lon-west rather than op-pay-2's own property.
      assert cash_entry(report_data(build_conn(), "2026-11-11"), "lon-west")["movements"][
               "reduced_cents"
             ] == 500

      assert ledger["cash_reduced_cents"] == 500
      assert ledger["cash_refunded_cents"] == 5500

      assert cash_entry(report_data(build_conn(), "2026-11-10"), "ams-canal")["movements"][
               "converted_to_credit_cents"
             ] == 6000

      assert report_data(build_conn(), "2026-11-10")["credit"]["movements"]["issued_cents"] ==
               6600
    end
  end

  describe "equivalence" do
    test "a single batch and sequential submissions produce the same reports" do
      sequential_conn = fn ->
        apply_operations!(build_conn(), [
          open_group_operation(%{"occurred_on" => "2026-10-20"}),
          open_group_operation(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-2",
            "property_id" => "lon-west",
            "occurred_on" => "2026-10-20"
          }),
          payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 8000}),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "group_id" => "group-2",
            "amount_cents" => 4000
          })
        ])

        apply_operations!(build_conn(), [
          start_reporting_operation(%{"starts_on" => "2026-11-01"})
        ])

        apply_operations!(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-1",
            "amount_cents" => 2000,
            "occurred_on" => "2026-11-02"
          })
        ])

        apply_operations!(build_conn(), [
          cancel_operation(%{
            "operation_id" => "op-cancel-1",
            "occurred_on" => "2026-11-10",
            "refund_method" => "hotel_credit"
          })
        ])

        report_data(build_conn(), "2026-11-10")
      end

      batched_conn = fn ->
        apply_operations!(build_conn(), [
          open_group_operation(%{"occurred_on" => "2026-10-20"}),
          open_group_operation(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-2",
            "property_id" => "lon-west",
            "occurred_on" => "2026-10-20"
          }),
          payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 8000}),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "group_id" => "group-2",
            "amount_cents" => 4000
          }),
          start_reporting_operation(%{"starts_on" => "2026-11-01"}),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-1",
            "amount_cents" => 2000,
            "occurred_on" => "2026-11-02"
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-1",
            "occurred_on" => "2026-11-10",
            "refund_method" => "hotel_credit"
          })
        ])

        report_data(build_conn(), "2026-11-10")
      end

      assert sequential_conn.() == batched_conn.()
    end

    test "reading reports in any order never changes them" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-03"
        })
      ])

      # Read the later date first, then the earlier one, then repeat.
      late = report_data(build_conn(), "2026-11-03")
      early = report_data(build_conn(), "2026-11-01")

      assert report_data(build_conn(), "2026-11-01") == early
      assert report_data(build_conn(), "2026-11-03") == late

      # Reading reports leaves domain state untouched.
      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 5000

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 5000
    end
  end

  ## Helpers

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

  defp cash_movements(overrides) do
    Map.merge(zero_cash_movements(), overrides)
  end

  defp ledger_data(on) do
    conn =
      if on do
        get(build_conn(), "/api/v1/ledger?on=" <> on)
      else
        get(build_conn(), "/api/v1/ledger")
      end

    json_response(conn, 200)["data"]
  end
end
