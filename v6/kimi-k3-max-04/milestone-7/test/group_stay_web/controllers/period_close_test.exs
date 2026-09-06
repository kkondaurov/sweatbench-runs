defmodule GroupStayWeb.PeriodCloseTest do
  @moduledoc """
  `close_finance_period` and published daily reports
  (docs/requests/07-period-close.md).

  Scenario groups use one room at rate 3000 for one night, so the deposit
  due is 600 per group.
  """
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: [operation]})
    |> json_response(200)
    |> get_in(["results"])
    |> hd()
  end

  defp applied!(result) do
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp report(conn, date) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp next_id, do: "op-#{System.unique_integer([:positive])}"

  defp open_op(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 3000}]
      },
      overrides
    )
  end

  defp pay_op(group_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp start_op(starts_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "start_finance_reporting",
        "starts_on" => starts_on
      },
      overrides
    )
  end

  defp close_op(period_end_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "close_finance_period",
        "period_end_on" => period_end_on
      },
      overrides
    )
  end

  describe "close_finance_period validation" do
    test "applies with exactly operation_id, status, and period_end_on", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))

      result = applied!(submit_one(conn, close_op("2026-10-12")))

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "period_end_on" => "2026-10-12"
             }
    end

    test "rejects before reporting has started", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, close_op("2026-10-12"))
    end

    test "rejects a cutoff before starts_on", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, close_op("2026-10-09"))
    end

    test "rejects a missing or unparsable cutoff", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))

      missing = close_op(nil) |> Map.delete("period_end_on")

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, missing)

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, close_op("not-a-date"))

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, close_op("2026-13-01"))
    end

    test "rejects the same or an earlier cutoff than the latest close", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))
      applied!(submit_one(conn, close_op("2026-10-12")))

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, close_op("2026-10-12"))

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, close_op("2026-10-11"))

      applied!(submit_one(conn, close_op("2026-10-13")))
    end

    test "accepts a cutoff equal to starts_on", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))
      applied!(submit_one(conn, close_op("2026-10-10")))

      assert %{"status" => "closed"} = report(conn, "2026-10-10")
    end

    test "a retry returns the exact stored result; a different payload conflicts", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))

      op = close_op("2026-10-12")
      done = applied!(submit_one(conn, op))

      assert submit_one(conn, op) == done

      conflict =
        submit_one(conn, %{
          close_op("2026-10-13")
          | "operation_id" => op["operation_id"]
        })

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = conflict
    end

    test "a rejected close leaves reporting open", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, close_op("2026-10-09"))

      assert %{"status" => "open"} = report(conn, "2026-10-10")
    end
  end

  describe "published reports" do
    test "reports through the cutoff are closed; later reports stay open", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))
      applied!(submit_one(conn, close_op("2026-10-12")))

      assert %{"status" => "closed"} = report(conn, "2026-10-10")
      assert %{"status" => "closed"} = report(conn, "2026-10-12")
      assert %{"status" => "open"} = report(conn, "2026-10-13")
    end

    test "a closed report is byte-for-byte stable across later operations", %{conn: conn} do
      group = "close-stable"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 400, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-11")
        ]),
        &applied!/1
      )

      frozen = report(conn, "2026-10-11")

      # This later payment posts after the close, so the closed day can no
      # longer move.
      applied!(submit_one(conn, pay_op(group, 200, %{"occurred_on" => "2026-10-11"})))

      assert report(conn, "2026-10-11") == frozen
      assert report(conn, "2026-10-11") == frozen
    end

    test "a later close leaves already-published reports untouched", %{conn: conn} do
      group = "close-twice"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 400, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-11")
        ]),
        &applied!/1
      )

      frozen = report(conn, "2026-10-11")

      Enum.each(
        submit(conn, [
          pay_op(group, 200, %{"occurred_on" => "2026-10-13"}),
          close_op("2026-10-13")
        ]),
        &applied!/1
      )

      assert report(conn, "2026-10-11") == frozen
      assert %{"status" => "closed"} = report(conn, "2026-10-13")
    end

    test "closing captures synthesized credit expiry exactly once", %{conn: conn} do
      source = "close-expiry-src"
      pay = "pay-expiry"

      # Issue a lot on 2026-11-26 (expires 2027-11-26, so it shows expiry on
      # 2027-11-27), then close through the expiry day.
      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(source, "guest-22"),
          pay_op(source, 400, %{"operation_id" => pay}),
          cancel_op(source, %{"refund_method" => "hotel_credit"}),
          close_op("2027-11-27")
        ]),
        &applied!/1
      )

      frozen = report(conn, "2027-11-27")

      assert %{
               "status" => "closed",
               "credit" => %{
                 "movements" => %{"expired_cents" => 440},
                 "closing_liability_cents" => 0
               }
             } = frozen

      # Afterwards, revoke the lot's available balance through a chargeback;
      # the published expiry must not move.
      applied!(
        submit_one(conn, %{
          "operation_id" => next_id(),
          "type" => "charge_back_payment",
          "payment_operation_id" => pay,
          "occurred_on" => "2027-11-28"
        })
      )

      assert report(conn, "2027-11-27") == frozen
    end
  end

  describe "posting after a close" do
    test "an operation immediately before a close posts into the closing period", %{conn: conn} do
      group = "pre-close"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 400, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-11")
        ]),
        &applied!/1
      )

      day = report(conn, "2026-10-11")

      assert [
               %{
                 "movements" => %{"received_cents" => 400},
                 "closing_held_cents" => 400
               }
             ] = day["cash"]

      assert day["late_adjustments"]["cash"] == []
    end

    test "an old-dated operation after a close posts on the first open day", %{conn: conn} do
      group = "post-close"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 400, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-11"),
          pay_op(group, 200, %{"occurred_on" => "2026-10-11"})
        ]),
        &applied!/1
      )

      day = report(conn, "2026-10-12")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 400,
                 "movements" => %{"received_cents" => 0},
                 "closing_held_cents" => 600
               }
             ] = day["cash"]

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{"received_cents" => 200}
               }
             ] = day["late_adjustments"]["cash"]

      assert day["late_adjustments"]["credit"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
    end

    test "an operation with occurred_on in the open period keeps its date", %{conn: conn} do
      group = "keep-date"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          close_op("2026-10-11"),
          pay_op(group, 300, %{"occurred_on" => "2026-10-13"})
        ]),
        &applied!/1
      )

      day = report(conn, "2026-10-13")

      assert [
               %{
                 "movements" => %{"received_cents" => 300},
                 "closing_held_cents" => 300
               }
             ] = day["cash"]

      assert day["late_adjustments"]["cash"] == []

      # Nothing posted on 2026-10-12, so the report carries no property.
      assert report(conn, "2026-10-12")["cash"] == []
    end

    test "a posting date chosen at commit never moves again", %{conn: conn} do
      group = "pinned-date"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          close_op("2026-10-11"),
          pay_op(group, 300, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-12")
        ]),
        &applied!/1
      )

      # The late payment pinned itself to 2026-10-12 at commit; closing that
      # day froze the classification it made.
      day = report(conn, "2026-10-12")

      assert [
               %{
                 "opening_held_cents" => 0,
                 "movements" => %{"received_cents" => 0},
                 "closing_held_cents" => 300
               }
             ] = day["cash"]

      assert [
               %{"movements" => %{"received_cents" => 300}}
             ] = day["late_adjustments"]["cash"]

      assert %{"status" => "closed"} = day
    end
  end

  describe "late adjustments" do
    test "the cash block is ordered by property and omits all-zero properties", %{conn: conn} do
      dst = "late-dst"
      src = "late-src"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(dst, "guest-22", %{"property_id" => "zzz-backup"}),
          open_op(src, "guest-22"),
          close_op("2026-10-11"),
          pay_op(dst, 200, %{"occurred_on" => "2026-10-11"}),
          pay_op(src, 100, %{"occurred_on" => "2026-10-11"})
        ]),
        &applied!/1
      )

      day = report(conn, "2026-10-12")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{"received_cents" => 100}
               },
               %{
                 "property_id" => "zzz-backup",
                 "movements" => %{"received_cents" => 200}
               }
             ] = day["late_adjustments"]["cash"]
    end

    test "a credit conversion after a close classifies both cash and credit as late", %{
      conn: conn
    } do
      group = "late-conv"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 400, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-11"),
          cancel_op(group, %{
            "occurred_on" => "2026-10-11",
            "refund_method" => "hotel_credit"
          })
        ]),
        &applied!/1
      )

      day = report(conn, "2026-10-12")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 400,
                 "movements" => %{"converted_to_credit_cents" => 0},
                 "closing_held_cents" => 0
               }
             ] = day["cash"]

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{"converted_to_credit_cents" => 400}
               }
             ] = day["late_adjustments"]["cash"]

      assert %{
               "opening_liability_cents" => 0,
               "movements" => %{"issued_cents" => 0},
               "closing_liability_cents" => 440
             } = day["credit"]

      assert %{"issued_cents" => 440} = day["late_adjustments"]["credit"]
    end

    test "signed classifications survive a zero-net late adjustment", %{conn: conn} do
      group = "late-chargeback"
      pay = "pay-late-1"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 100, %{"operation_id" => pay, "occurred_on" => "2026-10-11"}),
          cancel_op(group, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-11"),
          %{
            "operation_id" => next_id(),
            "type" => "charge_back_payment",
            "payment_operation_id" => pay,
            "occurred_on" => "2026-10-11"
          }
        ]),
        &applied!/1
      )

      day = report(conn, "2026-10-12")

      # The chargeback reclassifies the closed-period refund: refunded -100
      # and charged_back +100 keep their signed values instead of netting
      # out of the report.
      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   "refunded_cents" => -100,
                   "charged_back_cents" => 100
                 }
               }
             ] = day["late_adjustments"]["cash"]

      assert [
               %{
                 "opening_held_cents" => 0,
                 "movements" => %{"refunded_cents" => 0, "charged_back_cents" => 0},
                 "closing_held_cents" => 0
               }
             ] = day["cash"]
    end

    test "closing captures the late classifications the day they pinned", %{conn: conn} do
      group = "late-freeze"
      pay = "pay-late-2"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 100, %{"operation_id" => pay, "occurred_on" => "2026-10-11"}),
          cancel_op(group, %{"occurred_on" => "2026-10-11"}),
          close_op("2026-10-11"),
          %{
            "operation_id" => next_id(),
            "type" => "charge_back_payment",
            "payment_operation_id" => pay,
            "occurred_on" => "2026-10-11"
          },
          close_op("2026-10-12")
        ]),
        &applied!/1
      )

      frozen = report(conn, "2026-10-12")

      assert %{"status" => "closed"} = frozen

      assert [
               %{
                 "movements" => %{
                   "refunded_cents" => -100,
                   "charged_back_cents" => 100
                 }
               }
             ] = frozen["late_adjustments"]["cash"]

      assert report(conn, "2026-10-12") == frozen
    end
  end

  describe "non-reporting views" do
    test "a close does not change group or ledger state", %{conn: conn} do
      group = "close-views"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 400, %{"occurred_on" => "2026-10-11"})
        ]),
        &applied!/1
      )

      before_group =
        conn
        |> get(~p"/api/v1/groups/#{group}")
        |> json_response(200)
        |> Map.fetch!("data")

      before_ledger =
        conn
        |> get(~p"/api/v1/ledger")
        |> json_response(200)
        |> Map.fetch!("data")

      applied!(submit_one(conn, close_op("2026-10-11")))

      after_group =
        conn
        |> get(~p"/api/v1/groups/#{group}")
        |> json_response(200)
        |> Map.fetch!("data")

      after_ledger =
        conn
        |> get(~p"/api/v1/ledger")
        |> json_response(200)
        |> Map.fetch!("data")

      assert after_group == before_group
      assert after_ledger == before_ledger
    end
  end
end
