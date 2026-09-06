defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "close_finance_period" do
    test "applies with exactly operation_id, status, and period_end_on", %{conn: conn} do
      conn = post_batch(conn, [start_op(), close_op()])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "close-1",
                   "status" => "applied",
                   "period_end_on" => "2026-10-10"
                 }
               ]
             } = json_response(conn, 200)

      result = json_response(conn, 200)["results"] |> Enum.at(1)
      assert Map.keys(result) |> Enum.sort() == ["operation_id", "period_end_on", "status"]
    end

    test "does not use a revision guard", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          close_op(%{"expected_revision" => 99})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied", "period_end_on" => "2026-10-10"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects when reporting has not started or the cutoff is unusable", %{conn: conn} do
      conn =
        post_batch(conn, [
          close_op(),
          close_op(%{"operation_id" => "close-missing", "period_end_on" => nil}),
          close_op(%{"operation_id" => "close-bad", "period_end_on" => "10-10-2026"}),
          start_op(),
          close_op(%{"operation_id" => "close-early", "period_end_on" => "2026-09-30"})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "close-1",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 },
                 %{
                   "operation_id" => "close-missing",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 },
                 %{
                   "operation_id" => "close-bad",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 },
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "close-early",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects the same or an earlier cutoff and replays the original", %{conn: conn} do
      conn = post_batch(conn, [start_op(), close_op()])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          close_op(%{"operation_id" => "close-same", "period_end_on" => "2026-10-10"}),
          close_op(%{"operation_id" => "close-earlier", "period_end_on" => "2026-10-05"})
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "invalid_period"},
                 %{"status" => "rejected", "code" => "invalid_period"}
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [close_op()])
      original = hd(json_response(conn, 200)["results"])
      assert original["status"] == "applied"
      assert original["period_end_on"] == "2026-10-10"
      assert Map.keys(original) |> Enum.sort() == ["operation_id", "period_end_on", "status"]

      conn = post_batch(conn, [close_op(%{"period_end_on" => "2026-10-20"})])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/operations/close-1")

      assert %{"data" => %{"status" => "applied", "period_end_on" => "2026-10-10"}} =
               json_response(conn, 200)
    end

    test "allows a later cutoff after a successful close", %{conn: conn} do
      conn = post_batch(conn, [start_op(), close_op()])

      conn =
        post_batch(conn, [
          close_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-31"})
        ])

      assert %{"results" => [%{"status" => "applied", "period_end_on" => "2026-10-31"}]} =
               json_response(conn, 200)
    end
  end

  describe "closed daily reports" do
    test "reports through the cutoff become closed and later days stay open", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_group_op(), payment_op(5000), close_op()])

      conn = get_report(conn, "2026-10-04")
      report = json_response(conn, 200)["data"]
      assert report["status"] == "closed"
      assert hd(report["cash"])["movements"]["received_cents"] == 5000
      assert_late_adjustments_shape(report)

      conn = get_report(conn, "2026-10-10")
      assert json_response(conn, 200)["data"]["status"] == "closed"

      conn = get_report(conn, "2026-10-11")
      open = json_response(conn, 200)["data"]
      assert open["status"] == "open"
      assert hd(open["cash"])["opening_held_cents"] == 5000
      assert hd(open["cash"])["closing_held_cents"] == 5000
      assert_late_adjustments_shape(open)
    end

    test "closed report data stays byte-for-byte stable across later operations and closes", %{
      conn: conn
    } do
      conn = post_batch(conn, [start_op(), open_group_op(), payment_op(5000), close_op()])
      conn = get_report(conn, "2026-10-04")
      closed_body = conn.resp_body
      closed = json_response(conn, 200)["data"]

      conn =
        post_batch(conn, [
          payment_op(1000, "group-81", "2026-10-04") |> Map.put("operation_id", "pay-late"),
          cancel_op("group-81", "2026-11-26"),
          close_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-31"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-04")
      assert conn.resp_body == closed_body
      assert json_response(conn, 200)["data"] == closed
    end
  end

  describe "posting after a close" do
    test "an operation before a close in the same batch can post into the period being closed", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000, "group-81", "2026-10-04"),
          close_op(),
          payment_op(1000, "group-81", "2026-10-04") |> Map.put("operation_id", "pay-after-close")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-04")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      [cash] = closed["cash"]
      assert cash["movements"]["received_cents"] == 5000
      assert cash["closing_held_cents"] == 5000
      assert closed["late_adjustments"]["cash"] == []

      conn = get_report(conn, "2026-10-11")
      open = json_response(conn, 200)["data"]
      assert open["status"] == "open"
      [cash] = open["cash"]
      assert cash["opening_held_cents"] == 5000
      assert cash["movements"]["received_cents"] == 0
      assert hd(open["late_adjustments"]["cash"])["property_id"] == "ams-canal"
      assert hd(open["late_adjustments"]["cash"])["movements"]["received_cents"] == 1000
      assert cash["closing_held_cents"] == 6000
      assert_cash_identity(cash, open)
    end

    test "keeps occurred_on when it is already in the open period", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_group_op(), close_op()])

      conn =
        post_batch(conn, [
          payment_op(2000, "group-81", "2026-10-12"),
          payment_op(3000, "group-81", "2026-10-05") |> Map.put("operation_id", "pay-old")
        ])

      assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      conn = get_report(conn, "2026-10-11")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["movements"]["received_cents"] == 0
      assert hd(report["late_adjustments"]["cash"])["movements"]["received_cents"] == 3000
      assert cash["closing_held_cents"] == 3000

      conn = get_report(conn, "2026-10-12")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["opening_held_cents"] == 3000
      assert cash["movements"]["received_cents"] == 2000
      assert report["late_adjustments"]["cash"] == []
      assert cash["closing_held_cents"] == 5000
      assert_cash_identity(cash, report)
    end

    test "a later close does not move a posting date chosen at commit", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_group_op(), close_op()])
      conn = post_batch(conn, [payment_op(5000, "group-81", "2026-10-12")])

      conn = get_report(conn, "2026-10-12")
      before = json_response(conn, 200)["data"]
      assert hd(before["cash"])["movements"]["received_cents"] == 5000

      conn =
        post_batch(conn, [
          close_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-31"})
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_report(conn, "2026-10-12")
      after_close = json_response(conn, 200)["data"]
      assert after_close["status"] == "closed"
      assert hd(after_close["cash"])["movements"]["received_cents"] == 5000
      assert after_close["late_adjustments"]["cash"] == []

      conn = get_report(conn, "2026-11-01")
      next_open = json_response(conn, 200)["data"]
      assert next_open["status"] == "open"
      assert hd(next_open["cash"])["opening_held_cents"] == 5000
      assert hd(next_open["cash"])["movements"]["received_cents"] == 0
    end

    test "does not change group, ledger, or payment-statement current state", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_group_op(), payment_op(5000), close_op()])

      conn =
        post_batch(conn, [
          payment_op(1000, "group-81", "2026-10-04") |> Map.put("operation_id", "pay-late")
        ])

      assert %{"results" => [%{"status" => "applied", "outstanding_deposit_cents" => 13_500}]} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      group = json_response(conn, 200)["data"]
      assert group["deposit_paid_cents"] == 6000
      assert group["cash_paid_cents"] == 6000
      assert group["outstanding_deposit_cents"] == 13_500
      assert group["revision"] == 3

      conn = get(conn, ~p"/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 6000

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")

      assert %{"data" => %{"held_cents" => 5000, "recorded_cents" => 5000}} =
               json_response(conn, 200)

      conn = get_report(conn, "2026-10-04")
      assert hd(json_response(conn, 200)["data"]["cash"])["closing_held_cents"] == 5000
    end
  end

  describe "late adjustments" do
    test "keeps signed classifications when a chargeback nets to zero", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(100),
          cancel_op("group-81", "2026-11-26"),
          close_op(%{"period_end_on" => "2026-11-26"})
        ])

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-26",
            "payment_operation_id" => "op-pay-100-group-81"
          }
        ])

      assert %{"results" => [%{"status" => "applied", "charged_back_cents" => 100}]} =
               json_response(conn, 200)

      conn = get_report(conn, "2026-11-27")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["opening_held_cents"] == 0
      assert cash["closing_held_cents"] == 0
      assert cash["movements"]["refunded_cents"] == 0
      assert cash["movements"]["charged_back_cents"] == 0

      [late] = report["late_adjustments"]["cash"]
      assert late["property_id"] == "ams-canal"
      assert late["movements"]["refunded_cents"] == -100
      assert late["movements"]["charged_back_cents"] == 100
      assert Map.keys(late) |> Enum.sort() == ["movements", "property_id"]
      assert_cash_identity(cash, report)
    end

    test "omits all-zero properties from late cash and always includes credit", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_group_op(), payment_op(5000), close_op()])
      conn = get_report(conn, "2026-10-11")
      report = json_response(conn, 200)["data"]
      assert report["late_adjustments"]["cash"] == []
      assert report["late_adjustments"]["credit"]["issued_cents"] == 0

      assert Map.keys(report["late_adjustments"]["credit"]) |> Enum.sort() ==
               [
                 "absorbed_cents",
                 "consumed_cents",
                 "expired_cents",
                 "issued_cents",
                 "revoked_cents"
               ]
    end

    test "posts credit issued after a close as a late adjustment", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_group_op(), payment_op(5000), close_op()])

      conn =
        post_batch(conn, [
          cancel_op("group-81", "2026-10-04", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 5500}]} =
               json_response(conn, 200)

      conn = get_report(conn, "2026-10-04")
      closed = json_response(conn, 200)["data"]
      assert hd(closed["cash"])["movements"]["converted_to_credit_cents"] == 0
      assert closed["credit"]["movements"]["issued_cents"] == 0

      conn = get_report(conn, "2026-10-11")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["movements"]["converted_to_credit_cents"] == 0

      assert hd(report["late_adjustments"]["cash"])["movements"]["converted_to_credit_cents"] ==
               5000

      assert report["credit"]["movements"]["issued_cents"] == 0
      assert report["late_adjustments"]["credit"]["issued_cents"] == 5500
      assert report["credit"]["closing_liability_cents"] == 5500
      assert_cash_identity(cash, report)
      assert_credit_identity(report)
    end

    test "issues and expires credit on the first open day when the close already passed expiry",
         %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          close_op(%{"period_end_on" => "2027-11-27"})
        ])

      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_report(conn, "2027-11-27")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      assert closed["credit"]["movements"]["issued_cents"] == 0
      assert closed["credit"]["movements"]["expired_cents"] == 0
      assert closed["late_adjustments"]["credit"]["issued_cents"] == 0

      conn = get_report(conn, "2027-11-28")
      report = json_response(conn, 200)["data"]
      assert report["status"] == "open"
      assert report["credit"]["movements"]["issued_cents"] == 0
      assert report["credit"]["movements"]["expired_cents"] == 0
      assert report["late_adjustments"]["credit"]["issued_cents"] == 5500
      assert report["late_adjustments"]["credit"]["expired_cents"] == 5500
      assert report["credit"]["closing_liability_cents"] == 0
      assert_credit_identity(report)

      conn = get(conn, ~p"/api/v1/ledger?on=2027-11-28")
      assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
    end

    test "orders late cash properties by property_id", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          open_group_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-rot",
            "property_id" => "rot-harbor"
          }),
          payment_op(5000),
          payment_op(2000, "group-rot"),
          close_op()
        ])

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-ams",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-04",
            "payment_operation_id" => "op-pay-5000-group-81",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "reduce-rot",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-04",
            "payment_operation_id" => "op-pay-2000-group-rot",
            "amount_cents" => 500
          }
        ])

      conn = get_report(conn, "2026-10-11")
      report = json_response(conn, 200)["data"]

      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "rot-harbor"]

      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) == [
               "ams-canal",
               "rot-harbor"
             ]

      late = Map.new(report["late_adjustments"]["cash"], &{&1["property_id"], &1["movements"]})
      assert late["ams-canal"]["reduced_cents"] == 1000
      assert late["rot-harbor"]["reduced_cents"] == 500
      Enum.each(report["cash"], &assert_cash_identity(&1, report))
    end
  end

  defp start_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-01",
        "starts_on" => "2026-10-01"
      },
      overrides
    )
  end

  defp close_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "occurred_on" => "2026-10-10",
        "period_end_on" => "2026-10-10"
      },
      overrides
    )
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp open_group_op(overrides \\ %{}) do
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

  defp payment_op(amount_cents, group_id \\ "group-81", occurred_on \\ "2026-10-04") do
    %{
      "operation_id" => "op-pay-#{amount_cents}-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(group_id, occurred_on, extras \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extras
    )
  end

  defp get_report(conn, date) do
    get(conn, "/api/v1/finance/daily-report?date=#{date}")
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp assert_late_adjustments_shape(report) do
    late = report["late_adjustments"]
    assert is_list(late["cash"])
    assert is_map(late["credit"])

    assert Map.keys(late["credit"]) |> Enum.sort() ==
             [
               "absorbed_cents",
               "consumed_cents",
               "expired_cents",
               "issued_cents",
               "revoked_cents"
             ]
  end

  defp assert_cash_identity(entry, report) do
    late =
      report
      |> get_in(["late_adjustments", "cash"])
      |> List.wrap()
      |> Enum.find(%{"movements" => empty_cash()}, &(&1["property_id"] == entry["property_id"]))

    m = add_movements(entry["movements"], late["movements"])

    expected =
      entry["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
        m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
        m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]

    assert entry["closing_held_cents"] == expected
  end

  defp assert_credit_identity(report) do
    credit = report["credit"]
    m = add_movements(credit["movements"], report["late_adjustments"]["credit"])

    expected =
      credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
        m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    assert credit["closing_liability_cents"] == expected
  end

  defp add_movements(left, right) do
    Map.merge(left, right, fn _k, a, b -> a + b end)
  end

  defp empty_cash do
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
end
