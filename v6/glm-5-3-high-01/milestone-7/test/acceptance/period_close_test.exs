defmodule GroupStay.AcceptancePeriodCloseTest do
  @moduledoc false

  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  describe "closing through a date" do
    test "a close before reporting has started is rejected" do
      conn =
        submit(build_conn(), [
          close_period_operation(%{"operation_id" => "op-close", "period_end_on" => "2026-11-10"})
        ])

      assert [
               %{
                 "operation_id" => "op-close",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ] = json_response(conn, 200)["results"]

      # Nothing was published.
      conn = daily_report(build_conn(), "2026-11-10")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "an invalid or missing period_end_on is rejected" do
      apply_operations!(build_conn(), [
        start_reporting_operation(%{"starts_on" => "2026-11-01"})
      ])

      conn =
        submit(build_conn(), [
          close_period_operation(%{"operation_id" => "op-bad", "period_end_on" => "not-a-date"}),
          close_period_operation(%{"operation_id" => "op-missing", "period_end_on" => nil})
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "invalid_period"}
             ] = json_response(conn, 200)["results"]

      conn = daily_report(build_conn(), "2026-11-10")
      assert json_response(conn, 200)["data"]["status"] == "open"
    end

    test "a period_end_on before starts_on is rejected" do
      apply_operations!(build_conn(), [
        start_reporting_operation(%{"starts_on" => "2026-11-01"})
      ])

      conn =
        submit(build_conn(), [
          close_period_operation(%{
            "operation_id" => "op-close",
            "period_end_on" => "2026-10-31"
          })
        ])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               json_response(conn, 200)["results"]
    end

    test "an applied close returns exactly operation_id, status, and period_end_on" do
      results =
        apply_operations!(build_conn(), [
          start_reporting_operation(%{"operation_id" => "op-start", "starts_on" => "2026-11-01"}),
          close_period_operation(%{"operation_id" => "op-close", "period_end_on" => "2026-11-10"})
        ])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-11-10"
             }
    end

    test "a close on starts_on itself applies" do
      results =
        apply_operations!(build_conn(), [
          start_reporting_operation(%{"starts_on" => "2026-11-01"}),
          close_period_operation(%{
            "operation_id" => "op-close",
            "period_end_on" => "2026-11-01"
          })
        ])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-11-01"
             }

      assert report_data(build_conn(), "2026-11-01")["status"] == "closed"
      assert report_data(build_conn(), "2026-11-02")["status"] == "open"
    end

    test "a close must be strictly later than the latest successful close" do
      apply_operations!(build_conn(), [
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        close_period_operation(%{"operation_id" => "op-close-1", "period_end_on" => "2026-11-10"})
      ])

      conn =
        submit(build_conn(), [
          # The same cutoff again.
          close_period_operation(%{
            "operation_id" => "op-close-2",
            "period_end_on" => "2026-11-10"
          }),
          # An earlier cutoff.
          close_period_operation(%{
            "operation_id" => "op-close-3",
            "period_end_on" => "2026-11-05"
          }),
          # A later cutoff applies.
          close_period_operation(%{
            "operation_id" => "op-close-4",
            "period_end_on" => "2026-11-20"
          }),
          # A retry of the rejected same-cutoff close replays its rejection.
          close_period_operation(%{
            "operation_id" => "op-close-2",
            "period_end_on" => "2026-11-10"
          })
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "applied", "period_end_on" => "2026-11-20"},
               %{"status" => "rejected", "code" => "invalid_period"}
             ] = json_response(conn, 200)["results"]
    end

    test "a close replays its stored result and conflicts on a different payload" do
      results =
        apply_operations!(build_conn(), [
          start_reporting_operation(%{"starts_on" => "2026-11-01"}),
          close_period_operation(%{"operation_id" => "op-close", "period_end_on" => "2026-11-10"})
        ])

      stored = Enum.at(results, 1)

      conn =
        submit(build_conn(), [
          close_period_operation(%{"operation_id" => "op-close", "period_end_on" => "2026-11-10"})
        ])

      assert json_response(conn, 200)["results"] == [stored]

      conn =
        submit(build_conn(), [
          close_period_operation(%{"operation_id" => "op-close", "period_end_on" => "2026-11-11"})
        ])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/operations/op-close")
      assert json_response(conn, 200)["data"] == stored
    end
  end

  describe "published reports" do
    test "reports through the cutoff are closed and later reports are open" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"period_end_on" => "2026-11-05"})
      ])

      assert report_data(build_conn(), "2026-11-01")["status"] == "closed"
      assert report_data(build_conn(), "2026-11-05")["status"] == "closed"
      assert report_data(build_conn(), "2026-11-06")["status"] == "open"

      conn = daily_report(build_conn(), "2026-10-31")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "a closed report stays byte-for-byte stable across later operations" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"period_end_on" => "2026-11-05"})
      ])

      published = report_data(build_conn(), "2026-11-05")

      assert cash_entry(published, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 5000
             }

      # Later operations with old and new occurred_on dates.
      apply_operations!(build_conn(), [
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 3000
        }),
        payment_operation(%{
          "operation_id" => "op-pay-3",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 1000
        })
      ])

      assert report_data(build_conn(), "2026-11-05") == published

      # The first open day carries the old-dated payment as a late
      # adjustment and the open-dated payment as an ordinary movement.
      report = report_data(build_conn(), "2026-11-06")

      assert report["status"] == "open"

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => cash_movements(%{"received_cents" => 1000}),
                 "closing_held_cents" => 9000
               }
             ]

      assert report["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => cash_movements(%{"received_cents" => 3000})
                 }
               ],
               "credit" => zero_credit_movements()
             }
    end

    test "a later close publishes more days without changing earlier ones" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"operation_id" => "op-close-1", "period_end_on" => "2026-11-05"})
      ])

      published = report_data(build_conn(), "2026-11-05")

      apply_operations!(build_conn(), [
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 3000
        }),
        close_period_operation(%{"operation_id" => "op-close-2", "period_end_on" => "2026-11-08"})
      ])

      assert report_data(build_conn(), "2026-11-05") == published

      # The late movement committed between the closes stays on its chosen
      # day, which the second close now publishes.
      report = report_data(build_conn(), "2026-11-06")

      assert report["status"] == "closed"

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => zero_cash_movements(),
                 "closing_held_cents" => 8000
               }
             ]

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 3000})
               }
             ]

      assert report_data(build_conn(), "2026-11-08")["status"] == "closed"
      assert report_data(build_conn(), "2026-11-09")["status"] == "open"
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts its complete effect on the first open day" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"period_end_on" => "2026-11-10"})
      ])

      apply_operations!(build_conn(), [
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-04",
          "amount_cents" => 3000
        })
      ])

      # The closed day of the old-dated payment is untouched.
      report = report_data(build_conn(), "2026-11-04")

      assert report["status"] == "closed"

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 5000
             }

      assert report["late_adjustments"] == %{"cash" => [], "credit" => zero_credit_movements()}

      # The complete finance effect posts on the first open day.
      report = report_data(build_conn(), "2026-11-11")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 8000
             }

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 3000})
               }
             ]

      # Current-state views keep their existing meanings.
      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 8000

      ledger = ledger_data(nil)
      assert ledger["cash_held_cents"] == 8000
    end

    test "a durable retry after a close does not report a late movement twice" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        close_period_operation(%{"period_end_on" => "2026-11-10"}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-04",
          "amount_cents" => 3000
        })
      ])

      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-pay-1",
            "occurred_on" => "2026-11-04",
            "amount_cents" => 3000
          })
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      report = report_data(build_conn(), "2026-11-11")

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 3000})
               }
             ]

      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 3000
    end

    test "an operation with occurred_on in the open period keeps that date" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"period_end_on" => "2026-11-05"}),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-07",
          "amount_cents" => 4000
        })
      ])

      report = report_data(build_conn(), "2026-11-07")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => cash_movements(%{"received_cents" => 4000}),
               "closing_held_cents" => 9000
             }

      assert report["late_adjustments"] == %{"cash" => [], "credit" => zero_credit_movements()}
    end

    test "an operation before a close in the same batch posts into the closed period" do
      conn =
        submit(build_conn(), [
          open_group_operation(%{"occurred_on" => "2026-10-20"}),
          start_reporting_operation(%{"starts_on" => "2026-11-01"}),
          payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
          close_period_operation(%{"period_end_on" => "2026-11-10"}),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "occurred_on" => "2026-11-03",
            "amount_cents" => 3000
          })
        ])

      assert Enum.count(json_response(conn, 200)["results"], &(&1["status"] == "applied")) == 5

      report = report_data(build_conn(), "2026-11-02")

      assert report["status"] == "closed"

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"received_cents" => 5000}),
               "closing_held_cents" => 5000
             }

      report = report_data(build_conn(), "2026-11-11")

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 3000})
               }
             ]
    end

    test "a later close never moves a posting date already chosen" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        close_period_operation(%{
          "operation_id" => "op-close-1",
          "period_end_on" => "2026-11-05"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"operation_id" => "op-close-2", "period_end_on" => "2026-11-20"})
      ])

      published = report_data(build_conn(), "2026-11-06")

      assert published["status"] == "closed"

      assert published["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 5000})
               }
             ]

      assert cash_entry(published, "ams-canal")["closing_held_cents"] == 5000

      # An even older-dated operation posts after the second close.
      apply_operations!(build_conn(), [
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 4000
        })
      ])

      assert report_data(build_conn(), "2026-11-06") == published

      report = report_data(build_conn(), "2026-11-21")

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 4000})
               }
             ]

      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 9000
    end
  end

  describe "late adjustments" do
    test "cash entries are ordered by property_id and all-zero properties are omitted" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west",
          "occurred_on" => "2026-10-20"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-3",
          "property_id" => "par-eiffel",
          "occurred_on" => "2026-10-20"
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-02"
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        close_period_operation(%{"period_end_on" => "2026-11-10"}),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-1",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 3000
        }),
        payment_operation(%{
          "operation_id" => "op-pay-3",
          "group_id" => "group-3",
          "occurred_on" => "2026-11-11"
        })
      ])

      report = report_data(build_conn(), "2026-11-11")

      # Only the properties with late movements appear, in property order;
      # par-eiffel moved cash that day but none of it was moved by a close.
      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"transferred_out_cents" => 3000})
               },
               %{
                 "property_id" => "lon-west",
                 "movements" => cash_movements(%{"transferred_in_cents" => 3000})
               }
             ]

      assert Enum.map(report["cash"], & &1["property_id"]) ==
               ["ams-canal", "lon-west", "par-eiffel"]

      assert cash_entry(report, "par-eiffel")["movements"] ==
               cash_movements(%{"received_cents" => 5000})

      # A day without late movements still carries the credit object.
      report = report_data(build_conn(), "2026-11-12")
      assert report["late_adjustments"] == %{"cash" => [], "credit" => zero_credit_movements()}
    end

    test "signed classifications survive even when their net effect is zero" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "occurred_on" => "2026-10-20",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 100
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-03",
          "refund_method" => "cash"
        }),
        close_period_operation(%{"period_end_on" => "2026-11-10"}),
        charge_back_operation(%{
          "operation_id" => "op-chargeback-1",
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-05"
        })
      ])

      report = report_data(build_conn(), "2026-11-11")

      # The chargeback reverses the refund published inside the closed
      # period: -100 refunded and +100 charged back, netting zero without
      # disappearing.
      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" =>
                   cash_movements(%{"refunded_cents" => -100, "charged_back_cents" => 100})
               }
             ]

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 0
             }

      ledger = ledger_data("2026-11-11")
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 100
    end

    test "ordinary and late movements of the same day add into the balances" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"period_end_on" => "2026-11-10"}),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 3000
        }),
        payment_operation(%{
          "operation_id" => "op-pay-3",
          "occurred_on" => "2026-11-11",
          "amount_cents" => 1000
        })
      ])

      report = report_data(build_conn(), "2026-11-11")

      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => cash_movements(%{"received_cents" => 1000}),
               "closing_held_cents" => 9000
             }

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 3000})
               }
             ]

      assert ledger_data("2026-11-11")["cash_held_cents"] == 9000
    end

    test "credit issued after a close posts as a late adjustment" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{"operation_id" => "op-pay-1", "occurred_on" => "2026-11-02"}),
        close_period_operation(%{"period_end_on" => "2026-11-10"}),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      ])

      report = report_data(build_conn(), "2026-11-11")

      assert report["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => cash_movements(%{"converted_to_credit_cents" => 5000})
                 }
               ],
               "credit" => %{zero_credit_movements() | "issued_cents" => 5500}
             }

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => zero_cash_movements(),
                 "closing_held_cents" => 0
               }
             ]

      assert report["credit"]["movements"] == zero_credit_movements()
      assert report["credit"]["closing_liability_cents"] == 5500

      assert ledger_data("2026-11-11")["credit_liability_cents"] == 5500
    end
  end

  describe "reconciliation" do
    test "closing balances reconcile with the ledger after late activity" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-10-20"}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "property_id" => "lon-west",
          "occurred_on" => "2026-10-20"
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 8000
        }),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 4000
        }),
        close_period_operation(%{"period_end_on" => "2026-11-10"}),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-1",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 3000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-04",
          "refund_method" => "cash"
        }),
        payment_operation(%{
          "operation_id" => "op-pay-3",
          "occurred_on" => "2026-11-12",
          "amount_cents" => 2000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-1",
          "occurred_on" => "2026-11-13",
          "refund_method" => "hotel_credit"
        })
      ])

      report = report_data(build_conn(), "2026-11-13")
      ledger = ledger_data("2026-11-13")

      held = report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()
      assert held == 0
      assert ledger["cash_held_cents"] == 0

      assert report["credit"]["closing_liability_cents"] == 7700
      assert ledger["credit_liability_cents"] == 7700

      # The late refund and transfer settled on the first open day.
      report_1111 = report_data(build_conn(), "2026-11-11")

      assert report_1111["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"transferred_out_cents" => 3000})
               },
               %{
                 "property_id" => "lon-west",
                 "movements" =>
                   cash_movements(%{
                     "transferred_in_cents" => 3000,
                     "refunded_cents" => 7000
                   })
               }
             ]

      assert cash_entry(report_1111, "lon-west")["closing_held_cents"] == 0
    end

    test "credit applied late from a lot that expired inside the closed period" do
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
        close_period_operation(%{"period_end_on" => "2026-11-10"})
      ])

      # The lot expires 2026-11-05, so the closed period publishes its
      # expiry on 2026-11-06.
      published = report_data(build_conn(), "2026-11-06")

      assert published["status"] == "closed"
      assert published["credit"]["movements"]["expired_cents"] == 2200
      assert published["credit"]["closing_liability_cents"] == 0

      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-02"
        }),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 2200
        })
      ])

      # The published expiry cannot be rewritten, but the applied credit is
      # still liability, so the late adjustment reverses the expiry.
      assert report_data(build_conn(), "2026-11-06") == published

      report = report_data(build_conn(), "2026-11-11")

      assert report["credit"]["movements"] == zero_credit_movements()

      assert report["late_adjustments"]["credit"] ==
               %{zero_credit_movements() | "expired_cents" => -2200}

      assert report["credit"]["closing_liability_cents"] == 2200
      assert ledger_data("2026-11-11")["credit_liability_cents"] == 2200
    end

    test "credit issued by an old-dated conversion after a close is already expired" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-y",
          "group_id" => "group-y",
          "occurred_on" => "2025-11-01",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        }),
        payment_operation(%{
          "operation_id" => "op-pay-y",
          "group_id" => "group-y",
          "occurred_on" => "2025-11-01",
          "amount_cents" => 2000
        }),
        start_reporting_operation(%{"starts_on" => "2026-11-01"}),
        close_period_operation(%{"period_end_on" => "2026-11-10"}),
        cancel_operation(%{
          "operation_id" => "op-cancel-y",
          "group_id" => "group-y",
          "occurred_on" => "2025-11-05",
          "refund_method" => "hotel_credit"
        })
      ])

      report = report_data(build_conn(), "2026-11-11")

      # The conversion posts on the first open day, but the lot it issues
      # expired on 2026-11-05. Both signed movements stay visible even
      # though their net effect on the liability is zero.
      assert report["late_adjustments"]["credit"] ==
               %{zero_credit_movements() | "issued_cents" => 2200, "expired_cents" => 2200}

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"converted_to_credit_cents" => 2000})
               }
             ]

      assert report["credit"]["closing_liability_cents"] == 0
      assert ledger_data("2026-11-11")["credit_liability_cents"] == 0
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
