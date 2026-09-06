defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Groups

  describe "close_finance_period" do
    test "applies with exactly operation_id, status, and period_end_on", %{conn: conn} do
      conn = post_batch(conn, [start_reporting_op(), close_op()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "start-fin",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 },
                 %{
                   "operation_id" => "close-1",
                   "status" => "applied",
                   "period_end_on" => "2026-10-10"
                 }
               ]
             }
    end

    test "rejects when reporting has not started or the cutoff is invalid", %{conn: conn} do
      conn =
        post_batch(conn, [
          close_op(),
          start_reporting_op(),
          close_op(%{"operation_id" => "close-early", "period_end_on" => "2026-09-30"}),
          %{
            "operation_id" => "close-missing",
            "type" => "close_finance_period"
          },
          %{
            "operation_id" => "close-bad",
            "type" => "close_finance_period",
            "period_end_on" => "10/10/2026"
          },
          close_op(%{"operation_id" => "close-ok", "period_end_on" => "2026-10-01"}),
          close_op(%{"operation_id" => "close-same", "period_end_on" => "2026-10-01"}),
          close_op(%{"operation_id" => "close-earlier", "period_end_on" => "2026-09-30"})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "close-1",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 },
                 %{"operation_id" => "start-fin", "status" => "applied"},
                 %{
                   "operation_id" => "close-early",
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
                 %{
                   "operation_id" => "close-ok",
                   "status" => "applied",
                   "period_end_on" => "2026-10-01"
                 },
                 %{
                   "operation_id" => "close-same",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 },
                 %{
                   "operation_id" => "close-earlier",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "replays an applied close and conflicts on a different payload", %{conn: conn} do
      close = close_op()
      conn = post_batch(conn, [start_reporting_op(), close])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [close, close_op(%{"period_end_on" => "2026-10-11"})])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "close-1",
                   "status" => "applied",
                   "period_end_on" => "2026-10-10"
                 },
                 %{
                   "operation_id" => "close-1",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "does not increment a group revision", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          close_op()
        ])

      assert %{"results" => [_, %{"revision" => 1}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 1}} = json_response(conn, 200)
    end

    test "exposes the stored close result", %{conn: conn} do
      conn = post_batch(conn, [start_reporting_op(), close_op()])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/operations/close-1")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2026-10-10"
               }
             }
    end
  end

  describe "closed and open daily reports" do
    test "marks reports through the cutoff closed and later days open", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          close_op(%{"period_end_on" => "2026-10-05"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      closed = report(conn, "2026-10-04")
      assert closed["status"] == "closed"
      assert closed["late_adjustments"] == zero_late_adjustments()
      assert hd(closed["cash"])["movements"]["received_cents"] == 5000
      assert hd(closed["cash"])["closing_held_cents"] == 5000

      still_closed = report(conn, "2026-10-05")
      assert still_closed["status"] == "closed"
      assert hd(still_closed["cash"])["opening_held_cents"] == 5000
      assert hd(still_closed["cash"])["closing_held_cents"] == 5000

      open = report(conn, "2026-10-06")
      assert open["status"] == "open"
      assert hd(open["cash"])["opening_held_cents"] == 5000
      assert hd(open["cash"])["closing_held_cents"] == 5000
      assert open["late_adjustments"] == zero_late_adjustments()
    end

    test "keeps a closed report byte-stable after later operations and another close", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          close_op(%{"period_end_on" => "2026-10-05"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      first = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      first_body = json_response(first, 200)
      first_raw = first.resp_body

      conn =
        post_batch(conn, [
          cash_payment_op("pay-late", 1000, "group-81", "2026-10-04"),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-04",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 500
          },
          close_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-08"})
        ])

      assert %{"results" => later} = json_response(conn, 200)
      assert Enum.all?(later, &(&1["status"] == "applied"))

      second = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      assert second.resp_body == first_raw
      assert json_response(second, 200) == first_body

      open = report(conn, "2026-10-06")
      assert open["status"] == "closed"
      assert hd(open["cash"])["movements"] == zero_cash_movements()
      assert hd(open["late_adjustments"]["cash"])["movements"]["received_cents"] == 1000
      assert hd(open["late_adjustments"]["cash"])["movements"]["reduced_cents"] == 500
      assert hd(open["cash"])["closing_held_cents"] == 5500
      assert_cash_identity(open)
    end

    test "posts an operation before a close into the period being closed", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 4000, "group-81", "2026-10-04"),
          close_op(%{"period_end_on" => "2026-10-04"}),
          cash_payment_op("pay-after", 1000, "group-81", "2026-10-04")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      closed = report(conn, "2026-10-04")
      assert closed["status"] == "closed"
      assert hd(closed["cash"])["movements"]["received_cents"] == 4000
      assert hd(closed["cash"])["closing_held_cents"] == 4000
      assert closed["late_adjustments"] == zero_late_adjustments()

      open = report(conn, "2026-10-05")
      assert open["status"] == "open"
      assert hd(open["cash"])["movements"] == zero_cash_movements()
      assert hd(open["late_adjustments"]["cash"])["movements"]["received_cents"] == 1000
      assert hd(open["cash"])["closing_held_cents"] == 5000
      assert_cash_identity(open)
    end

    test "keeps an already-open posting date when a later close arrives", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000, "group-81", "2026-10-12"),
          close_op(%{"period_end_on" => "2026-10-20"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      day = report(conn, "2026-10-12")
      assert day["status"] == "closed"
      assert hd(day["cash"])["movements"]["received_cents"] == 5000
      assert day["late_adjustments"] == zero_late_adjustments()

      later = report(conn, "2026-10-21")
      assert later["status"] == "open"
      assert hd(later["cash"])["opening_held_cents"] == 5000
      assert hd(later["cash"])["movements"]["received_cents"] == 0
    end

    test "does not treat a same-day open-period posting as late", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          close_op(%{"period_end_on" => "2026-10-03"}),
          cash_payment_op("pay-17", 5000, "group-81", "2026-10-04")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      day = report(conn, "2026-10-04")
      assert day["status"] == "open"
      assert hd(day["cash"])["movements"]["received_cents"] == 5000
      assert day["late_adjustments"] == zero_late_adjustments()
    end
  end

  describe "late adjustments" do
    test "keeps signed chargeback classifications when net held is unchanged", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 100),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          },
          close_op(%{"period_end_on" => "2026-11-01"}),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-01",
            "payment_operation_id" => "pay-17"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      closed = report(conn, "2026-11-01")
      assert hd(closed["cash"])["movements"]["refunded_cents"] == 100
      assert closed["late_adjustments"] == zero_late_adjustments()

      open = report(conn, "2026-11-02")
      late = hd(open["late_adjustments"]["cash"])["movements"]
      assert late["refunded_cents"] == -100
      assert late["charged_back_cents"] == 100
      assert hd(open["cash"])["movements"] == zero_cash_movements()
      assert hd(open["cash"])["closing_held_cents"] == 0
      assert_cash_identity(open)
    end

    test "orders late cash by property_id and omits all-zero properties", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          open_group_op(%{
            "operation_id" => "op-open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          cash_payment_op("pay-17", 5000),
          close_op(%{"period_end_on" => "2026-10-05"}),
          transfer_op("xfer-1", 2000, "2026-10-04")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      open = report(conn, "2026-10-06")

      assert Enum.map(open["late_adjustments"]["cash"], & &1["property_id"]) == [
               "ams-canal",
               "rot-harbour"
             ]

      [canal, harbour] = open["late_adjustments"]["cash"]
      assert canal["movements"]["transferred_out_cents"] == 2000
      assert harbour["movements"]["transferred_in_cents"] == 2000
      assert open["credit"]["movements"] == zero_credit_movements()
      assert open["late_adjustments"]["credit"] == zero_credit_movements()
      assert_cash_identity(open)
    end

    test "posts late credit issue and deferred expiry on the first open day", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          close_op(%{"period_end_on" => "2027-12-01"}),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      closed = report(conn, "2026-11-01")
      assert closed["status"] == "closed"
      assert hd(closed["cash"])["movements"]["converted_to_credit_cents"] == 0
      assert closed["credit"]["movements"]["issued_cents"] == 0

      open = report(conn, "2027-12-02")
      assert open["status"] == "open"

      assert hd(open["late_adjustments"]["cash"])["movements"]["converted_to_credit_cents"] ==
               5000

      assert open["late_adjustments"]["credit"]["issued_cents"] == 5500
      assert open["late_adjustments"]["credit"]["expired_cents"] == 5500
      assert open["credit"]["movements"] == zero_credit_movements()
      assert open["credit"]["closing_liability_cents"] == 0
      assert_credit_identity(open)
      assert_cash_identity(open)
    end

    test "expires restored credit as a late adjustment when the natural day is closed", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          %{
            "operation_id" => "op-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-82",
            "amount_cents" => 5500
          },
          close_op(%{"period_end_on" => "2027-11-02"}),
          %{
            "operation_id" => "cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2027-10-01",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      closed_expiry = report(conn, "2027-11-02")
      assert closed_expiry["status"] == "closed"
      assert closed_expiry["credit"]["movements"]["expired_cents"] == 0
      assert closed_expiry["late_adjustments"]["credit"]["expired_cents"] == 0

      open = report(conn, "2027-11-03")
      assert open["status"] == "open"
      assert open["credit"]["movements"] == zero_credit_movements()
      assert open["late_adjustments"]["credit"]["expired_cents"] == 5500
      assert open["credit"]["closing_liability_cents"] == 0
      assert_credit_identity(open)
    end

    test "does not change group, ledger, or payment current state", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          close_op(%{"period_end_on" => "2026-10-05"}),
          cash_payment_op("pay-late", 1000, "group-81", "2026-10-04")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      group = json_response(conn, 200)["data"]
      assert group["revision"] == 3
      assert group["cash_paid_cents"] == 6000
      assert group["outstanding_deposit_cents"] == 13500

      conn = get_json(conn, ~p"/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 6000
      assert Groups.ledger()[:cash_held_cents] == 6000

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert json_response(conn, 200)["data"]["held_cents"] == 5000

      closed = report(conn, "2026-10-04")
      assert hd(closed["cash"])["closing_held_cents"] == 5000

      open = report(conn, "2026-10-06")
      assert hd(open["late_adjustments"]["cash"])["movements"]["received_cents"] == 1000
      assert hd(open["cash"])["closing_held_cents"] == 6000
    end
  end

  defp report(conn, date) do
    conn
    |> get_json("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp assert_cash_identity(report) do
    late_by_property =
      report
      |> get_in(["late_adjustments", "cash"])
      |> List.wrap()
      |> Map.new(&{&1["property_id"], &1["movements"]})

    Enum.each(report["cash"], fn entry ->
      m = add_movement_maps(entry["movements"], Map.get(late_by_property, entry["property_id"]))

      assert entry["closing_held_cents"] ==
               entry["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end)
  end

  defp assert_credit_identity(report) do
    c = report["credit"]
    m = add_movement_maps(c["movements"], get_in(report, ["late_adjustments", "credit"]))

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]
  end

  defp add_movement_maps(left, nil), do: left

  defp add_movement_maps(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
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

  defp zero_late_adjustments do
    %{"cash" => [], "credit" => zero_credit_movements()}
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp get_json(conn, path) do
    conn
    |> recycle()
    |> get(path)
  end

  defp start_reporting_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "start-fin",
        "type" => "start_finance_reporting",
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
        "period_end_on" => "2026-10-10"
      },
      overrides
    )
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp cash_payment_op(
         operation_id,
         amount_cents,
         group_id \\ "group-81",
         occurred_on \\ "2026-10-04"
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(operation_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => "group-81",
      "destination_group_id" => "group-92",
      "amount_cents" => amount_cents
    }
  end
end
