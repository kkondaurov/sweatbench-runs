defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  describe "close_finance_period" do
    test "applies with exactly operation_id, status, and period_end_on", %{conn: conn} do
      conn = post_batch(conn, [start_op("2026-10-01"), close_op("2026-10-05")])

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-start",
                 "status" => "applied",
                 "starts_on" => "2026-10-01"
               },
               %{
                 "operation_id" => "op-close",
                 "status" => "applied",
                 "period_end_on" => "2026-10-05"
               }
             ]
    end

    test "rejects a close before reporting has started", %{conn: conn} do
      conn = post_batch(conn, [close_op("2026-10-05")])

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-close",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
    end

    test "rejects a missing or invalid period_end_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op("2026-10-01"),
          %{"operation_id" => "no-date", "type" => "close_finance_period"},
          close_op("2026-13-40", "bad-date")
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "no-date",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "bad-date",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a cutoff before starts_on", %{conn: conn} do
      conn = post_batch(conn, [start_op("2026-10-10"), close_op("2026-10-09")])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_period"}
             ] = json_response(conn, 200)["results"]
    end

    test "accepts a cutoff on starts_on and rejects the same or an earlier later close", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          start_op("2026-10-01"),
          close_op("2026-10-01"),
          close_op("2026-10-01", "op-close-same"),
          close_op("2026-09-30", "op-close-earlier"),
          close_op("2026-10-02", "op-close-later")
        ])

      assert [
               %{"status" => "applied", "starts_on" => "2026-10-01"},
               %{"status" => "applied", "period_end_on" => "2026-10-01"},
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "applied", "period_end_on" => "2026-10-02"}
             ] = json_response(conn, 200)["results"]
    end

    test "replays the original close and conflicts on a different payload", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [start_op("2026-10-01"), close_op("2026-10-05")])

      conn = post_batch(conn, [close_op("2026-10-05")])

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-close",
                 "status" => "applied",
                 "period_end_on" => "2026-10-05"
               }
             ]

      conn = post_batch(conn, [close_op("2026-10-06")])

      assert [
               %{
                 "operation_id" => "op-close",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "does not address a group or consume a revision", %{conn: conn} do
      conn =
        post_batch(conn, [open_op(), start_op("2026-10-01"), close_op("2026-10-01"), pay_op(1000)])

      assert [
               %{"revision" => 1},
               %{"status" => "applied", "starts_on" => "2026-10-01"},
               %{"status" => "applied", "period_end_on" => "2026-10-01"},
               %{"revision" => 2}
             ] = json_response(conn, 200)["results"]

      close = Enum.at(json_response(conn, 200)["results"], 2)
      refute Map.has_key?(close, "revision")
      refute Map.has_key?(close, "group_id")
    end

    test "exposes the stored close result", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [start_op("2026-10-01"), close_op("2026-10-05")])

      conn = get(recycle(conn), "/api/v1/operations/op-close")

      assert json_response(conn, 200)["data"] == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-10-05"
             }
    end
  end

  describe "closed and open report status" do
    test "publishes reports through the cutoff and leaves later days open", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          pay_op(2500),
          close_op("2026-10-04")
        ])

      conn = get_report(conn, "2026-10-01")
      assert json_response(conn, 200)["data"]["status"] == "closed"

      conn = get_report(conn, "2026-10-04")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      assert hd(closed["cash"])["movements"]["received_cents"] == 2500
      assert hd(closed["cash"])["closing_held_cents"] == 2500
      assert closed["late_adjustments"] == zero_late_adjustments()

      conn = get_report(conn, "2026-10-05")
      open = json_response(conn, 200)["data"]
      assert open["status"] == "open"
      assert hd(open["cash"])["opening_held_cents"] == 2500
      assert hd(open["cash"])["closing_held_cents"] == 2500
    end

    test "keeps a closed report byte-stable after later operations and closes", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          pay_op(2500),
          close_op("2026-10-04")
        ])

      conn = get_report(conn, "2026-10-04")
      frozen = json_response(conn, 200)["data"]

      {:ok, conn} =
        open_and_return(recycle(conn), [
          Map.merge(pay_op(1000), %{"operation_id" => "pay-late", "occurred_on" => "2026-10-04"}),
          close_op("2026-10-10", "op-close-2")
        ])

      conn = get_report(conn, "2026-10-04")
      assert json_response(conn, 200)["data"] == frozen

      conn = get_report(conn, "2026-10-04")
      assert json_response(conn, 200)["data"] == frozen
    end
  end

  describe "posting after a close" do
    test "posts an old-dated operation after a close onto the first open day as late", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          close_op("2026-10-10")
        ])

      {:ok, conn} =
        open_and_return(conn, [
          Map.merge(pay_op(2000), %{"occurred_on" => "2026-10-04"})
        ])

      conn = get_report(conn, "2026-10-04")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      assert closed["cash"] == []
      assert closed["late_adjustments"] == zero_late_adjustments()

      conn = get_report(conn, "2026-10-11")
      open = json_response(conn, 200)["data"]
      assert open["status"] == "open"
      assert hd(open["cash"])["opening_held_cents"] == 0
      assert hd(open["cash"])["movements"]["received_cents"] == 0
      assert hd(open["cash"])["closing_held_cents"] == 2000

      assert open["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => Map.merge(zero_cash_movements(), %{"received_cents" => 2000})
               }
             ]

      assert_cash_identity(open)
    end

    test "keeps occurred_on when it is already in the open period", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          close_op("2026-10-10")
        ])

      {:ok, conn} =
        open_and_return(conn, [
          Map.merge(pay_op(3000), %{"occurred_on" => "2026-10-20"})
        ])

      conn = get_report(conn, "2026-10-11")
      first_open = json_response(conn, 200)["data"]
      assert first_open["cash"] == []
      assert first_open["late_adjustments"] == zero_late_adjustments()

      conn = get_report(conn, "2026-10-20")
      later = json_response(conn, 200)["data"]
      assert hd(later["cash"])["movements"]["received_cents"] == 3000
      assert later["late_adjustments"] == zero_late_adjustments()
      assert hd(later["cash"])["closing_held_cents"] == 3000
    end

    test "lets an operation immediately before a close post into the period being closed", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          start_op("2026-10-01"),
          pay_op(1500),
          close_op("2026-10-04")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-04")
      report = json_response(conn, 200)["data"]
      assert report["status"] == "closed"
      assert hd(report["cash"])["movements"]["received_cents"] == 1500
      assert report["late_adjustments"] == zero_late_adjustments()
    end

    test "posts an old-dated operation immediately after a close onto the first open day", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          start_op("2026-10-01"),
          close_op("2026-10-04"),
          pay_op(1800)
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-04")
      closed = json_response(conn, 200)["data"]
      assert closed["cash"] == []

      conn = get_report(conn, "2026-10-05")
      open = json_response(conn, 200)["data"]
      assert hd(open["late_adjustments"]["cash"])["movements"]["received_cents"] == 1800
      assert hd(open["cash"])["movements"]["received_cents"] == 0
      assert hd(open["cash"])["closing_held_cents"] == 1800
    end

    test "does not move a committed posting date when a later close arrives", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          close_op("2026-10-04"),
          Map.merge(pay_op(2200), %{"occurred_on" => "2026-10-08"})
        ])

      conn = get_report(conn, "2026-10-08")
      before = json_response(conn, 200)["data"]
      assert hd(before["cash"])["movements"]["received_cents"] == 2200
      assert before["status"] == "open"

      {:ok, conn} = open_and_return(recycle(conn), [close_op("2026-10-10", "op-close-2")])

      conn = get_report(conn, "2026-10-08")
      after_close = json_response(conn, 200)["data"]
      assert after_close["status"] == "closed"
      assert hd(after_close["cash"])["movements"]["received_cents"] == 2200
      assert after_close["late_adjustments"] == zero_late_adjustments()

      conn = get_report(conn, "2026-10-11")
      next_open = json_response(conn, 200)["data"]
      assert hd(next_open["cash"])["opening_held_cents"] == 2200
      assert hd(next_open["cash"])["movements"]["received_cents"] == 0
      assert next_open["late_adjustments"] == zero_late_adjustments()
    end

    test "freezes late adjustments in place when a later close covers them", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          close_op("2026-10-04"),
          pay_op(2200)
        ])

      conn = get_report(conn, "2026-10-05")
      before = json_response(conn, 200)["data"]
      assert hd(before["late_adjustments"]["cash"])["movements"]["received_cents"] == 2200
      assert before["status"] == "open"

      {:ok, conn} = open_and_return(recycle(conn), [close_op("2026-10-10", "op-close-2")])

      conn = get_report(conn, "2026-10-05")
      frozen = json_response(conn, 200)["data"]
      assert frozen["status"] == "closed"
      assert frozen["late_adjustments"] == before["late_adjustments"]
      assert hd(frozen["cash"])["closing_held_cents"] == 2200
      assert frozen["cash"] == before["cash"]

      conn = get_report(conn, "2026-10-11")
      next_open = json_response(conn, 200)["data"]
      assert hd(next_open["cash"])["opening_held_cents"] == 2200
      assert next_open["late_adjustments"] == zero_late_adjustments()
    end

    test "does not change group, ledger, or payment-statement current state", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          pay_op(2500),
          close_op("2026-10-04"),
          Map.merge(pay_op(1000), %{"operation_id" => "pay-2", "occurred_on" => "2026-10-02"})
        ])

      conn = get(conn, "/api/v1/groups/group-81")
      group = json_response(conn, 200)["data"]
      assert group["cash_paid_cents"] == 3500
      assert group["outstanding_deposit_cents"] == group["deposit_due_cents"] - 3500

      conn = get(conn, "/api/v1/ledger?on=2026-10-04")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 3500

      conn = get(conn, "/api/v1/payments/op-pay")
      assert json_response(conn, 200)["data"]["held_cents"] == 2500
    end
  end

  describe "late adjustments" do
    test "keeps signed chargeback classifications that net to zero", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(4000),
          start_op("2026-10-01"),
          cancel_op("cancel-1", "2026-10-04"),
          close_op("2026-10-10"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "op-pay"
          }
        ])

      conn = get_report(conn, "2026-10-06")
      assert json_response(conn, 200)["data"]["status"] == "closed"

      conn = get_report(conn, "2026-10-11")
      report = json_response(conn, 200)["data"]
      entry = hd(report["cash"])
      late = hd(report["late_adjustments"]["cash"])

      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["refunded_cents"] == 0
      assert entry["movements"]["charged_back_cents"] == 0
      assert entry["closing_held_cents"] == 0

      assert late["property_id"] == "ams-canal"
      assert late["movements"]["refunded_cents"] == -4000
      assert late["movements"]["charged_back_cents"] == 4000
      assert_cash_identity(report)
    end

    test "orders late cash by property_id and omits all-zero properties", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          open_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-92",
            "property_id" => "rot-harbor"
          }),
          close_op("2026-10-10"),
          %{
            "operation_id" => "op-xfer",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-06",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 2000
          }
        ])

      conn = get_report(conn, "2026-10-11")
      report = json_response(conn, 200)["data"]

      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) == [
               "ams-canal",
               "rot-harbor"
             ]

      ams = Enum.at(report["late_adjustments"]["cash"], 0)
      rot = Enum.at(report["late_adjustments"]["cash"], 1)
      assert ams["movements"]["transferred_out_cents"] == 2000
      assert rot["movements"]["transferred_in_cents"] == 2000

      conn = get_report(conn, "2026-10-12")
      later = json_response(conn, 200)["data"]
      assert later["late_adjustments"]["cash"] == []
    end

    test "splits credit issue after a close into late adjustments", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(1000),
          start_op("2026-10-01"),
          close_op("2026-10-10"),
          cancel_op("credit-83", "2026-10-06", "hotel_credit")
        ])

      conn = get_report(conn, "2026-10-11")
      report = json_response(conn, 200)["data"]

      assert report["credit"]["movements"]["issued_cents"] == 0
      assert report["late_adjustments"]["credit"]["issued_cents"] == 1100
      assert report["credit"]["closing_liability_cents"] == 1100

      ams = Enum.find(report["cash"], &(&1["property_id"] == "ams-canal"))
      late = Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == "ams-canal"))
      assert ams["movements"]["converted_to_credit_cents"] == 0
      assert late["movements"]["converted_to_credit_cents"] == 1000
      assert ams["closing_held_cents"] == 0
    end

    test "always includes the credit late-adjustment object", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [start_op("2026-10-01"), close_op("2026-10-01")])

      conn = get_report(conn, "2026-10-02")
      report = json_response(conn, 200)["data"]

      assert report["late_adjustments"]["credit"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
    end

    test "keeps unused credit expiry inside a closed report", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          close_op("2027-11-02")
        ])

      conn = get_report(conn, "2027-11-02")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      assert closed["credit"]["movements"]["expired_cents"] == 5500
      assert closed["credit"]["closing_liability_cents"] == 0
      assert closed["late_adjustments"]["credit"]["expired_cents"] == 0

      {:ok, conn} =
        open_and_return(recycle(conn), [
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(1000), %{"operation_id" => "pay-2", "group_id" => "group-82"})
        ])

      conn = get_report(conn, "2027-11-02")
      assert json_response(conn, 200)["data"] == closed

      conn = get_report(conn, "2027-11-03")
      open = json_response(conn, 200)["data"]
      assert open["credit"]["opening_liability_cents"] == 0
      assert open["credit"]["movements"]["expired_cents"] == 0
      assert open["late_adjustments"]["credit"]["expired_cents"] == 0
    end

    test "expires a late-issued lot on the first open day when the cutoff covers expiry", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          close_op("2027-11-02"),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit")
        ])

      conn = get_report(conn, "2027-11-02")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      assert closed["credit"]["movements"]["issued_cents"] == 0
      assert closed["credit"]["movements"]["expired_cents"] == 0
      assert closed["late_adjustments"]["credit"]["issued_cents"] == 0
      assert closed["late_adjustments"]["credit"]["expired_cents"] == 0

      conn = get_report(conn, "2027-11-03")
      open = json_response(conn, 200)["data"]
      assert open["credit"]["movements"]["issued_cents"] == 0
      assert open["credit"]["movements"]["expired_cents"] == 0
      assert open["late_adjustments"]["credit"]["issued_cents"] == 5500
      assert open["late_adjustments"]["credit"]["expired_cents"] == 5500
      assert open["credit"]["closing_liability_cents"] == 0

      late_cash = hd(open["late_adjustments"]["cash"])
      assert late_cash["movements"]["converted_to_credit_cents"] == 5000
      assert_cash_identity(open)
    end
  end

  defp start_op(starts_on, operation_id \\ "op-start") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_op(period_end_on, operation_id \\ "op-close") do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp get_report(conn, date) do
    get(recycle(conn), "/api/v1/finance/daily-report?date=#{date}")
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

  defp zero_late_adjustments do
    %{
      "cash" => [],
      "credit" => %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      }
    }
  end

  defp assert_cash_identity(report) do
    late_by_property =
      Map.new(report["late_adjustments"]["cash"], fn entry ->
        {entry["property_id"], entry["movements"]}
      end)

    Enum.each(report["cash"], fn entry ->
      m = entry["movements"]
      late = Map.get(late_by_property, entry["property_id"], zero_cash_movements())

      assert entry["closing_held_cents"] ==
               entry["opening_held_cents"] + m["received_cents"] + late["received_cents"] +
                 m["transferred_in_cents"] + late["transferred_in_cents"] -
                 m["transferred_out_cents"] - late["transferred_out_cents"] -
                 m["refunded_cents"] - late["refunded_cents"] - m["retained_cents"] -
                 late["retained_cents"] - m["converted_to_credit_cents"] -
                 late["converted_to_credit_cents"] - m["reduced_cents"] - late["reduced_cents"] -
                 m["charged_back_cents"] - late["charged_back_cents"]
    end)
  end

  defp open_and_return(conn, operations) do
    conn = post_batch(conn, operations)
    assert conn.status == 200
    {:ok, conn}
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1001",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp pay_op(amount_cents) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, occurred_on, refund_method \\ nil) do
    op = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-81"
    }

    if refund_method, do: Map.put(op, "refund_method", refund_method), else: op
  end
end
