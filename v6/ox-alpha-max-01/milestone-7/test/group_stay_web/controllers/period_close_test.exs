defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  @start "2027-01-01"

  defp results(conn), do: conn |> json_response(200) |> Map.fetch!("results")

  defp ledger_data(conn, query \\ []),
    do: conn |> get_ledger(query) |> json_response(200) |> Map.fetch!("data")

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

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), movements),
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(zero_credit_movements(), movements),
      "closing_liability_cents" => closing
    }
  end

  defp late_cash(movements_by_property) do
    Enum.map(movements_by_property, fn {property_id, movements} ->
      %{"property_id" => property_id, "movements" => Map.merge(zero_cash_movements(), movements)}
    end)
  end

  describe "closing through a date" do
    test "the applied result contains exactly operation_id, status, and period_end_on", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          start_reporting_operation(@start),
          close_period_operation("2027-01-31", %{"operation_id" => "op-close"})
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-close",
                 "status" => "applied",
                 "period_end_on" => "2027-01-31"
               }
             ] = results(conn)
    end

    test "rejects anything outside a started, valid, open period", %{conn: conn} do
      # Reporting has not started yet.
      conn = post_operations(conn, [close_period_operation("2027-01-31")])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] = results(conn)

      conn = post_operations(conn, [start_reporting_operation(@start)])

      conn =
        post_operations(conn, [
          # A missing or unusable period_end_on names no period at all.
          %{"operation_id" => "op-no-date", "type" => "close_finance_period"},
          close_period_operation("soon"),
          # Earlier than starts_on.
          close_period_operation("2026-12-31")
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "invalid_period"}
             ] = results(conn)

      # Nothing was published by the rejected attempts.
      assert %{"date" => @start, "status" => "open"} =
               Map.take(finance_report(conn, @start), ["date", "status"])
    end

    test "a close must move strictly past the latest cutoff", %{conn: conn} do
      conn =
        post_operations(conn, [
          start_reporting_operation(@start),
          close_period_operation("2027-01-10")
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = results(conn)

      conn =
        post_operations(conn, [
          close_period_operation("2027-01-10"),
          close_period_operation("2027-01-09"),
          close_period_operation(@start)
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "invalid_period"}
             ] = results(conn)

      assert %{"status" => "closed"} = finance_report(conn, "2027-01-10")
      assert %{"status" => "open"} = finance_report(conn, "2027-01-11")
    end

    test "closing through starts_on itself applies", %{conn: conn} do
      conn =
        post_operations(conn, [
          start_reporting_operation(@start),
          close_period_operation(@start)
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = results(conn)
      assert %{"status" => "closed"} = finance_report(conn, @start)
    end

    test "an exact retry replays durably while other identifiers conflict or reject", %{
      conn: conn
    } do
      close = close_period_operation("2027-01-10", %{"operation_id" => "op-close"})

      conn = post_operations(conn, [start_reporting_operation(@start), close])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-close",
                 "status" => "applied",
                 "period_end_on" => "2027-01-10"
               }
             ] = results(conn)

      # The exact retry returns the stored result verbatim.
      conn = post_operations(conn, [close])

      assert [
               %{
                 "operation_id" => "op-close",
                 "status" => "applied",
                 "period_end_on" => "2027-01-10"
               }
             ] =
               results(conn)

      # A different identifier attempting the same cutoff is a fresh domain
      # rejection, and a changed payload under the taken identifier conflicts.
      conn =
        post_operations(conn, [
          close_period_operation("2027-01-10", %{"operation_id" => "op-close-second"}),
          close_period_operation("2027-02-10", %{"operation_id" => "op-close"})
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "rejected", "code" => "operation_id_conflict"}
             ] = results(conn)

      assert %{"status" => "closed"} = finance_report(conn, "2027-01-10")
      assert %{"status" => "open"} = finance_report(conn, "2027-02-10")
    end
  end

  describe "publishing reports" do
    test "published days return status closed and stay byte-for-byte stable forever", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 1_000, %{"occurred_on" => "2027-01-04"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn = post_operations(conn, [close_period_operation("2027-01-05")])

      closed_body =
        conn
        |> get_finance_report(%{"date" => "2027-01-05"})
        |> response(200)

      assert %{"data" => %{"date" => "2027-01-05", "status" => "closed"}} =
               Jason.decode!(closed_body)

      # Later operations and another close cannot move a single figure.
      conn =
        post_operations(conn, [
          payment_operation("group-81", 500, %{"occurred_on" => "2026-12-20"})
        ])

      assert [%{"status" => "applied"}] = results(conn)

      conn = post_operations(conn, [close_period_operation("2027-02-28")])

      assert conn |> get_finance_report(%{"date" => "2027-01-05"}) |> response(200) == closed_body

      # Every day through a cutoff publishes, including quiet ones; days
      # beyond the frontier stay open.
      for date <- ~w(2027-01-01 2027-01-02 2027-02-28) do
        assert %{"data" => %{"status" => "closed"}} =
                 conn |> get_finance_report(%{"date" => date}) |> json_response(200)
      end

      assert %{"data" => %{"status" => "open"}} =
               conn |> get_finance_report(%{"date" => "2027-03-01"}) |> json_response(200)
    end

    test "an operation immediately before the close posts into the period being closed", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 800, %{"occurred_on" => "2027-01-10"}),
          close_period_operation("2027-01-10")
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, "2027-01-10") == %{
               "date" => "2027-01-10",
               "status" => "closed",
               "cash" => [cash_entry("ams-canal", 0, %{"received_cents" => 800}, 800)],
               "credit" => credit_entry(0, %{}, 0),
               "late_adjustments" => %{"cash" => [], "credit" => zero_credit_movements()}
             }
    end
  end

  describe "posting after a close" do
    test "an old-dated operation right after the close posts on the first open day", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          close_period_operation("2027-01-10")
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          payment_operation("group-81", 700, %{"occurred_on" => "2027-01-04"})
        ])

      assert [%{"status" => "applied"}] = results(conn)

      # The movement shows up only in the late-adjustments block; the
      # property still appears because its closing balance moved.
      assert finance_report(conn, "2027-01-11") == %{
               "date" => "2027-01-11",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => zero_cash_movements(),
                   "closing_held_cents" => 700
                 }
               ],
               "credit" => credit_entry(0, %{}, 0),
               "late_adjustments" => %{
                 "cash" => late_cash([{"ams-canal", %{"received_cents" => 700}}]),
                 "credit" => zero_credit_movements()
               }
             }

      # The rule changes only finance reporting; the ledger keeps its
      # current-state meaning.
      assert %{"cash_held_cents" => 700} = ledger_data(conn)
    end

    test "an operation keeps its posting date when a later close publishes it", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          close_period_operation("2027-01-10")
        ])

      conn =
        post_operations(conn, [
          payment_operation("group-81", 300, %{"occurred_on" => "2026-12-25"})
        ])

      assert [%{"status" => "applied"}] = results(conn)
      posted = finance_report(conn, "2027-01-11")

      conn = post_operations(conn, [close_period_operation("2027-01-15")])

      # Publishing freezes the day exactly as committed, flipping only the
      # status to closed.
      assert finance_report(conn, "2027-01-11") == %{posted | "status" => "closed"}
    end

    test "reversing a published refund reports negative refunded with positive charged-back late adjustments",
         %{conn: conn} do
      payment_id = "op-pay-sign"

      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 4_000, %{
            "occurred_on" => "2027-01-02",
            "operation_id" => payment_id
          }),
          cancel_operation("group-81", %{"occurred_on" => "2026-11-20"}),
          close_period_operation("2027-01-05")
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          charge_back_payment_operation(payment_id, %{"occurred_on" => "2027-01-04"})
        ])

      assert [%{"status" => "applied", "charged_back_cents" => 4_000}] = results(conn)

      report = finance_report(conn, "2027-01-06")
      entry = hd(report["cash"])

      # Ordinary movements stay empty; the reversal lives entirely in the
      # signed late adjustments instead of disappearing as a zero-net pair.
      assert entry == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 0
             }

      assert report["late_adjustments"]["cash"] ==
               late_cash([
                 {"ams-canal", %{"refunded_cents" => -4_000, "charged_back_cents" => 4_000}}
               ])

      assert %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 4_000} = ledger_data(conn)
    end

    test "credit issued after a close enters liability through the late-adjustment credit block",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          close_period_operation("2027-01-05")
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          payment_operation("group-81", 1_000, %{"occurred_on" => "2027-01-02"}),
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, "2027-01-06") == %{
               "date" => "2027-01-06",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => zero_cash_movements(),
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => credit_entry(0, %{}, 1_100),
               "late_adjustments" => %{
                 "cash" =>
                   late_cash([
                     {"ams-canal",
                      %{"received_cents" => 1_000, "converted_to_credit_cents" => 1_000}}
                   ]),
                 "credit" => Map.merge(zero_credit_movements(), %{"issued_cents" => 1_100})
               }
             }

      assert %{"credit_liability_cents" => 1_100, "cash_held_cents" => 0} = ledger_data(conn)
    end

    test "a day totals its ordinary movements together with its late adjustments", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          close_period_operation("2027-01-10")
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          # Occurred inside the closed period: forwarded to the first open day.
          payment_operation("group-81", 400, %{"occurred_on" => "2027-01-05"}),
          # Occurred on the first open day itself: keeps that date ordinarily.
          payment_operation("group-81", 600, %{"occurred_on" => "2027-01-11"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      report = finance_report(conn, "2027-01-11")

      assert report["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 600}, 1_000)
             ]

      assert report["late_adjustments"]["cash"] ==
               late_cash([{"ams-canal", %{"received_cents" => 400}}])
    end

    test "transfers after a close post both sides of the move as late adjustments", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_operation(%{
            "group_id" => "group-b",
            "property_id" => "rot-lake",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
          }),
          start_reporting_operation(@start),
          close_period_operation("2027-01-10")
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          payment_operation("group-81", 5_000, %{"occurred_on" => "2027-01-02"}),
          transfer_deposit_operation("group-81", "group-b", 3_000, %{
            "occurred_on" => "2027-01-03"
          })
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      report = finance_report(conn, "2027-01-11")

      assert report["cash"] == [
               cash_entry("ams-canal", 0, %{}, 2_000),
               cash_entry("rot-lake", 0, %{}, 3_000)
             ]

      assert report["late_adjustments"]["cash"] ==
               late_cash([
                 {"ams-canal", %{"received_cents" => 5_000, "transferred_out_cents" => 3_000}},
                 {"rot-lake", %{"transferred_in_cents" => 3_000}}
               ])

      # Transferred-in and transferred-out stay equal company-wide.
      assert %{"cash_held_cents" => 5_000} = ledger_data(conn)
      assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) == 5_000
    end
  end
end
