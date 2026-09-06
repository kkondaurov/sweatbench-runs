defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates closes and preserves their durable replay and conflict behavior", %{conn: conn} do
    before_start = close("before-start", "2026-10-01")

    assert post_batch(conn, [before_start]) == [
             rejected("before-start", "invalid_period")
           ]

    assert post_batch(build_conn(), [start("start", "2026-10-01")]) == [
             %{
               "operation_id" => "start",
               "status" => "applied",
               "starts_on" => "2026-10-01"
             }
           ]

    # Rejections are durable even when later state would make the submission valid.
    assert post_batch(build_conn(), [before_start]) == [
             rejected("before-start", "invalid_period")
           ]

    invalid_closes = [
      close("missing", "2026-10-01") |> Map.delete("period_end_on"),
      close("malformed", "not-a-date"),
      close("wrong-type", 20_261_001),
      close("before-inception", "2026-09-30")
    ]

    assert Enum.map(post_batch(build_conn(), invalid_closes), & &1["code"]) ==
             List.duplicate("invalid_period", 4)

    first = close("first-close", "2026-10-02")

    assert post_batch(build_conn(), [first]) == [
             %{
               "operation_id" => "first-close",
               "status" => "applied",
               "period_end_on" => "2026-10-02"
             }
           ]

    assert post_batch(build_conn(), [close("same-cutoff", "2026-10-02")]) == [
             rejected("same-cutoff", "invalid_period")
           ]

    assert post_batch(build_conn(), [close("earlier-cutoff", "2026-10-01")]) == [
             rejected("earlier-cutoff", "invalid_period")
           ]

    assert post_batch(build_conn(), [close("later-close", "2026-10-05")]) == [
             %{
               "operation_id" => "later-close",
               "status" => "applied",
               "period_end_on" => "2026-10-05"
             }
           ]

    # An exact retry does not consult the newer cutoff.
    assert post_batch(build_conn(), [first]) == [
             %{
               "operation_id" => "first-close",
               "status" => "applied",
               "period_end_on" => "2026-10-02"
             }
           ]

    assert post_batch(build_conn(), [close("first-close", "2026-10-06")]) == [
             rejected("first-close", "operation_id_conflict")
           ]
  end

  test "same-batch ordering fixes posting dates and exposes ordinary and late movements", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        start("start", "2026-10-01"),
        open("group", "guest", "ams-canal", "flexible", 500),
        cash("before-close", "group", 40, "2026-09-01"),
        close("close", "2026-10-02"),
        cash("late", "group", 30, "2026-09-01"),
        cash("ordinary", "group", 20, "2026-10-04")
      ])

    assert Enum.at(results, 3) == %{
             "operation_id" => "close",
             "status" => "applied",
             "period_end_on" => "2026-10-02"
           }

    closed_start = report("2026-10-01")

    assert closed_start == %{
             "date" => "2026-10-01",
             "status" => "closed",
             "cash" => [cash_entry("ams-canal", 0, %{"received_cents" => 40}, 40)],
             "credit" => credit(0, %{}, 0),
             "late_adjustments" => late_adjustments()
           }

    closed_quiet = report("2026-10-02")

    assert closed_quiet == %{
             "date" => "2026-10-02",
             "status" => "closed",
             "cash" => [cash_entry("ams-canal", 40, %{}, 40)],
             "credit" => credit(0, %{}, 0),
             "late_adjustments" => late_adjustments()
           }

    assert report("2026-10-03") == %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [cash_entry("ams-canal", 40, %{}, 70)],
             "credit" => credit(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments([
                 late_cash_entry("ams-canal", %{"received_cents" => 30})
               ])
           }

    assert report("2026-10-04") == %{
             "date" => "2026-10-04",
             "status" => "open",
             "cash" => [cash_entry("ams-canal", 70, %{"received_cents" => 20}, 90)],
             "credit" => credit(0, %{}, 0),
             "late_adjustments" => late_adjustments()
           }

    # Closing the day later changes only its publication status. The posting chosen
    # by the already-committed late payment never moves to the next open day.
    assert post_batch(build_conn(), [close("next-close", "2026-10-03")]) |> hd() == %{
             "operation_id" => "next-close",
             "status" => "applied",
             "period_end_on" => "2026-10-03"
           }

    assert report("2026-10-03")["status"] == "closed"

    assert report("2026-10-03")["late_adjustments"] ==
             late_adjustments([late_cash_entry("ams-canal", %{"received_cents" => 30})])

    assert report("2026-10-04")["cash"] == [
             cash_entry("ams-canal", 70, %{"received_cents" => 20}, 90)
           ]

    # Reports already closed by the first operation remain exact values.
    assert report("2026-10-01") == closed_start
    assert report("2026-10-02") == closed_quiet
  end

  test "a late chargeback retains signed classifications even when its net effect is zero", %{
    conn: conn
  } do
    post_batch(conn, [
      start("start", "2026-10-01"),
      open("group", "guest", "ams-canal", "flexible", 500),
      cash("payment", "group", 100, "2026-10-01"),
      cancel("refund", "group", "2026-10-02", "cash"),
      close("close", "2026-10-02")
    ])

    closed = report("2026-10-02")

    assert post_batch(build_conn(), [chargeback("chargeback", "payment", "2026-10-01")])
           |> hd()
           |> Map.take(["status", "charged_back_cents"]) == %{
             "status" => "applied",
             "charged_back_cents" => 100
           }

    assert report("2026-10-03") == %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [cash_entry("ams-canal", 0, %{}, 0)],
             "credit" => credit(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments([
                 late_cash_entry("ams-canal", %{
                   "refunded_cents" => -100,
                   "charged_back_cents" => 100
                 })
               ])
           }

    assert report("2026-10-02") == closed

    assert ledger() |> Map.take(["cash_refunded_cents", "cash_charged_back_cents"]) == %{
             "cash_refunded_cents" => 0,
             "cash_charged_back_cents" => 100
           }
  end

  test "late credit settlement uses occurred-on refundability and cannot rewrite a closed expiry",
       %{conn: conn} do
    post_batch(conn, [
      start("start", "2026-01-01"),
      open("seed", "guest", "ams-canal", "flexible", 500, "2028-12-31"),
      cash("seed-payment", "seed", 100, "2026-01-01"),
      cancel("issue", "seed", "2026-01-02", "hotel_credit"),
      open("funded", "guest", "ams-canal", "flexible", 500, "2026-02-20"),
      apply_credit("fund", "funded", 100, "2026-01-03"),
      close("first-close", "2026-03-01")
    ])

    # The economic date is refundable (cutoff 2026-02-06), although the reporting
    # posting date selected below is 2026-03-02 and is after that cutoff.
    assert post_batch(build_conn(), [
             cancel("restore", "funded", "2026-02-01", "cash")
           ])
           |> hd()
           |> Map.take(["status", "refunded_cents", "retained_cents"]) == %{
             "status" => "applied",
             "refunded_cents" => 0,
             "retained_cents" => 0
           }

    assert report("2026-03-02") == %{
             "date" => "2026-03-02",
             "status" => "open",
             "cash" => [],
             "credit" => credit(110, %{}, 110),
             "late_adjustments" => late_adjustments()
           }

    # The restored lot expires on 2027-01-02, so the following day carries the
    # expiry. Close it, then use an old economic date to apply some credit after
    # the close. The closed expiry must stay unchanged.
    post_batch(build_conn(), [
      open("target", "guest", "berlin", "advance_purchase", 100, "2028-12-31"),
      close("expiry-close", "2027-01-03")
    ])

    expiry = report("2027-01-03")

    assert expiry == %{
             "date" => "2027-01-03",
             "status" => "closed",
             "cash" => [],
             "credit" => credit(110, %{"expired_cents" => 110}, 0),
             "late_adjustments" => late_adjustments()
           }

    assert post_batch(build_conn(), [apply_credit("late-apply", "target", 100, "2026-12-01")])
           |> hd()
           |> Map.take(["status", "amount_cents"]) == %{
             "status" => "applied",
             "amount_cents" => 100
           }

    assert report("2027-01-03") == expiry

    assert report("2027-01-04") == %{
             "date" => "2027-01-04",
             "status" => "open",
             "cash" => [],
             "credit" => credit(0, %{}, 100),
             "late_adjustments" => late_adjustments([], %{"expired_cents" => -100})
           }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger do
    build_conn()
    |> get("/api/v1/ledger?on=2027-01-01")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp start(id, starts_on),
    do: %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => starts_on}

  defp close(id, period_end_on),
    do: %{
      "operation_id" => id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }

  defp open(id, guest, property, rate_plan, nightly_rate, arrival \\ "2027-12-31") do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => id,
      "guest_id" => guest,
      "property_id" => property,
      "arrival_on" => arrival,
      "departure_on" => arrival |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601(),
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }
  end

  defp cash(id, group, amount, on),
    do: operation(id, "record_cash_payment", group, on, %{"amount_cents" => amount})

  defp apply_credit(id, group, amount, on),
    do: operation(id, "apply_hotel_credit", group, on, %{"amount_cents" => amount})

  defp cancel(id, group, on, method),
    do: operation(id, "cancel_group", group, on, %{"refund_method" => method})

  defp chargeback(id, payment, on),
    do: %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment,
      "occurred_on" => on
    }

  defp operation(id, type, group, on, extra) do
    Map.merge(
      %{"operation_id" => id, "type" => type, "group_id" => group, "occurred_on" => on},
      extra
    )
  end

  defp rejected(operation_id, code),
    do: %{"operation_id" => operation_id, "status" => "rejected", "code" => code}

  defp cash_entry(property, opening, movements, closing) do
    %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => cash_movements(movements),
      "closing_held_cents" => closing
    }
  end

  defp late_cash_entry(property, movements),
    do: %{"property_id" => property, "movements" => cash_movements(movements)}

  defp cash_movements(overrides) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp credit(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(movements),
      "closing_liability_cents" => closing
    }
  end

  defp late_adjustments(cash \\ [], credit \\ %{}) do
    %{"cash" => cash, "credit" => credit_movements(credit)}
  end

  defp credit_movements(overrides) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end
end
