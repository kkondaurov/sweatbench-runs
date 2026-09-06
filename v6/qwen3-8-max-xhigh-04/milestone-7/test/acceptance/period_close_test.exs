defmodule GroupStayWeb.Acceptance.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  # Two rooms over two nights (flexible, 20% deposit):
  #   room-a lodging 20000 deposit 4000
  #   room-b lodging 30000 deposit 6000
  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000}
        ]
      },
      overrides
    )
  end

  defp pay_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp start_op(op_id, starts_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => starts_on
      },
      overrides
    )
  end

  defp close_op(op_id, period_end_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "close_finance_period",
        "occurred_on" => "2026-11-20",
        "period_end_on" => period_end_on
      },
      overrides
    )
  end

  defp cancel_op(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}-#{occurred_on}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp apply_credit_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-03",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp reduce_op(op_id, payment_operation_id, amount_cents, overrides) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-03",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp charge_back_op(op_id, payment_operation_id, overrides) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp transfer_op(op_id, source_group_id, destination_group_id, amount_cents, overrides) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-02",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report", %{"date" => date})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # The raw response body, for byte-for-byte stability checks.
  defp report_body(conn, date) do
    conn = get(conn, "/api/v1/finance/daily-report", %{"date" => date})
    assert conn.status == 200
    conn.resp_body
  end

  defp ledger(conn, on \\ nil) do
    params = if on, do: %{"on" => on}, else: %{}

    conn
    |> get("/api/v1/ledger", params)
    |> json_response(200)
    |> Map.fetch!("data")
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

  describe "closing through a date" do
    test "the applied result contains exactly operation_id, status, and period_end_on" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2026-11-10"
               } = result
             ] = submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert Map.keys(result) |> Enum.sort() == ["operation_id", "period_end_on", "status"]
    end

    test "a close before reporting has started is rejected with invalid_period" do
      assert [%{"operation_id" => "close-1", "status" => "rejected", "code" => "invalid_period"}] =
               submit(build_conn(), [close_op("close-1", "2026-11-10")])
    end

    test "a close before starts_on is rejected with invalid_period" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               submit(build_conn(), [close_op("close-1", "2026-10-31")])
    end

    test "a close on starts_on applies" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [%{"status" => "applied", "period_end_on" => "2026-11-01"}] =
               submit(build_conn(), [close_op("close-1", "2026-11-01")])

      assert report(build_conn(), "2026-11-01")["status"] == "closed"
    end

    test "a different operation attempting the same cutoff is rejected" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert [%{"operation_id" => "close-2", "status" => "rejected", "code" => "invalid_period"}] =
               submit(build_conn(), [close_op("close-2", "2026-11-10")])
    end

    test "a different operation attempting an earlier cutoff is rejected" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               submit(build_conn(), [close_op("close-2", "2026-11-05")])
    end

    test "a strictly later cutoff applies" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert [%{"status" => "applied", "period_end_on" => "2026-11-15"}] =
               submit(build_conn(), [close_op("close-2", "2026-11-15")])
    end

    test "an invalid or missing period_end_on is rejected with invalid_period" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               submit(build_conn(), [close_op("close-1", "not-a-date")])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               submit(build_conn(), [
                 close_op("close-2", "2026-11-10") |> Map.delete("period_end_on")
               ])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               submit(build_conn(), [
                 close_op("close-3", "2026-11-10", %{"period_end_on" => 20_261_110})
               ])
    end

    test "a missing occurred_on is rejected with invalid_operation" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 close_op("close-1", "2026-11-10") |> Map.delete("occurred_on")
               ])
    end

    test "replaying an applied close returns its exact stored result" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      [first] = submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert submit(build_conn(), [close_op("close-1", "2026-11-10")]) == [first]
    end

    test "reusing the identifier with a different cutoff is a conflict" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [close_op("close-1", "2026-11-15")])
    end

    test "a rejected close is remembered durably" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-10-31")])

      assert submit(build_conn(), [close_op("close-1", "2026-10-31")]) == [
               %{
                 "operation_id" => "close-1",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]

      # The rejection did not establish a cutoff.
      assert [%{"status" => "applied", "period_end_on" => "2026-11-10"}] =
               submit(build_conn(), [close_op("close-2", "2026-11-10")])
    end

    test "a close does not address a group and changes no revision" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      group =
        build_conn()
        |> get("/api/v1/groups/group-a")
        |> json_response(200)
        |> Map.fetch!("data")

      assert group["revision"] == 1
      assert group["status"] == "active"
    end
  end

  describe "published reports" do
    setup do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 5000)])
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      :ok
    end

    test "reports through the cutoff are closed and later reports are open" do
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert report(build_conn(), "2026-11-01")["status"] == "closed"
      assert report(build_conn(), "2026-11-05")["status"] == "closed"
      assert report(build_conn(), "2026-11-10")["status"] == "closed"
      assert report(build_conn(), "2026-11-11")["status"] == "open"
    end

    test "a closed report is byte-for-byte stable across later operations" do
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      body_05 = report_body(build_conn(), "2026-11-05")
      body_10 = report_body(build_conn(), "2026-11-10")

      # An old-dated correction and a current operation, plus a retry.
      submit(build_conn(), [pay_op("pay-2", "group-a", 1000, %{"occurred_on" => "2026-11-04"})])
      submit(build_conn(), [pay_op("pay-3", "group-a", 2000, %{"occurred_on" => "2026-11-12"})])

      submit(build_conn(), [reduce_op("reduce-1", "pay-1", 500, %{"occurred_on" => "2026-11-06"})])

      submit(build_conn(), [pay_op("pay-2", "group-a", 1000, %{"occurred_on" => "2026-11-04"})])

      assert report_body(build_conn(), "2026-11-05") == body_05
      assert report_body(build_conn(), "2026-11-10") == body_10
    end

    test "a closed report is byte-for-byte stable across later closes" do
      submit(build_conn(), [close_op("close-1", "2026-11-10")])
      body = report_body(build_conn(), "2026-11-05")

      submit(build_conn(), [close_op("close-2", "2026-11-20")])

      assert report_body(build_conn(), "2026-11-05") == body
      assert report(build_conn(), "2026-11-20")["status"] == "closed"
      assert report(build_conn(), "2026-11-21")["status"] == "open"
    end

    test "a later close publishes the days between the cutoffs" do
      submit(build_conn(), [close_op("close-1", "2026-11-10")])
      submit(build_conn(), [pay_op("pay-2", "group-a", 1500, %{"occurred_on" => "2026-11-12"})])
      submit(build_conn(), [pay_op("pay-3", "group-a", 700, %{"occurred_on" => "2026-11-05"})])
      submit(build_conn(), [close_op("close-2", "2026-11-15")])

      # The old-dated payment posted on the first open day and stays a late
      # adjustment when that day is published by the second close.
      late_day = report(build_conn(), "2026-11-11")
      assert late_day["status"] == "closed"
      assert [%{"movements" => %{"received_cents" => 700}}] = late_day["late_adjustments"]["cash"]
      assert [%{"closing_held_cents" => 5700}] = late_day["cash"]

      day = report(build_conn(), "2026-11-12")
      assert day["status"] == "closed"

      assert [%{"movements" => %{"received_cents" => 1500}, "closing_held_cents" => 7200}] =
               day["cash"]
    end

    test "a late correction does not rewrite a closed day" do
      submit(build_conn(), [cancel_op("group-a", "2026-11-05")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      closed = report(build_conn(), "2026-11-05")

      assert [%{"movements" => %{"refunded_cents" => 5000}, "closing_held_cents" => 0}] =
               closed["cash"]

      # The chargeback occurred inside the closed period but is processed
      # after the close.
      submit(build_conn(), [charge_back_op("cb-1", "pay-1", %{"occurred_on" => "2026-11-06"})])

      assert report(build_conn(), "2026-11-05") == closed

      day = report(build_conn(), "2026-11-11")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{"refunded_cents" => -5000, "charged_back_cents" => 5000}
               }
             ] = day["late_adjustments"]["cash"]

      assert [%{"movements" => %{"refunded_cents" => 0}, "closing_held_cents" => 0}] = day["cash"]
    end
  end

  describe "posting after a close" do
    setup do
      submit(build_conn(), [open_op("group-a")])
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])
      :ok
    end

    test "an old-dated operation posts on the first open day" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-03"})])

      # The closed day keeps its snapshot without the movement.
      assert report(build_conn(), "2026-11-03")["cash"] == []

      day = report(build_conn(), "2026-11-11")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => movements,
                 "closing_held_cents" => 1000
               }
             ] = day["cash"]

      assert movements == zero_cash_movements()

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{"received_cents" => 1000} = late_movements
               }
             ] = day["late_adjustments"]["cash"]

      assert Map.delete(late_movements, "received_cents") ==
               Map.delete(zero_cash_movements(), "received_cents")
    end

    test "an operation already in the open period keeps its date" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-15"})])

      day = report(build_conn(), "2026-11-15")
      assert [%{"movements" => %{"received_cents" => 1000}}] = day["cash"]
      assert day["late_adjustments"]["cash"] == []
      assert report(build_conn(), "2026-11-11")["cash"] == []
    end

    test "the posting date is the latest of occurred_on, starts_on, and the first open day" do
      # Natural date is starts_on (occurred_on before starts_on); the close
      # moves it to the first open day.
      submit(build_conn(), [pay_op("pay-1", "group-a", 500, %{"occurred_on" => "2026-10-20"})])

      day = report(build_conn(), "2026-11-11")

      assert [%{"received_cents" => 500}] =
               Enum.map(
                 day["late_adjustments"]["cash"],
                 &(&1["movements"] |> Map.take(["received_cents"]))
               )

      assert [%{"closing_held_cents" => 500}] = day["cash"]
    end

    test "in one batch, an operation before a close posts into the closed period" do
      # The setup closed 2026-11-10, so 2026-11-15 is open when pay-1 commits.
      submit(build_conn(), [
        pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-15"}),
        close_op("close-2", "2026-11-20"),
        pay_op("pay-2", "group-a", 2000, %{"occurred_on" => "2026-11-15"})
      ])

      closed = report(build_conn(), "2026-11-15")
      assert closed["status"] == "closed"

      assert [%{"movements" => %{"received_cents" => 1000}, "closing_held_cents" => 1000}] =
               closed["cash"]

      assert closed["late_adjustments"]["cash"] == []

      first_open = report(build_conn(), "2026-11-21")

      assert [%{"movements" => %{"received_cents" => 2000}}] =
               first_open["late_adjustments"]["cash"]

      assert [%{"closing_held_cents" => 3000}] = first_open["cash"]
    end

    test "an operation keeps its posting date when a later close passes over it" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-12"})])
      submit(build_conn(), [close_op("close-2", "2026-11-20")])

      day = report(build_conn(), "2026-11-12")
      assert day["status"] == "closed"
      assert [%{"movements" => %{"received_cents" => 1000}}] = day["cash"]
      assert day["late_adjustments"]["cash"] == []
    end
  end

  describe "late adjustments" do
    test "before any close, late adjustments are empty" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000)])

      day = report(build_conn(), "2026-11-02")
      assert day["late_adjustments"] == %{"cash" => [], "credit" => zero_credit_movements()}
    end

    test "the day's total movement is the ordinary value plus the late-adjustment value" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      submit(build_conn(), [
        pay_op("pay-late", "group-a", 1000, %{"occurred_on" => "2026-11-05"}),
        pay_op("pay-open", "group-a", 2000, %{"occurred_on" => "2026-11-11"})
      ])

      day = report(build_conn(), "2026-11-11")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{"received_cents" => 2000},
                 "closing_held_cents" => 3000
               }
             ] = day["cash"]

      assert [%{"movements" => %{"received_cents" => 1000}}] = day["late_adjustments"]["cash"]
    end

    test "signed classifications survive a zero net balance effect" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 100)])
      submit(build_conn(), [cancel_op("group-a", "2026-11-05")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      submit(build_conn(), [charge_back_op("cb-1", "pay-1", %{"occurred_on" => "2026-11-08"})])

      day = report(build_conn(), "2026-11-11")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" =>
                   %{
                     "refunded_cents" => -100,
                     "charged_back_cents" => 100
                   } = late_movements
               }
             ] = day["late_adjustments"]["cash"]

      assert Map.delete(late_movements, "refunded_cents")
             |> Map.delete("charged_back_cents") ==
               Map.delete(zero_cash_movements(), "refunded_cents")
               |> Map.delete("charged_back_cents")

      # The ordinary columns stay zero and the closing uses both blocks.
      assert [%{"movements" => movements, "closing_held_cents" => 0}] = day["cash"]
      assert movements == zero_cash_movements()
    end

    test "the late cash array is ordered by property_id and omits all-zero properties" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b", %{"property_id" => "nyc-east"}),
        start_op("start-1", "2026-11-01")
      ])

      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      submit(build_conn(), [
        pay_op("pay-b-late", "group-b", 2000, %{"occurred_on" => "2026-11-03"}),
        pay_op("pay-a-late", "group-a", 1000, %{"occurred_on" => "2026-11-02"}),
        pay_op("pay-b-open", "group-b", 500, %{"occurred_on" => "2026-11-11"})
      ])

      day = report(build_conn(), "2026-11-11")

      # group-b's ordinary payment is not a late adjustment.
      assert Enum.map(day["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "nyc-east"]

      assert [%{"received_cents" => 1000}, %{"received_cents" => 2000}] =
               Enum.map(
                 day["late_adjustments"]["cash"],
                 &Map.take(&1["movements"], ["received_cents"])
               )
    end

    test "late credit movements are reported in the credit object" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-05", %{"refund_method" => "hotel_credit"})
      ])

      day = report(build_conn(), "2026-11-11")

      assert day["late_adjustments"]["credit"]["issued_cents"] == 4400

      assert [%{"movements" => %{"converted_to_credit_cents" => 4000}}] =
               day["late_adjustments"]["cash"]

      # The ordinary credit movements stay zero while the closing uses both.
      assert day["credit"]["movements"] == zero_credit_movements()
      assert day["credit"]["closing_liability_cents"] == 4400
    end

    test "the credit object is always present" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [close_op("close-1", "2026-11-10")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-05"})])

      assert report(build_conn(), "2026-11-11")["late_adjustments"]["credit"] ==
               zero_credit_movements()
    end
  end

  describe "credit expiry and closed periods" do
    test "applying credit after its report-time expiry keeps the liability correct" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-c"),
        pay_op("pay-c", "group-c", 4000)
      ])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-12-01")])
      submit(build_conn(), [close_op("close-1", "2027-11-30")])

      # The lot's expires_on is 2027-11-03; the closed report expired it.
      expiry_day = report(build_conn(), "2027-11-03")
      assert expiry_day["status"] == "closed"
      assert expiry_day["credit"]["movements"]["expired_cents"] == 4400
      assert expiry_day["credit"]["closing_liability_cents"] == 0

      # Domain-valid application (before the expiry) processed after the close.
      submit(build_conn(), [
        apply_credit_op("credit-a", "group-a", 2000, %{"occurred_on" => "2027-11-01"})
      ])

      day = report(build_conn(), "2027-12-01")
      assert day["credit"]["movements"] == zero_credit_movements()
      assert day["late_adjustments"]["credit"]["expired_cents"] == -2000
      assert day["credit"]["closing_liability_cents"] == 2000

      assert ledger(build_conn(), "2027-12-01")["credit_liability_cents"] == 2000

      # The closed expiry day is unchanged.
      assert report(build_conn(), "2027-11-03") == expiry_day
    end

    test "restoring credit after its report-time expiry keeps the liability correct" do
      submit(build_conn(), [
        open_op("group-a", %{"arrival_on" => "2028-01-10", "departure_on" => "2028-01-12"}),
        open_op("group-c"),
        pay_op("pay-c", "group-c", 4000)
      ])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-12-01")])
      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 2000)])
      submit(build_conn(), [close_op("close-1", "2027-11-30")])

      # The closed expiry expired only the unapplied 2400.
      assert report(build_conn(), "2027-11-03")["credit"]["movements"]["expired_cents"] == 2400

      # Refundable settlement inside the closed period restores the credit to
      # the already-expired lot.
      submit(build_conn(), [cancel_op("group-a", "2027-11-01")])

      day = report(build_conn(), "2027-12-01")
      assert day["credit"]["movements"] == zero_credit_movements()
      assert day["late_adjustments"]["credit"]["expired_cents"] == 2000
      assert day["credit"]["closing_liability_cents"] == 0
      assert ledger(build_conn(), "2027-12-01")["credit_liability_cents"] == 0
    end

    test "a chargeback after the lot's report-time expiry nets to zero" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [close_op("close-1", "2027-11-30")])

      expiry_day = report(build_conn(), "2027-11-03")
      assert expiry_day["credit"]["movements"]["expired_cents"] == 4400
      assert expiry_day["credit"]["closing_liability_cents"] == 0

      submit(build_conn(), [charge_back_op("cb-c", "pay-c", %{"occurred_on" => "2027-11-01"})])

      day = report(build_conn(), "2027-12-01")
      assert day["credit"]["movements"] == zero_credit_movements()
      assert day["late_adjustments"]["credit"]["revoked_cents"] == 4400
      assert day["late_adjustments"]["credit"]["expired_cents"] == -4400
      assert day["credit"]["closing_liability_cents"] == 0
      assert ledger(build_conn(), "2027-12-01")["credit_liability_cents"] == 0

      # The converted principal reverses and becomes charged-back cash, late.
      assert [
               %{
                 "movements" => %{
                   "converted_to_credit_cents" => -4000,
                   "charged_back_cents" => 4000
                 }
               }
             ] = day["late_adjustments"]["cash"]

      assert report(build_conn(), "2027-11-03") == expiry_day
    end
  end

  describe "durability and reconciliation" do
    setup do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b", %{"property_id" => "nyc-east"}),
        start_op("start-1", "2026-11-01")
      ])

      submit(build_conn(), [close_op("close-1", "2026-11-10")])
      :ok
    end

    test "a retry does not report a late movement twice" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-05"})])
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-05"})])

      assert [%{"movements" => %{"received_cents" => 1000}}] =
               report(build_conn(), "2026-11-11")["late_adjustments"]["cash"]
    end

    test "a rejected operation after a close leaves no movement" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 99999, %{"occurred_on" => "2026-11-05"})])

      day = report(build_conn(), "2026-11-11")
      assert day["cash"] == []
      assert day["late_adjustments"]["cash"] == []
    end

    test "replaying the close does not change closed reports" do
      body = report_body(build_conn(), "2026-11-05")
      submit(build_conn(), [close_op("close-1", "2026-11-10")])

      assert report_body(build_conn(), "2026-11-05") == body
    end

    test "cash closes follow the equation and reconcile with the ledger" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 7000)])

      # Late transfer (occurred inside the closed period) and an ordinary
      # reduction afterwards.
      submit(build_conn(), [
        transfer_op("transfer-1", "group-a", "group-b", 2000, %{"occurred_on" => "2026-11-08"})
      ])

      submit(build_conn(), [
        reduce_op("reduce-1", "pay-1", 1000, %{"occurred_on" => "2026-11-12"})
      ])

      day = report(build_conn(), "2026-11-12")

      Enum.each(day["cash"], fn entry ->
        m = entry["movements"]

        late =
          case Enum.find(
                 day["late_adjustments"]["cash"],
                 &(&1["property_id"] == entry["property_id"])
               ) do
            nil -> zero_cash_movements()
            late_entry -> late_entry["movements"]
          end

        assert entry["closing_held_cents"] ==
                 entry["opening_held_cents"] +
                   m["received_cents"] + late["received_cents"] +
                   m["transferred_in_cents"] + late["transferred_in_cents"] -
                   m["transferred_out_cents"] - late["transferred_out_cents"] -
                   m["refunded_cents"] - late["refunded_cents"] -
                   m["retained_cents"] - late["retained_cents"] -
                   m["converted_to_credit_cents"] - late["converted_to_credit_cents"] -
                   m["reduced_cents"] - late["reduced_cents"] -
                   m["charged_back_cents"] - late["charged_back_cents"]
      end)

      total_closing = Enum.reduce(day["cash"], 0, &(&1["closing_held_cents"] + &2))
      assert total_closing == ledger(build_conn())["cash_held_cents"]
      assert total_closing == 6000

      [ams, nyc] = day["cash"]
      assert ams["closing_held_cents"] == 5000
      assert nyc["closing_held_cents"] == 1000
    end

    test "credit closes reconcile with the ledger across a close" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [
        apply_credit_op("credit-a", "group-a", 2000, %{"occurred_on" => "2026-11-05"})
      ])

      day = report(build_conn(), "2026-11-11")
      assert day["credit"]["closing_liability_cents"] == 4400

      assert day["credit"]["closing_liability_cents"] ==
               ledger(build_conn(), "2026-11-11")["credit_liability_cents"]
    end
  end
end
