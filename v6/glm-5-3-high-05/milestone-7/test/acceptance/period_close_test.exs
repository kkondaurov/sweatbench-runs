defmodule GroupStayWeb.Acceptance.PeriodCloseTest do
  @moduledoc """
  Acceptance tests for the finance period close: the `close_finance_period`
  operation and its `invalid_period` rules, published (closed) daily reports
  and their byte-for-byte stability, the posting dates of operations
  processed after a close, and the late-adjustment reporting of movements a
  close moved forward.
  """

  use GroupStayWeb.ConnCase, async: true

  @zero_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @zero_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  describe "closing through a date" do
    test "the applied result contains exactly operation_id, status, and period_end_on" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      result =
        apply_one!(
          build_conn(),
          close_period_operation(%{
            "operation_id" => "op-close-1",
            "period_end_on" => "2026-11-05"
          })
        )

      assert result == %{
               "operation_id" => "op-close-1",
               "status" => "applied",
               "period_end_on" => "2026-11-05"
             }
    end

    test "a close before reporting has started is rejected with invalid_period" do
      result =
        apply_one!(build_conn(), close_period_operation(%{"period_end_on" => "2026-11-05"}))

      assert %{"status" => "rejected", "code" => "invalid_period"} = result

      # Nothing was closed: reports are still unavailable.
      conn = get_daily_report(build_conn(), "2026-11-05")

      assert %{status: 404} = conn
      assert %{"error" => %{"code" => "report_not_available"}} == json_response(conn, 404)
    end

    test "a period_end_on before starts_on is rejected with invalid_period" do
      start_reporting!(%{"starts_on" => "2026-11-05"})

      result =
        apply_one!(build_conn(), close_period_operation(%{"period_end_on" => "2026-11-04"}))

      assert %{"status" => "rejected", "code" => "invalid_period"} = result

      # An equal period_end_on is on or after starts_on and applies.
      assert %{"status" => "applied", "period_end_on" => "2026-11-05"} =
               apply_one!(
                 build_conn(),
                 close_period_operation(%{"period_end_on" => "2026-11-05"})
               )
    end

    test "a close not strictly later than the latest close is rejected with invalid_period" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      close_period!(%{"period_end_on" => "2026-11-05"})

      for period_end_on <- ["2026-11-05", "2026-11-04", "2026-11-01"] do
        result =
          apply_one!(
            build_conn(),
            close_period_operation(%{"period_end_on" => period_end_on})
          )

        assert %{"status" => "rejected", "code" => "invalid_period"} = result
      end

      # A strictly later close still applies.
      assert %{"status" => "applied", "period_end_on" => "2026-11-06"} =
               apply_one!(
                 build_conn(),
                 close_period_operation(%{"period_end_on" => "2026-11-06"})
               )
    end

    test "an invalid or missing period_end_on is rejected with invalid_period" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      for attrs <- [
            %{"period_end_on" => "not-a-date"},
            %{"period_end_on" => "2026-13-01"},
            %{"period_end_on" => 42},
            %{"period_end_on" => nil}
          ] do
        result = apply_one!(build_conn(), close_period_operation(attrs))

        assert %{"status" => "rejected", "code" => "invalid_period"} = result
      end

      result =
        apply_one!(build_conn(), Map.delete(close_period_operation(), "period_end_on"))

      assert %{"status" => "rejected", "code" => "invalid_period"} = result
    end

    test "a retry of an applied close replays its stored result" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      operation =
        close_period_operation(%{
          "operation_id" => "op-close-1",
          "period_end_on" => "2026-11-05"
        })

      original = apply_one!(build_conn(), operation)
      assert %{"status" => "applied"} = original

      assert apply_one!(build_conn(), operation) == original
    end

    test "a rejected close is durably rejected on retry" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      operation =
        close_period_operation(%{"operation_id" => "op-close-bad", "period_end_on" => "nope"})

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               apply_one!(build_conn(), operation)

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               apply_one!(build_conn(), operation)
    end

    test "a different payload under the same operation_id conflicts" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      apply_one!(
        build_conn(),
        close_period_operation(%{
          "operation_id" => "op-close-1",
          "period_end_on" => "2026-11-05"
        })
      )

      result =
        apply_one!(
          build_conn(),
          close_period_operation(%{
            "operation_id" => "op-close-1",
            "period_end_on" => "2026-11-06"
          })
        )

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = result
    end

    test "the stored close result is served by the operations endpoint" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      apply_one!(
        build_conn(),
        close_period_operation(%{
          "operation_id" => "op-close-1",
          "period_end_on" => "2026-11-05"
        })
      )

      conn = Phoenix.ConnTest.get(build_conn(), "/api/v1/operations/op-close-1")

      assert %{status: 200} = conn

      assert json_response(conn, 200)["data"] == %{
               "operation_id" => "op-close-1",
               "status" => "applied",
               "period_end_on" => "2026-11-05"
             }
    end

    test "a close ignores group addressing: no group exists and none is required" do
      start_reporting!(%{"starts_on" => "2026-11-01"})

      result =
        apply_one!(
          build_conn(),
          close_period_operation(%{
            "period_end_on" => "2026-11-05",
            "group_id" => "group-none"
          })
        )

      assert %{"status" => "applied", "period_end_on" => "2026-11-05"} = result
    end
  end

  describe "published reports" do
    setup do
      start_reporting!(%{"starts_on" => "2026-11-01"})
      open_group!(build_conn(), %{"group_id" => "group-81"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      :ok
    end

    test "reports through period_end_on are closed and later reports are open" do
      close_period!(%{"period_end_on" => "2026-11-05"})

      assert %{"status" => "closed"} = daily_report("2026-11-01")
      assert %{"status" => "closed"} = daily_report("2026-11-05")
      assert %{"status" => "open"} = daily_report("2026-11-06")
    end

    test "closed reports are byte-for-byte stable across later operations and later closes" do
      close_period!(%{"period_end_on" => "2026-11-05"})

      conn = get_daily_report(build_conn(), "2026-11-02")
      assert %{status: 200} = conn
      published = conn.resp_body

      # A later old-dated operation converts the held cash into hotel
      # credit: its complete finance effect posts after the cutoff.
      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      conn = get_daily_report(build_conn(), "2026-11-02")
      assert %{status: 200} = conn
      assert conn.resp_body == published

      close_period!(%{"period_end_on" => "2026-11-08"})

      conn = get_daily_report(build_conn(), "2026-11-02")
      assert %{status: 200} = conn
      assert conn.resp_body == published
    end

    test "a later close publishes the days up to its own cutoff only" do
      close_period!(%{"period_end_on" => "2026-11-05"})
      close_period!(%{"period_end_on" => "2026-11-08"})

      assert %{"status" => "closed"} = daily_report("2026-11-08")
      assert %{"status" => "open"} = daily_report("2026-11-09")
    end

    test "a rejected close publishes nothing" do
      apply_one!(
        build_conn(),
        close_period_operation(%{"period_end_on" => "2026-10-31"})
      )

      assert %{"status" => "open"} = daily_report("2026-11-02")
    end

    test "a natural credit expiry inside the closed period stays frozen" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      # The lot is issued on 2026-11-03 and expires on 2027-11-03, so its
      # natural expiry movement falls on 2027-11-04.
      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      # Closing through the expiry freezes the expiry movement in the
      # published report.
      close_period!(%{"period_end_on" => "2027-11-05"})

      frozen = daily_report("2027-11-04")

      assert %{
               "movements" => %{"expired_cents" => 11_000},
               "closing_liability_cents" => 0
             } = frozen["credit"]

      # A later operation consumes the same lot before its expiry. Without
      # the published snapshot, the live derivation of the closed day would
      # now drop the expiry; it must not change.
      open_group!(
        build_conn(),
        %{
          "group_id" => "group-adv",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-12-10",
          "departure_on" => "2027-12-11",
          "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 12_000}]
        }
      )

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{
          "group_id" => "group-adv",
          "amount_cents" => 11_000,
          "occurred_on" => "2027-11-01"
        })
      )

      assert daily_report("2027-11-04") == frozen

      # The open report carries the applied credit as live liability.
      report = daily_report("2027-11-06")

      assert %{
               "opening_liability_cents" => 11_000,
               "movements" => @zero_credit_movements,
               "closing_liability_cents" => 11_000
             } = report["credit"]

      assert %{"credit_liability_cents" => 11_000} = ledger()
    end
  end

  describe "posting after a close" do
    setup do
      start_reporting!(%{"starts_on" => "2026-11-01"})
      open_group!(build_conn(), %{"group_id" => "group-81"})
      close_period!(%{"period_end_on" => "2026-11-05"})

      :ok
    end

    test "an operation whose occurred_on is in the open period keeps that date" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-07"
        })
      )

      report = daily_report("2026-11-07")

      assert %{"received_cents" => 5000} = cash_movements(report)
      assert report["late_adjustments"]["cash"] == []
      assert report["late_adjustments"]["credit"] == @zero_credit_movements
    end

    test "an old-dated operation posts its complete effect on the first open day" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-03"
        })
      )

      # The closed day is untouched by the later payment.
      assert daily_report("2026-11-03")["cash"] == []

      report = daily_report("2026-11-06")

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => Map.put(@zero_cash_movements, "received_cents", 5000)
               }
             ]

      assert cash_movements(report) == @zero_cash_movements

      assert %{
               "opening_held_cents" => 0,
               "closing_held_cents" => 5000
             } = cash_entry(report)
    end

    test "an operation occurred before starts_on posts on the first open day after a close" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-10-15"
        })
      )

      report = daily_report("2026-11-06")

      assert [%{"movements" => %{"received_cents" => 5000}}] =
               report["late_adjustments"]["cash"]
    end

    test "an operation before a later close can post into the period that close publishes" do
      # The setup already closed through 2026-11-05.
      conn =
        post_batch(build_conn(), [
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-03"
          }),
          close_period_operation(%{"period_end_on" => "2026-11-08"})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"}
               ]
             } = json_response(conn, 200)

      # The payment runs before the second close commits, so it may post on
      # the first open day of the already-closed period (2026-11-06); the
      # second close then publishes that day with the movement in place.
      report = daily_report("2026-11-06")

      assert report["status"] == "closed"

      assert [%{"movements" => %{"received_cents" => 5000}}] =
               report["late_adjustments"]["cash"]

      assert %{"movements" => @zero_cash_movements, "closing_held_cents" => 5000} =
               cash_entry(report)
    end

    test "a committed posting date is not moved by a later close" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      assert [%{"movements" => %{"received_cents" => 5000}}] =
               daily_report("2026-11-06")["late_adjustments"]["cash"]

      close_period!(%{"period_end_on" => "2026-11-08"})

      report = daily_report("2026-11-06")

      assert report["status"] == "closed"

      assert [%{"movements" => %{"received_cents" => 5000}}] =
               report["late_adjustments"]["cash"]

      assert daily_report("2026-11-09")["late_adjustments"]["cash"] == []
    end

    test "a rejected operation after a close leaves no movement" do
      conn =
        post_batch(build_conn(), [
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-03"
          }),
          transfer_deposit_operation(%{
            "source_group_id" => "group-81",
            "destination_group_id" => "group-none",
            "amount_cents" => 1000,
            "occurred_on" => "2026-11-03"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "rejected"}
               ]
             } = json_response(conn, 200)

      assert [%{"movements" => %{"received_cents" => 5000}}] =
               daily_report("2026-11-06")["late_adjustments"]["cash"]
    end

    test "a durable retry after a close does not report a movement twice" do
      operation =
        record_cash_operation(%{
          "operation_id" => "op-pay-late",
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-03"
        })

      apply_one!(build_conn(), operation)
      apply_one!(build_conn(), operation)

      report = daily_report("2026-11-06")

      assert [%{"movements" => %{"received_cents" => 5000}}] =
               report["late_adjustments"]["cash"]

      assert %{"closing_held_cents" => 5000} = cash_entry(report)
      assert %{"cash_held_cents" => 5000} = ledger()
    end
  end

  describe "batch ordering around a close" do
    setup do
      start_reporting!(%{"starts_on" => "2026-11-01"})
      open_group!(build_conn(), %{"group_id" => "group-81"})

      :ok
    end

    test "an operation before the close posts into the period being closed" do
      conn =
        post_batch(build_conn(), [
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-03"
          }),
          close_period_operation(%{"period_end_on" => "2026-11-08"}),
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 3000,
            "occurred_on" => "2026-11-02"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied"}
               ]
             } = json_response(conn, 200)

      # The payment before the close commits with no cutoff in place, so it
      # posts ordinarily on its own date inside the period being closed.
      report = daily_report("2026-11-03")

      assert report["status"] == "closed"
      assert %{"movements" => %{"received_cents" => 5000}} = cash_entry(report)
      assert report["late_adjustments"]["cash"] == []

      # The old-dated payment after the close posts on the first open day.
      report = daily_report("2026-11-09")

      assert [%{"movements" => %{"received_cents" => 3000}}] =
               report["late_adjustments"]["cash"]

      assert %{"closing_held_cents" => 8000} = cash_entry(report)
    end

    test "a rejected close between two payments does not move either posting date" do
      conn =
        post_batch(build_conn(), [
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-03"
          }),
          close_period_operation(%{"period_end_on" => "2026-10-31"}),
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 3000,
            "occurred_on" => "2026-11-02"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "rejected"},
                 %{"status" => "applied"}
               ]
             } = json_response(conn, 200)

      # No close committed, so both payments post on their natural dates.
      assert %{"received_cents" => 5000} = cash_movements("2026-11-03")
      assert %{"received_cents" => 3000} = cash_movements("2026-11-02")
    end
  end

  describe "late adjustments" do
    setup do
      start_reporting!(%{"starts_on" => "2026-11-01"})
      open_group!(build_conn(), %{"group_id" => "group-81"})

      :ok
    end

    test "a day without moved movements has an empty cash array and a zero credit object" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      report = daily_report("2026-11-02")

      assert report["late_adjustments"] == %{
               "cash" => [],
               "credit" => @zero_credit_movements
             }
    end

    test "charging back a previously refunded payment reports the signed reclassification" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 100,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-81", "occurred_on" => "2026-11-03"})
      )

      assert %{"refunded_cents" => 100} = cash_movements("2026-11-03")

      close_period!(%{"period_end_on" => "2026-11-05"})

      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-04"
        })
      )

      report = daily_report("2026-11-06")

      # The chargeback reverses the refund and reclassifies it as charged
      # back. Both movements keep their signed classifications even though
      # their net balance effect is zero.
      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   "received_cents" => 0,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => -100,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 100
                 }
               }
             ]

      assert report["late_adjustments"]["credit"] == @zero_credit_movements

      # The ordinary movements and balances are all zero, so the property is
      # omitted from the ordinary cash array entirely.
      assert report["cash"] == []
      assert report["credit"]["movements"] == @zero_credit_movements
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "the day's total is the ordinary movement plus the late adjustment" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      close_period!(%{"period_end_on" => "2026-11-04"})

      # An old-dated payment posts late, an open-period payment ordinarily,
      # on the same first open day.
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-03"
        })
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-05"
        })
      )

      report = daily_report("2026-11-05")

      entry = cash_entry(report)

      assert entry["movements"]["received_cents"] == 2000

      assert [%{"movements" => %{"received_cents" => 3000}}] =
               report["late_adjustments"]["cash"]

      assert entry["opening_held_cents"] == 5000
      assert entry["closing_held_cents"] == 10_000

      assert %{"cash_held_cents" => 10_000} = ledger()
    end

    test "credit late adjustments report issued and revoked with balances using both" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      close_period!(%{"period_end_on" => "2026-11-04"})

      # An old-dated conversion to hotel credit posts converted cash and
      # issued credit on the first open day.
      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      report = daily_report("2026-11-05")

      assert report["late_adjustments"]["credit"] ==
               Map.put(@zero_credit_movements, "issued_cents", 5500)

      assert [%{"movements" => %{"converted_to_credit_cents" => 5000}}] =
               report["late_adjustments"]["cash"]

      assert report["credit"]["movements"] == @zero_credit_movements
      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 5500

      # An old-dated chargeback revokes the issued credit on the same day.
      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-03"
        })
      )

      report = daily_report("2026-11-05")

      late_credit = report["late_adjustments"]["credit"]

      assert late_credit["issued_cents"] == 5500
      assert late_credit["revoked_cents"] == 5500
      assert report["credit"]["closing_liability_cents"] == 0

      assert %{"credit_liability_cents" => 0} = ledger()
    end

    test "an old-dated chargeback of a lot that expired inside the closed period revokes late" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      # The lot is issued on 2026-11-03 and expires on 2027-11-03; its
      # natural expiry movement falls on 2027-11-04, inside the closed
      # period below.
      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      close_period!(%{"period_end_on" => "2027-11-05"})

      assert %{"movements" => %{"expired_cents" => 5500}} =
               daily_report("2027-11-04")["credit"]

      # The chargeback occurred while the lot was unexpired, but a close
      # moved its posting date past the lot's expiry. The revocation still
      # posts late, so the open report reconciles with the current ledger.
      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2027-11-01"
        })
      )

      report = daily_report("2027-11-06")

      assert report["late_adjustments"]["credit"]["revoked_cents"] == 5500
      assert report["credit"]["closing_liability_cents"] == 0

      assert %{"credit_liability_cents" => 0} = ledger()
    end

    test "late cash entries are ordered by property_id and omit properties without late movements" do
      open_group!(
        build_conn(),
        %{"group_id" => "group-92", "property_id" => "zbur-market"}
      )

      open_group!(
        build_conn(),
        %{"group_id" => "group-93", "property_id" => "berlin-hbf"}
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      close_period!(%{"period_end_on" => "2026-11-04"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-92",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        })
      )

      # An open-period payment posts ordinarily on the first open day.
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-93",
          "amount_cents" => 1000,
          "occurred_on" => "2026-11-05"
        })
      )

      report = daily_report("2026-11-05")

      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "zbur-market"]

      # The ordinary cash array still covers every property with a balance
      # or an ordinary movement, in property order.
      assert Enum.map(report["cash"], & &1["property_id"]) ==
               ["ams-canal", "berlin-hbf", "zbur-market"]
    end

    test "a close publishes late adjustments posted on the days it closes" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      close_period!(%{"period_end_on" => "2026-11-04"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-03"
        })
      )

      # The movement is late on the first open day; the later close
      # publishes that day with the late adjustment frozen in place.
      close_period!(%{"period_end_on" => "2026-11-06"})

      report = daily_report("2026-11-05")

      assert report["status"] == "closed"

      assert [%{"movements" => %{"received_cents" => 3000}}] =
               report["late_adjustments"]["cash"]

      assert %{"movements" => @zero_cash_movements, "closing_held_cents" => 8000} =
               cash_entry(report)
    end

    test "each open day reconciles: closing equals opening plus ordinary and late movements" do
      open_group!(
        build_conn(),
        %{"group_id" => "group-92", "property_id" => "zbur-market"}
      )

      operations = [
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        }),
        record_cash_operation(%{
          "group_id" => "group-92",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-02"
        }),
        close_period_operation(%{"period_end_on" => "2026-11-04"}),
        transfer_deposit_operation(%{
          "source_group_id" => "group-81",
          "destination_group_id" => "group-92",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        }),
        reduce_cash_operation(%{
          "payment_operation_id" => "op-pay-1",
          "amount_cents" => 1000,
          "occurred_on" => "2026-11-02"
        }),
        cancel_operation(%{"group_id" => "group-92", "occurred_on" => "2026-11-05"})
      ]

      Enum.each(operations, &apply_one!(build_conn(), &1))

      for date <- ["2026-11-05", "2026-11-06"] do
        report = daily_report(date)

        late_by_property =
          report["late_adjustments"]["cash"]
          |> Map.new(&{&1["property_id"], &1["movements"]})

        for entry <- report["cash"] do
          movements = entry["movements"]
          late = Map.get(late_by_property, entry["property_id"], @zero_cash_movements)

          expected =
            entry["opening_held_cents"] +
              (movements["received_cents"] + late["received_cents"]) +
              (movements["transferred_in_cents"] + late["transferred_in_cents"]) -
              (movements["transferred_out_cents"] + late["transferred_out_cents"]) -
              (movements["refunded_cents"] + late["refunded_cents"]) -
              (movements["retained_cents"] + late["retained_cents"]) -
              (movements["converted_to_credit_cents"] + late["converted_to_credit_cents"]) -
              (movements["reduced_cents"] + late["reduced_cents"]) -
              (movements["charged_back_cents"] + late["charged_back_cents"])

          assert expected == entry["closing_held_cents"],
                 "cash identity failed for #{date} #{entry["property_id"]}"
        end
      end

      # The latest open report reconciles to the current ledger view.
      final = daily_report("2026-11-06")

      held =
        final["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

      assert held == ledger()["cash_held_cents"]
    end
  end

  ## Helpers

  defp start_reporting!(attrs) do
    result = apply_one!(build_conn(), start_reporting_operation(attrs))
    assert %{"status" => "applied"} = result
    result
  end

  defp close_period!(attrs) do
    result = apply_one!(build_conn(), close_period_operation(attrs))
    assert %{"status" => "applied"} = result
    result
  end

  defp daily_report(date) do
    conn = get_daily_report(build_conn(), date)
    assert %{status: 200} = conn
    json_response(conn, 200)["data"]
  end

  defp cash_entry(report, property_id \\ "ams-canal")

  defp cash_entry(%{} = report, property_id) do
    report
    |> Map.fetch!("cash")
    |> Enum.find(&(&1["property_id"] == property_id))
  end

  defp cash_movements(report_or_date, property_id \\ "ams-canal")

  defp cash_movements(%{} = report, property_id),
    do: cash_entry(report, property_id)["movements"]

  defp cash_movements(date, property_id) when is_binary(date),
    do: date |> daily_report() |> cash_movements(property_id)

  defp ledger(on \\ nil) do
    assert %{status: 200} = conn = get_ledger(build_conn(), on)
    json_response(conn, 200)["data"]
  end
end
